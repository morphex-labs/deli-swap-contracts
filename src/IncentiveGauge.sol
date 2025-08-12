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
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
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
 *         new stream.
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

    struct Pending {
        IERC20 token;
        uint256 amount;
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
    // Cache latest liquidity for each positionKey (token-agnostic)
    mapping(bytes32 => uint128) internal positionLiquidity;

    // track tick range per position key
    struct TickRange {
        int24 lower;
        int24 upper;
    }

    mapping(bytes32 => TickRange) internal positionTicks;
    mapping(bytes32 => uint256) internal positionTokenIds;

    // per pool list of active incentive tokens
    mapping(PoolId => IERC20[]) internal poolTokens;

    // whitelist of reward tokens
    mapping(IERC20 => bool) public whitelist;

    // cache tickSpacing per pool
    mapping(PoolId => int24) internal poolTickSpacing;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event WhitelistSet(IERC20 indexed token, bool allowed);
    event IncentiveCreated(PoolId indexed pid, IERC20 indexed token, uint256 amount, uint256 rate);
    event Claimed(address indexed user, IERC20 indexed token, uint256 amount);
    event HookAuthorised(address hook, bool enabled);
    event PositionManagerAdapterUpdated(address newAdapter);

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

    function setHook(address hook, bool enabled) external onlyOwner {
        if (hook == address(0)) revert DeliErrors.ZeroAddress();
        isHook[hook] = enabled;
        emit HookAuthorised(hook, enabled);
    }

    function setWhitelist(IERC20 token, bool ok) external onlyOwner {
        whitelist[token] = ok;
        emit WhitelistSet(token, ok);
    }

    function setPositionManagerAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert DeliErrors.ZeroAddress();
        positionManagerAdapter = IPositionManagerAdapter(_adapter);
        emit PositionManagerAdapterUpdated(_adapter);
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
        IncentiveInfo storage info = incentives[pid][rewardToken];

        // Update pool with old rate before changing it
        if (info.rewardRate > 0) {
            _updatePoolByPid(pid);
        }

        // pull tokens
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 leftover;
        if (block.timestamp < info.periodFinish) {
            uint256 remainingTime = info.periodFinish - block.timestamp;
            leftover = remainingTime * info.rewardRate;

            // Prevent griefing: new deposit must be larger than remaining rewards
            if (amount <= leftover) {
                revert DeliErrors.InsufficientIncentive();
            }
        }

        uint256 newTotal = amount + leftover;
        info.rewardRate = uint128(newTotal / TimeLibrary.WEEK);
        info.periodFinish = uint64(block.timestamp + TimeLibrary.WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = uint128(newTotal);

        emit IncentiveCreated(pid, rewardToken, amount, info.rewardRate);

        // Track token in pool list if first time
        _addTokenToPool(pid, rewardToken);

        // pool initialization is handled exclusively by the hook via initPool
    }

    /// @notice Claim accrued token rewards for a single position.
    /// @param tokenId The NFT token ID of the position to claim for.
    /// @param token The token to claim rewards for.
    /// @param to The address to transfer the rewards to.
    function claim(uint256 tokenId, IERC20 token, address to) external returns (uint256 amount) {
        // Verify the caller owns the position
        address owner = positionManagerAdapter.ownerOf(tokenId);
        if (msg.sender != owner) revert DeliErrors.NotAuthorized();

        (PoolKey memory key,) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // Update pool state (by pid) and accrue for the single token
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
            uint256 keyLen = keys.length;
            if (keyLen == 0) continue;

            // Skip pools without active tokens
            if (poolTokens[pid].length == 0) continue;

            // Update pool once per pid
            _updatePoolByPid(pid);

            // Accrue and claim for every position
            for (uint256 i; i < keyLen; ++i) {
                bytes32 posKey = keys[i];

                // Verify this position still belongs to the owner
                uint256 tokenId = positionTokenIds[posKey];
                if (tokenId == 0) continue; // Position was removed

                // Check ownership (use try-catch to handle burned tokens)
                try positionManagerAdapter.ownerOf(tokenId) returns (address currentOwner) {
                    if (currentOwner != owner) continue; // Skip if no longer owned
                } catch {
                    continue; // Skip if token doesn't exist or ownerOf reverts
                }

                _accrueAndClaimForPosition(pid, posKey, owner);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice List active reward tokens for a pool.
    function poolTokensOf(PoolId pid) external view returns (IERC20[] memory list) {
        list = poolTokens[pid];
    }

    /// @notice Basic incentive data for APR calculations.
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
    function incentiveDataBatch(PoolId pid, IERC20[] calldata tokens)
        external
        view
        returns (uint256[] memory rewardRates, uint256[] memory finishes, uint256[] memory remainings)
    {
        uint256 len = tokens.length;
        rewardRates = new uint256[](len);
        finishes = new uint256[](len);
        remainings = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            IncentiveInfo storage info = incentives[pid][tokens[i]];
            rewardRates[i] = info.rewardRate;
            finishes[i] = info.periodFinish;
            remainings[i] = info.remaining;
        }
    }

    /// @notice Returns pending rewards for a position by tokenId and specific token.
    function pendingRewardsByTokenId(uint256 tokenId, IERC20 token) external view returns (uint256 amount) {
        amount = _pendingRewardsByTokenId(tokenId, token);
    }

    /// @notice Batch version, returns array aligned to `tokens` input for a given tokenId
    function pendingRewardsByTokenIdBatch(uint256 tokenId, IERC20[] calldata tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 len = tokens.length;
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            amounts[i] = _pendingRewardsByTokenId(tokenId, tokens[i]);
        }
    }

    /// @notice Aggregate pending rewards (all tokens) for an owner in a pool
    function pendingRewardsOwner(PoolId pid, address owner) external view returns (Pending[] memory list) {
        list = _pendingRewardsForPool(pid, owner);
    }

    /// @notice Batch version, returns array aligned to `pids` input, each element is Pending array for that pool
    function pendingRewardsOwnerBatch(PoolId[] calldata pids, address owner)
        external
        view
        returns (Pending[][] memory lists)
    {
        uint256 plen = pids.length;
        lists = new Pending[][](plen);
        for (uint256 p; p < plen; ++p) {
            lists[p] = _pendingRewardsForPool(pids[p], owner);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper to accrue and claim for a single position across all tokens
    function _accrueAndClaimForPosition(PoolId pid, bytes32 posKey, address ownerAddr) internal {
        IERC20[] storage toks = poolTokens[pid];
        TickRange storage tr = positionTicks[posKey];
        uint128 liq = positionLiquidity[posKey];
        RangePool.State storage pool = poolRewards[pid];
        for (uint256 t; t < toks.length; ++t) {
            IERC20 tok = toks[t];
            RangePosition.State storage ps = positionRewards[posKey][tok];
            uint256 rpl = pool.rangeRplX128(address(tok), tr.lower, tr.upper);
            ps.accrue(liq, rpl);
            uint256 amt = ps.claim();
            if (amt > 0) {
                tok.safeTransfer(ownerAddr, amt);
                emit Claimed(ownerAddr, tok, amt);
            }
        }
    }

    /// @dev Accrue across all tokens for a position
    function _accrueAcrossTokens(PoolId pid, bytes32 positionKey, int24 lower, int24 upper, uint128 liquidity)
        internal
    {
        IERC20[] storage toks = poolTokens[pid];
        RangePool.State storage pool = poolRewards[pid];
        for (uint256 i; i < toks.length; ++i) {
            IERC20 tok = toks[i];
            RangePosition.State storage ps = positionRewards[positionKey][tok];
            uint256 rpl = pool.rangeRplX128(address(tok), lower, upper);
            ps.accrue(liquidity, rpl);
        }
    }

    /// @dev Claim across all tokens for a position
    function _claimAcrossTokens(PoolId pid, bytes32 positionKey, address to, bool clear) internal {
        IERC20[] storage toks = poolTokens[pid];
        for (uint256 i; i < toks.length; ++i) {
            _claimRewards(positionKey, toks[i], to);
            if (clear) delete positionRewards[positionKey][toks[i]];
        }
    }

    /// @dev Remove position indices and clear per-token state if fully settled and zero-liquidity
    function _prunePositionIfSettled(PoolId pid, bytes32 posKey, address ownerAddr) internal {
        if (positionLiquidity[posKey] != 0) return;
        IERC20[] storage toks = poolTokens[pid];
        for (uint256 i; i < toks.length; ++i) {
            if (positionRewards[posKey][toks[i]].rewardsAccrued != 0) {
                return;
            }
        }
        // Remove indices and clean tick/tokenId mapping
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, ownerAddr, posKey);
        delete positionTicks[posKey];
        delete positionTokenIds[posKey];
        // Clear per-token state
        for (uint256 i; i < toks.length; ++i) {
            delete positionRewards[posKey][toks[i]];
        }
    }

    /// @dev Apply liquidity delta using only pid; positiveAdd indicates whether to pass token list for outside init
    function _applyLiquidityDeltaByPid(PoolId pid, int24 lower, int24 upper, int128 liquidityDelta, bool positiveAdd)
        internal
    {
        address[] memory addrs;
        if (positiveAdd) {
            IERC20[] storage toks = poolTokens[pid];
            addrs = new address[](toks.length);
            for (uint256 i; i < toks.length; ++i) {
                addrs[i] = address(toks[i]);
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

    /// @dev internal helper to add a token to a pool
    function _addTokenToPool(PoolId pid, IERC20 token) internal {
        IERC20[] storage arr = poolTokens[pid];
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == token) return;
        }
        arr.push(token);
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
                uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
                amount = ps.rewardsAccrued + (delta * liq) / FixedPoint128.Q128;
            } else {
                amount = ps.rewardsAccrued;
            }
        } catch {
            amount = 0;
        }
    }

    /// @dev internal helper to compute pending list for one pool
    function _pendingRewardsForPool(PoolId pid, address owner) internal view returns (Pending[] memory list) {
        IERC20[] storage toks = poolTokens[pid];
        uint256 tlen = toks.length;
        list = new Pending[](tlen);

        bytes32[] storage keys = ownerPositions[pid][owner];
        uint256 klen = keys.length;

        for (uint256 t; t < tlen; ++t) {
            IERC20 tok = toks[t];
            uint256 total;
            for (uint256 i; i < klen; ++i) {
                total += _pendingForPosTok(keys[i], tok, pid);
            }
            list[t] = Pending({token: tok, amount: total});
        }
    }

    /// @dev full helper that computes pending reward for a position key and token for given pool using tick range
    function _pendingForPosTok(bytes32 posKey, IERC20 tok, PoolId pid) internal view returns (uint256) {
        // If position has no liquidity, no rewards
        if (positionLiquidity[posKey] == 0) {
            return positionRewards[posKey][tok].rewardsAccrued;
        }

        TickRange storage tr = positionTicks[posKey];
        uint256 rangeRpl = poolRewards[pid].rangeRplX128(address(tok), tr.lower, tr.upper);
        uint256 delta = rangeRpl - positionRewards[posKey][tok].rewardsPerLiquidityLastX128;
        return positionRewards[posKey][tok].rewardsAccrued + (delta * positionLiquidity[posKey]) / FixedPoint128.Q128;
    }

    /// @dev internal helper to update pool state by pid
    function _updatePoolByPid(PoolId pid) internal {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        _updatePool(pid, currentTick);
    }

    /// @dev internal helper to update pool state
    function _updatePool(PoolId pid, int24 currentTick) internal {
        IERC20[] storage toks = poolTokens[pid];
        uint256 len = toks.length;
        if (len == 0) return;

        RangePool.State storage pool = poolRewards[pid];
        uint256 poolLast = pool.lastUpdated;
        uint256 nowTs = block.timestamp;

        address[] memory addrs = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            IERC20 tok = toks[i];
            addrs[i] = address(tok);

            uint256 amt = 0;
            IncentiveInfo storage info = incentives[pid][tok];
            if (info.rewardRate > 0) {
                uint256 endTs = nowTs < info.periodFinish ? nowTs : info.periodFinish;
                if (endTs > poolLast) {
                    uint256 activeSeconds = endTs - poolLast;
                    amt = uint256(info.rewardRate) * activeSeconds;
                }
            }
            amounts[i] = amt;
        }
        // Always call sync when initialized so tick adjusts even if dt == 0
        pool.sync(addrs, amounts, poolTickSpacing[pid], currentTick);

        // Bookkeeping for all tokens
        for (uint256 i; i < len; ++i) {
            IERC20 tok = toks[i];
            IncentiveInfo storage info = incentives[pid][tok];
            if (info.rewardRate == 0) continue;

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
                if (nowTs >= info.periodFinish) {
                    info.remaining = 0; // clear residual rounding when stream ended
                    info.rewardRate = 0;
                } else if (info.remaining == 0) {
                    info.rewardRate = 0;
                }
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

    /// @notice Called by PositionManagerAdapter when a new position is created.
    function notifySubscribe(uint256 tokenId, bytes memory) external onlyPositionManagerAdapter {
        (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManagerAdapter.getPositionLiquidity(tokenId);
        address owner = positionManagerAdapter.ownerOf(tokenId);

        PoolId pid = key.toId();
        IERC20[] storage toks = poolTokens[pid];

        // index position key once
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // Early exit if no tokens
        if (toks.length == 0) {
            // Still need to track the position even if no tokens
            RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, positionKey, liquidity);
            positionTicks[positionKey] = TickRange({lower: info.tickLower(), upper: info.tickUpper()});
            positionTokenIds[positionKey] = tokenId;
            // Update shared pool liquidity and tick topology even when there are no tokens yet
            _applyLiquidityDeltaByPid(
                pid, info.tickLower(), info.tickUpper(), SafeCast.toInt128(uint256(liquidity)), false
            );
            return;
        }

        RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, positionKey, liquidity);

        // save tick range and tokenId
        positionTicks[positionKey] = TickRange({lower: info.tickLower(), upper: info.tickUpper()});
        positionTokenIds[positionKey] = tokenId;

        // Update pool state once (batched)
        _updatePoolByPid(pid);

        // Apply add liquidity first so tick outside is initialised for tokens if flips occur
        _applyLiquidityDeltaByPid(pid, info.tickLower(), info.tickUpper(), SafeCast.toInt128(uint256(liquidity)), true);

        // Snapshot rewards for each token AFTER outside init to avoid non-monotonic deltas
        for (uint256 t; t < toks.length; ++t) {
            IERC20 tok = toks[t];
            positionRewards[positionKey][tok].initSnapshot(
                poolRewards[pid].rangeRplX128(address(tok), info.tickLower(), info.tickUpper())
            );
        }
    }

    /// @notice Optimized unsubscribe path with pre-fetched context from the adapter
    /// @dev Context layout: (bytes32 poolIdRaw, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)
    function notifyUnsubscribeWithContext(uint256 tokenId, bytes calldata data) external onlyPositionManagerAdapter {
        (bytes32 poolIdRaw, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick) =
            abi.decode(data, (bytes32, int24, int24, uint128, int24));

        PoolId pid = PoolId.wrap(poolIdRaw);
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // Early exit if no active incentive tokens; clean indices immediately
        if (poolTokens[pid].length == 0) {
            RangePosition.removePosition(
                ownerPositions, positionLiquidity, pid, positionManagerAdapter.ownerOf(tokenId), positionKey
            );
            delete positionTicks[positionKey];
            delete positionTokenIds[positionKey];
            return;
        }

        // Update pool state (use provided tick and cached spacing)
        _updatePool(pid, currentTick);

        // Accrue across all pool tokens
        _accrueAcrossTokens(pid, positionKey, tickLower, tickUpper, liquidity);

        // Apply removal of liquidity in pool accounting
        if (liquidity != 0) {
            _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, -SafeCast.toInt128(uint256(liquidity)), false);
        }

        // Defer all claims for consistency; keep per-token state for later claim and prune
        positionLiquidity[positionKey] = 0;
    }

    /// @notice Called by PositionManagerAdapter when a position is burned.
    function notifyBurn(uint256 tokenId, address ownerAddr, PositionInfo info, uint256 liquidity, BalanceDelta)
        external
        onlyPositionManagerAdapter
    {
        // For burned positions, we can't look up the tokenId normally
        // Instead, use the PositionInfo to get the PoolKey via IPoolKeys
        PoolKey memory key = positionManagerAdapter.getPoolKeyFromPositionInfo(info);
        PoolId pid = key.toId();
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // Early exit if no tokens
        if (poolTokens[pid].length == 0) {
            RangePosition.removePosition(ownerPositions, positionLiquidity, pid, ownerAddr, positionKey);
            delete positionTicks[positionKey];
            delete positionTokenIds[positionKey];
            return;
        }

        // Update pool state once (batched)
        _updatePoolByPid(pid);

        // Batch accrue across all tokens, remove once, then clean
        _accrueAcrossTokens(pid, positionKey, info.tickLower(), info.tickUpper(), uint128(liquidity));

        if (liquidity != 0) {
            _applyLiquidityDeltaByPid(
                pid, info.tickLower(), info.tickUpper(), -SafeCast.toInt128(uint256(liquidity)), false
            );
        }

        _claimAcrossTokens(pid, positionKey, ownerAddr, true);

        // Clean up position tracking
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, ownerAddr, positionKey);
        delete positionTicks[positionKey];
        delete positionTokenIds[positionKey];
    }

    /// @notice Called by PositionManagerAdapter when a position's liquidity is modified.
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta)
        external
        onlyPositionManagerAdapter
    {
        (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();
        address owner = positionManagerAdapter.ownerOf(tokenId);

        uint128 currentLiq = positionManagerAdapter.getPositionLiquidity(tokenId);
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // Always update cached liquidity (keep position tracked even at 0)
        positionLiquidity[positionKey] = currentLiq;

        // Early exit if no tokens
        if (poolTokens[pid].length == 0) {
            return;
        }

        // Batch update pool once
        _updatePoolByPid(pid);

        // Accrue rewards with liquidity before change across all tokens
        uint128 liquidityBefore;
        if (liquidityChange >= 0) {
            liquidityBefore = currentLiq - uint128(uint256(liquidityChange));
        } else {
            liquidityBefore = currentLiq + uint128(uint256(-liquidityChange));
        }
        _accrueAcrossTokens(pid, positionKey, info.tickLower(), info.tickUpper(), liquidityBefore);

        // Apply user-requested delta once; on positive adds pass all tokens to ensure per-token outside init on first flips. On removals (and zero) pass empty list to avoid unnecessary writes.
        _applyLiquidityDeltaByPid(
            pid, info.tickLower(), info.tickUpper(), SafeCast.toInt128(liquidityChange), liquidityChange > 0
        );

        // Auto-claim if liquidity is now zero
        if (currentLiq == 0) {
            _claimAcrossTokens(pid, positionKey, owner, false);
        }
    }
}
