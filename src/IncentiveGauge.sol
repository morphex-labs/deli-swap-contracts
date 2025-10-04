// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EfficientHashLib} from "lib/solady/src/utils/EfficientHashLib.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IPoolKeys} from "./interfaces/IPoolKeys.sol";
import {IPositionManagerAdapter} from "./interfaces/IPositionManagerAdapter.sol";

import {RangePool} from "./libraries/RangePool.sol";
import {RangePosition} from "./libraries/RangePosition.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";

/**
 * @title IncentiveGauge
 * @notice Streams ERC20 incentive tokens to Uniswap v4 LP NFTs.
 *         PositionManager subscription callbacks track liquidity changes so
 *         rewards remain proportional over time.  Each stream lasts 7 days
 *         and can be topped-up seamlessly; leftover tokens are rolled into the
 *         new stream. Rewards are forfeited on position unsubscribe.
 */
contract IncentiveGauge is Ownable2Step {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;
    using TickBitmap for mapping(int16 => uint256);
    using TimeLibrary for uint256;

    /*//////////////////////////////////////////////////////////////
                                   STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct IncentiveInfo {
        uint128 rewardRate; // tokens per second, Q0
        uint64 periodFinish; // timestamp when current stream ends
        uint64 lastUpdate; // last time pool accumulator updated for this token
        uint128 remaining; // tokens still not streamed (for accounting)
    }

    // track pending rewards for a position
    struct Pending {
        IERC20 token;
        uint256 amount;
    }

    // track tick range per position key
    struct TickRange {
        int24 lower;
        int24 upper;
    }

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    IPoolManager public immutable POOL_MANAGER;

    IPositionManagerAdapter public positionManagerAdapter;

    mapping(address => bool) public isHook;

    // pool -> rewardToken -> incentive data
    mapping(PoolId => mapping(IERC20 => IncentiveInfo)) public incentives;

    // Shared pool state per pool (token-aware accumulators inside RangePool)
    mapping(PoolId => RangePool.State) public poolRewards;
    // positionKey -> token -> positionState
    mapping(bytes32 => mapping(IERC20 => RangePosition.State)) public positionRewards;

    // Track all positionKeys owned by a user per pool
    mapping(PoolId => mapping(address => bytes32[])) internal ownerPositions;
    // O(1) index: per posKey -> owner and idx+1
    mapping(bytes32 => address) internal positionOwner;
    mapping(bytes32 => uint256) internal positionIndex;
    // Cache latest liquidity for each positionKey (token-agnostic)
    mapping(bytes32 => uint128) internal positionLiquidity;

    mapping(bytes32 => TickRange) internal positionTicks;
    mapping(bytes32 => uint256) internal positionTokenIds;

    // registry of all tokens ever used by a pool
    mapping(PoolId => IERC20[]) internal poolTokenRegistry;
    mapping(PoolId => mapping(IERC20 => bool)) internal inRegistry;

    // whitelist of reward tokens
    mapping(IERC20 => bool) public whitelist;

    // cache tickSpacing per pool
    mapping(PoolId => int24) internal poolTickSpacing;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WhitelistSet(IERC20 indexed token, bool allowed);
    event Claimed(address indexed user, IERC20 indexed token, uint256 amount);
    event HookAuthorised(address hook, bool enabled);
    event PositionManagerAdapterUpdated(address newAdapter);
    event IncentiveActivated(PoolId indexed pid, IERC20 indexed token, uint256 amount, uint256 rate);
    event IncentiveDeactivated(PoolId indexed pid, IERC20 indexed token);
    event ForceUnsubscribed(address indexed owner, PoolId indexed pid, bytes32 posKey);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _pm, IPositionManagerAdapter _posManagerAdapter, address _hook) Ownable(msg.sender) {
        POOL_MANAGER = _pm;
        positionManagerAdapter = _posManagerAdapter;
        isHook[_hook] = true;
        emit HookAuthorised(_hook, true);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyPositionManagerAdapter() {
        if (msg.sender != address(positionManagerAdapter)) revert DeliErrors.NotSubscriber();
        _;
    }

    modifier onlyHook() {
        if (!isHook[msg.sender]) revert DeliErrors.NotHook();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                   ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin-only function to set the hook.
    /// @param _hook The address of the hook.
    /// @param _enabled Whether the hook is enabled.
    function setHook(address _hook, bool _enabled) external onlyOwner {
        if (_hook == address(0)) revert DeliErrors.ZeroAddress();
        isHook[_hook] = _enabled;
        emit HookAuthorised(_hook, _enabled);
    }

    /// @notice Admin-only function to set the whitelist.
    /// @param _token The token to set the whitelist for.
    /// @param _enabled Whether the token is whitelisted.
    function setWhitelist(IERC20 _token, bool _enabled) external onlyOwner {
        whitelist[_token] = _enabled;
        emit WhitelistSet(_token, _enabled);
    }

    /// @notice Admin-only function to set the position manager adapter.
    /// @param _adapter The address of the position manager adapter.
    function setPositionManagerAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert DeliErrors.ZeroAddress();
        positionManagerAdapter = IPositionManagerAdapter(_adapter);
        emit PositionManagerAdapterUpdated(_adapter);
    }

    /// @notice Admin-only function to forcibly unsubscribe and clean up a position
    /// @dev Accrues across all registered tokens, removes internal liquidity and indices.
    ///      Optionally claims accrued rewards to the stored owner; otherwise forfeits them.
    /// @param posKey The position key (hash of tokenId and poolId)
    /// @param claimToOwner If true, transfer accrued rewards to the stored owner; if false, forfeit and clear.
    function adminForceUnsubscribe(bytes32 posKey, bool claimToOwner) external onlyOwner {
        // Skip if already removed
        if (positionTokenIds[posKey] == 0) return;

        // Derive pool id from stored tokenId via adapter
        uint256 tokenId = positionTokenIds[posKey];
        (PoolKey memory key,) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();

        // Update pool to latest tick and time so accruals are up-to-date
        _updatePoolByPid(pid);

        // Accrue across all tokens with current liquidity
        TickRange storage tr = positionTicks[posKey];
        uint128 liq = positionLiquidity[posKey];

        _accrueAcrossTokens(pid, posKey, tr.lower, tr.upper, liq);

        // Remove liquidity from pool accounting
        if (liq != 0) {
            _applyLiquidityDeltaByPid(pid, tr.lower, tr.upper, -SafeCast.toInt128(uint256(liq)), false);
        }

        address owner = positionOwner[posKey];
        if (claimToOwner) {
            // Claim all tokens to stored owner and clear per-token state
            _claimAcrossTokens(pid, posKey, owner, true);
        }

        // Remove indices and caches
        RangePosition.removePosition(ownerPositions, positionLiquidity, positionOwner, positionIndex, pid, posKey);
        delete positionTicks[posKey];
        delete positionTokenIds[posKey];

        emit ForceUnsubscribed(owner, pid, posKey);
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time pool bootstrap called by hooks after pool initialization.
    /// @dev Prevents user-driven initialization at incorrect ticks.
    function initPool(PoolKey memory key, int24 initialTick) external onlyHook {
        PoolId pid = key.toId();
        RangePool.State storage pool = poolRewards[pid];
        if (pool.lastUpdated != 0) revert DeliErrors.AlreadySet();
        pool.initialize(initialTick);
        // Cache tickSpacing once using
        int24 ts = key.tickSpacing;
        poolTickSpacing[pid] = ts;
    }

    /// @notice Called by DeliHook to update pool state
    function pokePool(PoolKey calldata key) external onlyHook {
        _updatePoolByPid(key.toId());
    }

    /// @notice Fund a new 7-day stream for `rewardToken` on `poolKey`.
    ///         If an existing stream is active the remaining tokens are added and rate recalculated.
    /// @param key The pool key for the pool to create the incentive for.
    /// @param rewardToken The token to create the incentive for.
    /// @param amount The amount of tokens to create the incentive for.
    function createIncentive(PoolKey calldata key, IERC20 rewardToken, uint256 amount) external {
        if (
            !(
                whitelist[rewardToken] || rewardToken == IERC20(Currency.unwrap(key.currency0))
                    || rewardToken == IERC20(Currency.unwrap(key.currency1))
            )
        ) {
            revert DeliErrors.NotAllowed();
        }
        if (amount == 0) revert DeliErrors.ZeroAmount();

        PoolId pid = key.toId();
        // Require pool to be initialized by the hook
        if (poolRewards[pid].lastUpdated == 0) revert DeliErrors.PoolNotInitialized();

        // pull tokens up-front
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        // register token in pool registry
        if (!inRegistry[pid][rewardToken]) {
            inRegistry[pid][rewardToken] = true;
            poolTokenRegistry[pid].push(rewardToken);
        }

        // Upsert incentive: activate or top-up existing schedule
        uint128 rate = _upsertIncentive(pid, rewardToken, amount);
        emit IncentiveActivated(pid, rewardToken, amount, rate);
    }

    /// @notice Claim accrued token rewards for a single position.
    /// @param tokenId The NFT token ID of the position to claim for.
    /// @param token The token to claim rewards for.
    /// @param to The address to transfer the rewards to.
    /// @return amount The amount of rewards claimed.
    function claim(uint256 tokenId, IERC20 token, address to) external returns (uint256 amount) {
        // Verify the caller owns the position
        address owner = positionManagerAdapter.ownerOf(tokenId);
        if (msg.sender != owner) revert DeliErrors.NotAuthorized();

        (PoolKey memory key,) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // If unsubscribed (position removed), nothing to claim
        if (positionTokenIds[positionKey] == 0) {
            return 0;
        }

        // Update pool state
        _updatePoolByPid(pid);
        TickRange storage tr = positionTicks[positionKey];
        uint256 rpl = poolRewards[pid].rangeRplX128(address(token), tr.lower, tr.upper);
        RangePosition.State storage ps = positionRewards[positionKey][token];
        ps.accrue(positionLiquidity[positionKey], rpl);

        // Claim and transfer
        amount = _claimRewards(positionKey, token, to);
    }

    /// @notice Claim all token rewards for an owner across multiple pools.
    /// @param pids The pools to claim rewards for.
    /// @param owner The owner to claim rewards for.
    function claimAllForOwner(PoolId[] calldata pids, address owner) external {
        uint256 plen = pids.length;
        for (uint256 p; p < plen; ++p) {
            PoolId pid = pids[p];

            // Skip if owner has no positions in this pool
            bytes32[] storage keys = ownerPositions[pid][owner];
            if (keys.length == 0) continue;

            // Skip pools with no registered tokens
            if (poolTokenRegistry[pid].length == 0) continue;

            // Update pool once per pid
            _updatePoolByPid(pid);

            // Accrue and claim for every position (swap-pop safe loop)
            uint256 i;
            while (i < keys.length) {
                bytes32 posKey = keys[i];

                // Verify this position still belongs to the owner
                uint256 tokenId = positionTokenIds[posKey];
                if (tokenId == 0) {
                    unchecked {
                        ++i;
                    }
                    continue; // Position was removed elsewhere
                }

                // Check ownership (use try-catch to handle burned tokens)
                try positionManagerAdapter.ownerOf(tokenId) returns (address currentOwner) {
                    if (currentOwner != owner) {
                        unchecked {
                            ++i;
                        }
                        continue;
                    }
                } catch {
                    unchecked {
                        ++i;
                    }
                    continue; // Skip if token doesn't exist or ownerOf reverts
                }

                // Accrue/claim across all registered tokens
                _accrueAndClaimForPosition(pid, posKey, owner);

                unchecked {
                    ++i;
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice List registered reward tokens for a pool.
    /// @param pid The poolId to get the reward tokens for.
    /// @return list The list of reward tokens for the pool.
    function poolTokensOf(PoolId pid) external view returns (IERC20[] memory list) {
        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 n = reg.length;
        list = new IERC20[](n);
        for (uint256 i; i < n;) {
            list[i] = reg[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Basic incentive data for APR calculations.
    /// @param pid The poolId to get the incentive data for.
    /// @param token The token to get the incentive data for.
    /// @return rewardRate The reward rate for the token.
    /// @return periodFinish The period finish for the token.
    /// @return remaining The remaining amount for the token.
    function incentiveData(PoolId pid, IERC20 token)
        external
        view
        returns (uint256 rewardRate, uint256 periodFinish, uint256 remaining)
    {
        IncentiveInfo storage info = incentives[pid][token];
        rewardRate = info.rewardRate;
        periodFinish = info.periodFinish;
        remaining = info.remaining;
    }

    /// @notice batched version, returns array aligned to `tokens` input
    /// @param pid The poolId to get the incentive data for.
    /// @param tokens The tokens to get the incentive data for.
    /// @return rewardRates The reward rates for the tokens.
    /// @return finishes The period finishes for the tokens.
    /// @return remainings The remaining amounts for the tokens.
    function incentiveDataBatch(PoolId pid, IERC20[] calldata tokens)
        external
        view
        returns (uint256[] memory rewardRates, uint256[] memory finishes, uint256[] memory remainings)
    {
        uint256 len = tokens.length;
        rewardRates = new uint256[](len);
        finishes = new uint256[](len);
        remainings = new uint256[](len);
        for (uint256 i; i < len;) {
            IncentiveInfo storage info = incentives[pid][tokens[i]];
            rewardRates[i] = info.rewardRate;
            finishes[i] = info.periodFinish;
            remainings[i] = info.remaining;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns pending rewards for a position by tokenId and specific token.
    /// @param tokenId The tokenId to get the pending rewards for.
    /// @param token The token to get the pending rewards for.
    /// @return amount The amount of pending rewards.
    function pendingRewardsByTokenId(uint256 tokenId, IERC20 token) external view returns (uint256 amount) {
        amount = _pendingRewardsByTokenId(tokenId, token);
    }

    /// @notice Batch version, returns array aligned to `tokens` input for a given tokenId
    /// @param tokenId The tokenId to get the pending rewards for.
    /// @param tokens The tokens to get the pending rewards for.
    /// @return amounts The amounts of pending rewards.
    function pendingRewardsByTokenIdBatch(uint256 tokenId, IERC20[] calldata tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 len = tokens.length;
        amounts = new uint256[](len);
        for (uint256 i; i < len;) {
            amounts[i] = _pendingRewardsByTokenId(tokenId, tokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Aggregate pending rewards (all tokens) for an owner in a pool
    /// @param pid The poolId to get the pending rewards for.
    /// @param owner The owner to get the pending rewards for.
    /// @return list The list of pending rewards for the owner in the pool.
    function pendingRewardsOwner(PoolId pid, address owner) external view returns (Pending[] memory list) {
        list = _pendingRewardsForPool(pid, owner);
    }

    /// @notice Batch version, returns array aligned to `pids` input, each element is Pending array for that pool
    /// @param pids The pools to get the pending rewards for.
    /// @param owner The owner to get the pending rewards for.
    /// @return lists The lists of pending rewards for the owner in the pools.
    function pendingRewardsOwnerBatch(PoolId[] calldata pids, address owner)
        external
        view
        returns (Pending[][] memory lists)
    {
        uint256 plen = pids.length;
        lists = new Pending[][](plen);
        for (uint256 p; p < plen;) {
            lists[p] = _pendingRewardsForPool(pids[p], owner);
            unchecked {
                ++p;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Activate a token if inactive, or top-up an active token and recompute rate
    function _upsertIncentive(PoolId pid, IERC20 token, uint256 amount) internal returns (uint128 rate) {
        IncentiveInfo storage info = incentives[pid][token];

        // Always sync pool before updating incentive
        _updatePoolByPid(pid);

        uint256 total = amount;
        if (info.rewardRate > 0) {
            // For active schedules add leftover budget
            if (block.timestamp < info.periodFinish) {
                uint256 remainingTime = info.periodFinish - block.timestamp;
                uint256 leftover = remainingTime * info.rewardRate;
                if (amount <= leftover) revert DeliErrors.InsufficientIncentive();
                total += leftover;
            }
        }

        rate = SafeCast.toUint128(total / TimeLibrary.WEEK);
        info.rewardRate = rate;
        info.periodFinish = uint64(block.timestamp + TimeLibrary.WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = SafeCast.toUint128(total);
    }

    /// @dev Helper to accrue and claim for a single position across all tokens
    function _accrueAndClaimForPosition(PoolId pid, bytes32 posKey, address ownerAddr) internal {
        TickRange storage tr = positionTicks[posKey];
        uint128 liq = positionLiquidity[posKey];
        RangePool.State storage pool = poolRewards[pid];

        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 rlen = reg.length;
        for (uint256 i; i < rlen;) {
            IERC20 tok = reg[i];
            RangePosition.State storage ps = positionRewards[posKey][tok];
            uint256 rpl = pool.rangeRplX128(address(tok), tr.lower, tr.upper);
            ps.accrue(liq, rpl);
            _claimRewards(posKey, tok, ownerAddr);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Accrue across all tokens for a position
    function _accrueAcrossTokens(PoolId pid, bytes32 positionKey, int24 lower, int24 upper, uint128 liquidity)
        internal
    {
        IERC20[] storage reg = poolTokenRegistry[pid];
        RangePool.State storage pool = poolRewards[pid];
        uint256 n = reg.length;
        for (uint256 i; i < n; ++i) {
            IERC20 tok = reg[i];
            RangePosition.State storage ps = positionRewards[positionKey][tok];
            uint256 rpl = pool.rangeRplX128(address(tok), lower, upper);
            ps.accrue(liquidity, rpl);
        }
    }

    /// @dev Claim across all tokens for a position
    function _claimAcrossTokens(PoolId pid, bytes32 positionKey, address to, bool clear) internal {
        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 n = reg.length;
        for (uint256 i; i < n; ++i) {
            IERC20 tok = reg[i];
            _claimRewards(positionKey, tok, to);
            if (clear) delete positionRewards[positionKey][tok];
        }
    }

    /// @dev Apply liquidity delta using only pid; positiveAdd indicates whether to pass token list for outside init
    function _applyLiquidityDeltaByPid(PoolId pid, int24 lower, int24 upper, int128 liquidityDelta, bool positiveAdd)
        internal
    {
        address[] memory addrs;
        if (positiveAdd) {
            IERC20[] storage reg = poolTokenRegistry[pid];
            uint256 n = reg.length;
            addrs = new address[](n);
            for (uint256 i; i < n; ++i) {
                addrs[i] = address(reg[i]);
            }
        } else {
            addrs = new address[](0);
        }
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: liquidityDelta,
                tickSpacing: poolTickSpacing[pid]
            }),
            addrs
        );
    }

    /// @dev Clear any stale per-token state across registry and baseline reward tokens to current inside RPL
    function _clearAndBaselineOnSubscribe(PoolId pid, bytes32 positionKey, int24 tickLower, int24 tickUpper) internal {
        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 rlen = reg.length;
        for (uint256 i; i < rlen;) {
            IERC20 tok = reg[i];
            // Clear stale state
            delete positionRewards[positionKey][tok];
            // Baseline to current inside RPL
            uint256 snap = poolRewards[pid].rangeRplX128(address(tok), tickLower, tickUpper);
            if (snap != 0) {
                positionRewards[positionKey][tok].initSnapshot(snap);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev internal helper for calculating pending rewards by tokenId
    function _pendingRewardsByTokenId(uint256 tokenId, IERC20 token) internal view returns (uint256 amount) {
        try positionManagerAdapter.ownerOf(tokenId) returns (address) {
            (PoolKey memory key,) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
            PoolId pid = key.toId();
            bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

            RangePosition.State storage ps = positionRewards[positionKey][token];
            uint128 liq = positionLiquidity[positionKey];

            if (liq > 0) {
                TickRange storage tr = positionTicks[positionKey];
                uint256 rangeRpl = poolRewards[pid].rangeRplX128(address(token), tr.lower, tr.upper);
                uint256 delta;
                unchecked {
                    delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
                }
                amount = ps.rewardsAccrued + FullMath.mulDiv(delta, liq, FixedPoint128.Q128);
            } else {
                amount = ps.rewardsAccrued;
            }
        } catch {
            amount = 0;
        }
    }

    /// @dev internal helper to compute pending list for one pool
    function _pendingRewardsForPool(PoolId pid, address owner) internal view returns (Pending[] memory list) {
        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 regLen = reg.length;

        list = new Pending[](regLen);

        bytes32[] storage keys = ownerPositions[pid][owner];
        uint256 klen = keys.length;

        for (uint256 r; r < regLen;) {
            IERC20 tok = reg[r];
            uint256 total;
            for (uint256 i; i < klen;) {
                total += _pendingForPosTok(keys[i], tok, pid);
                unchecked {
                    ++i;
                }
            }
            list[r] = Pending({token: tok, amount: total});
            unchecked {
                ++r;
            }
        }
    }

    /// @dev full helper that computes pending reward for a position key and token for given pool using tick range
    function _pendingForPosTok(bytes32 posKey, IERC20 tok, PoolId pid) internal view returns (uint256) {
        uint128 liq = positionLiquidity[posKey];
        RangePosition.State storage ps = positionRewards[posKey][tok];
        if (liq == 0) {
            return ps.rewardsAccrued;
        }
        TickRange storage tr = positionTicks[posKey];
        uint256 rangeRpl = poolRewards[pid].rangeRplX128(address(tok), tr.lower, tr.upper);
        uint256 delta;
        unchecked {
            delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
        }
        return ps.rewardsAccrued + FullMath.mulDiv(delta, liq, FixedPoint128.Q128);
    }

    /// @dev internal helper to update pool state by pid
    function _updatePoolByPid(PoolId pid) internal {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        _updatePool(pid, currentTick);
    }

    /// @dev internal helper to update pool state
    function _updatePool(PoolId pid, int24 currentTick) internal {
        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 len = reg.length;
        if (len == 0) return;

        RangePool.State storage pool = poolRewards[pid];
        uint256 poolLast = pool.lastUpdated;
        uint256 nowTs = block.timestamp;

        address[] memory addrs = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i; i < len;) {
            IERC20 tok = reg[i];
            addrs[i] = address(tok);
            uint256 amt;
            IncentiveInfo storage info = incentives[pid][tok];
            if (info.rewardRate > 0) {
                uint256 endTs = nowTs < info.periodFinish ? nowTs : info.periodFinish;
                if (endTs > poolLast) {
                    uint256 activeSeconds = endTs - poolLast;
                    amt = uint256(info.rewardRate) * activeSeconds;
                }
            }
            amounts[i] = amt;
            unchecked {
                ++i;
            }
        }
        // Always call sync when initialized so tick adjusts even if dt == 0
        pool.sync(addrs, amounts, poolTickSpacing[pid], currentTick);

        // Bookkeeping for reward tokens
        for (uint256 i; i < len;) {
            IERC20 tok = reg[i];
            IncentiveInfo storage info = incentives[pid][tok];
            if (info.rewardRate == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 dt = nowTs - info.lastUpdate;
            if (dt > 0) {
                uint256 cappedTimestamp = nowTs > info.periodFinish ? info.periodFinish : nowTs;
                if (cappedTimestamp > info.lastUpdate) {
                    dt = cappedTimestamp - info.lastUpdate;
                    uint256 streamed = dt * info.rewardRate;
                    if (streamed > info.remaining) streamed = info.remaining;
                    info.remaining -= uint128(streamed);
                }

                info.lastUpdate = uint64(nowTs);
                if (nowTs >= info.periodFinish || info.remaining == 0) {
                    // Deactivate
                    info.remaining = 0;
                    info.rewardRate = 0;
                    emit IncentiveDeactivated(pid, tok);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev internal: claim rewards for a position and transfer to recipient
    function _claimRewards(bytes32 posKey, IERC20 token, address recipient) internal returns (uint256 amount) {
        amount = positionRewards[posKey][token].claim();
        if (amount > 0) {
            token.safeTransfer(recipient, amount);
            emit Claimed(recipient, token, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SUBSCRIPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PositionManagerAdapter when a new position is created (context-based).
    function notifySubscribeWithContext(
        uint256 tokenId,
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Add position and store tokenId
        RangePosition.addPosition(
            ownerPositions, positionLiquidity, positionOwner, positionIndex, pid, owner, positionKey, liquidity
        );

        // save tick range and tokenId
        positionTicks[positionKey] = TickRange({lower: tickLower, upper: tickUpper});
        positionTokenIds[positionKey] = tokenId;

        // Update pool state once (batched) using adapter-provided tick
        _updatePool(pid, currentTick);

        // Apply add liquidity first so tick outside is initialised for tokens if flips occur
        _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, SafeCast.toInt128(uint256(liquidity)), true);

        // Clear stale per-token state and baseline reward tokens to current inside RPL
        _clearAndBaselineOnSubscribe(pid, positionKey, tickLower, tickUpper);
    }

    /// @notice Optimized unsubscribe path with pre-fetched context from the adapter (forfeit rewards)
    function notifyUnsubscribeWithContext(
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyPositionManagerAdapter {
        // If already not tracked (force-unsubscribed) but still called, return
        if (positionTokenIds[positionKey] == 0) return;

        // Apply removal of liquidity in pool accounting
        PoolId pid = PoolId.wrap(poolIdRaw);
        if (liquidity != 0) {
            _applyLiquidityDeltaByPid(
                pid,
                tickLower,
                tickUpper,
                -SafeCast.toInt128(uint256(liquidity)),
                false // removals: no per-token outside init writes
            );
        }

        // Forfeit: clear local position state and owner index
        RangePosition.removePosition(ownerPositions, positionLiquidity, positionOwner, positionIndex, pid, positionKey);
        delete positionTicks[positionKey];
        delete positionTokenIds[positionKey];
    }

    /// @notice Called by PositionManagerAdapter when a position is burned (context-based).
    function notifyBurnWithContext(
        bytes32 positionKey,
        bytes32 poolIdRaw,
        address ownerAddr,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyPositionManagerAdapter {
        // If already not tracked (force-unsubscribed) but still called, return
        if (positionTokenIds[positionKey] == 0) return;

        // Update pool state once (batched) using adapter-provided tick
        PoolId pid = PoolId.wrap(poolIdRaw);
        _updatePool(pid, currentTick);

        // Batch accrue across all tokens, remove once
        _accrueAcrossTokens(pid, positionKey, tickLower, tickUpper, uint128(liquidity));

        if (liquidity != 0) {
            _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, -SafeCast.toInt128(uint256(liquidity)), false);
        }

        // Claim rewards to stored owner
        _claimAcrossTokens(pid, positionKey, ownerAddr, true);

        // Remove position tracking
        RangePosition.removePosition(ownerPositions, positionLiquidity, positionOwner, positionIndex, pid, positionKey);
        delete positionTicks[positionKey];
        delete positionTokenIds[positionKey];
    }

    /// @notice Called by PositionManagerAdapter when a position's liquidity is modified (context-based).
    function notifyModifyLiquidityWithContext(
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityChange,
        uint128 liquidityAfter
    ) external onlyPositionManagerAdapter {
        // If already not tracked (force-unsubscribed) but still called, return
        if (positionTokenIds[positionKey] == 0) return;

        // Always update cached liquidity
        PoolId pid = PoolId.wrap(poolIdRaw);
        positionLiquidity[positionKey] = liquidityAfter;

        // Batch update pool once using adapter-provided tick
        _updatePool(pid, currentTick);

        // Accrue rewards with liquidity before change across all tokens (cast-safe)
        int128 delta128 = SafeCast.toInt128(liquidityChange);
        uint128 liquidityBefore =
            delta128 >= 0 ? liquidityAfter - uint128(uint128(delta128)) : liquidityAfter + uint128(uint128(-delta128));

        _accrueAcrossTokens(pid, positionKey, tickLower, tickUpper, liquidityBefore);

        // Apply user-requested delta once; on positive adds pass all tokens to ensure per-token outside init on first flips. On removals (and zero) pass empty list to avoid unnecessary writes
        _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, SafeCast.toInt128(liquidityChange), liquidityChange > 0);
    }
}
