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
                            CONSTANTS & IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // active incentive tokens or queue size to prevent griefing
    uint8 internal constant MAX_INCENTIVE_TOKEN_LIMIT = 3;

    IPoolManager public immutable POOL_MANAGER;

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

    // per pool fixed-slot set of ACTIVE incentive tokens
    struct TokenSet {
        uint8 count;
        IERC20[MAX_INCENTIVE_TOKEN_LIMIT] tokens;
    }

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

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

    mapping(bytes32 => TickRange) internal positionTicks;
    mapping(bytes32 => uint256) internal positionTokenIds;

    // per pool fixed-slot set of ACTIVE incentive tokens
    mapping(PoolId => TokenSet) internal poolTokenSet;

    // registry of all tokens ever used by a pool
    mapping(PoolId => IERC20[]) internal poolTokenRegistry;
    mapping(PoolId => mapping(IERC20 => bool)) internal inRegistry;

    // whitelist of reward tokens
    mapping(IERC20 => bool) public whitelist;

    // cache tickSpacing per pool
    mapping(PoolId => int24) internal poolTickSpacing;

    // Exit snapshot for deferred view calculations
    mapping(bytes32 => uint128) internal exitLiquidity;
    // Token-keyed exit snapshots to remain correct across active set swaps
    mapping(bytes32 => mapping(IERC20 => uint256)) internal exitSnapshots;

    // Standby queue for overflow incentives
    mapping(PoolId => IERC20[]) internal queuedTokens; // FIFO
    mapping(PoolId => mapping(IERC20 => uint256)) internal queuedAmounts; // amount per queued token
    mapping(PoolId => mapping(IERC20 => bool)) internal isQueued; // guard to prevent duplicates

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WhitelistSet(IERC20 indexed token, bool allowed);
    event Claimed(address indexed user, IERC20 indexed token, uint256 amount);
    event HookAuthorised(address hook, bool enabled);
    event PositionManagerAdapterUpdated(address newAdapter);
    event IncentiveActivated(PoolId indexed pid, IERC20 indexed token, uint256 amount, uint256 rate);
    event IncentiveQueued(PoolId indexed pid, IERC20 indexed token, uint256 amount);
    event IncentiveDeactivated(PoolId indexed pid, IERC20 indexed token);

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

        // pull tokens up-front
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        // register token in pool registry for future claims (active or inactive)
        if (!inRegistry[pid][rewardToken]) {
            inRegistry[pid][rewardToken] = true;
            poolTokenRegistry[pid].push(rewardToken);
        }

        // If token is already active, update as today
        TokenSet storage active = poolTokenSet[pid];
        if (_isActiveToken(active, rewardToken)) {
            uint128 newRate = _topUpActive(pid, rewardToken, amount);
            emit IncentiveActivated(pid, rewardToken, amount, newRate);
            return;
        }

        // Not currently active
        if (active.count < MAX_INCENTIVE_TOKEN_LIMIT) {
            uint8 slot = active.count;
            active.count = slot + 1;
            uint128 rate = _activateIntoSlot(pid, rewardToken, amount, slot);
            emit IncentiveActivated(pid, rewardToken, amount, rate);
            return;
        }

        // Active set full: enqueue
        _enqueue(pid, rewardToken, amount);
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

        // Update pool state (by pid).
        // If the position has been unsubscribed for this token, any pending rewards are accrued
        // via the per-token exit snapshot in _finalizeExitForToken(); ps.accrue below will then
        // simply advance the snapshot when liquidity is zero.
        _updatePoolByPid(pid);
        _finalizeExitForToken(pid, positionKey, token);
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

            // Skip pools with neither active nor registered tokens
            if (poolTokenSet[pid].count == 0 && poolTokenRegistry[pid].length == 0) continue;

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

                // Finalize any per-token exit snapshots for active tokens first (unsubscribed
                // positions accrue via exit snapshots rather than live accrual here).
                _finalizeExitForPosition(pid, posKey);
                // Then handle accrual/claims across all registered tokens (active and inactive).
                _accrueAndClaimForPosition(pid, posKey, owner);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice List active reward tokens for a pool.
    function poolTokensOf(PoolId pid) external view returns (IERC20[] memory list) {
        TokenSet storage ts = poolTokenSet[pid];
        uint8 n = ts.count;
        list = new IERC20[](n);
        for (uint8 i; i < n; ++i) {
            list[i] = ts.tokens[i];
        }
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

    /// @notice View queued tokens for a pool (FIFO order) and their total queued amounts
    function queuedTokensOf(PoolId pid) external view returns (IERC20[] memory tokens, uint256[] memory amounts) {
        IERC20[] storage q = queuedTokens[pid];
        uint256 len = q.length;
        tokens = new IERC20[](len);
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            IERC20 t = q[i];
            tokens[i] = t;
            amounts[i] = queuedAmounts[pid][t];
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Top up an already-active token incentive and recompute rate
    function _topUpActive(PoolId pid, IERC20 token, uint256 addAmount) internal returns (uint128 newRate) {
        IncentiveInfo storage info = incentives[pid][token];
        if (info.rewardRate > 0) {
            _updatePoolByPid(pid);
        }

        // Re-validate that the token is still active after the pool update
        TokenSet storage active = poolTokenSet[pid];
        if (!_isActiveToken(active, token)) revert DeliErrors.NotAllowed();

        uint256 leftover;
        if (block.timestamp < info.periodFinish) {
            uint256 remainingTime = info.periodFinish - block.timestamp;
            leftover = remainingTime * info.rewardRate;
            if (addAmount <= leftover) revert DeliErrors.InsufficientIncentive();
        }
        uint256 newTotal = addAmount + leftover;
        info.rewardRate = uint128(newTotal / TimeLibrary.WEEK);
        info.periodFinish = uint64(block.timestamp + TimeLibrary.WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = uint128(newTotal);
        return info.rewardRate;
    }

    /// @dev Activate a token into a specific active slot and initialize its schedule
    function _activateIntoSlot(PoolId pid, IERC20 token, uint256 amount, uint8 slotIndex)
        internal
        returns (uint128 rate)
    {
        IncentiveInfo storage info = incentives[pid][token];
        rate = uint128(amount / TimeLibrary.WEEK);
        info.rewardRate = rate;
        info.periodFinish = uint64(block.timestamp + TimeLibrary.WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = uint128(amount);
        poolTokenSet[pid].tokens[slotIndex] = token;
    }

    /// @dev Enqueue a token for later activation; accumulates amount and emits event on every top-up
    function _enqueue(PoolId pid, IERC20 token, uint256 amount) internal {
        if (!isQueued[pid][token]) {
            if (queuedTokens[pid].length >= MAX_INCENTIVE_TOKEN_LIMIT) revert DeliErrors.NotAllowed();
            queuedTokens[pid].push(token);
            isQueued[pid][token] = true;
        }
        queuedAmounts[pid][token] += amount;
        emit IncentiveQueued(pid, token, amount);
    }

    /// @dev Fill a freed active slot from the queue if available
    function _refillFromQueue(PoolId pid, uint8 slotIndex, uint256 nowTs) internal returns (bool filled) {
        IERC20[] storage q = queuedTokens[pid];
        while (q.length != 0) {
            IERC20 qtok = q[0];
            uint256 last = q.length - 1;
            // FIFO: shift-left the array and pop tail
            for (uint256 i; i < last;) {
                q[i] = q[i + 1];
                unchecked {
                    ++i;
                }
            }
            q.pop();
            isQueued[pid][qtok] = false;
            uint256 qamt = queuedAmounts[pid][qtok];
            if (qamt == 0) continue;
            delete queuedAmounts[pid][qtok];

            IncentiveInfo storage qi = incentives[pid][qtok];
            qi.rewardRate = uint128(qamt / TimeLibrary.WEEK);
            qi.periodFinish = uint64(nowTs + TimeLibrary.WEEK);
            qi.lastUpdate = uint64(nowTs);
            qi.remaining = uint128(qamt);

            poolTokenSet[pid].tokens[slotIndex] = qtok;
            emit IncentiveActivated(pid, qtok, qamt, qi.rewardRate);
            return true;
        }
        return false;
    }

    /// @dev Helper to accrue and claim for a single position across all tokens
    function _accrueAndClaimForPosition(PoolId pid, bytes32 posKey, address ownerAddr) internal {
        TokenSet storage active = poolTokenSet[pid];
        TickRange storage tr = positionTicks[posKey];
        uint128 liq = positionLiquidity[posKey];
        RangePool.State storage pool = poolRewards[pid];

        IERC20[] storage reg = poolTokenRegistry[pid];
        uint256 rlen = reg.length;
        for (uint256 i; i < rlen; ++i) {
            IERC20 tok = reg[i];
            if (_isActiveToken(active, tok)) {
                RangePosition.State storage ps = positionRewards[posKey][tok];
                uint256 rpl = pool.rangeRplX128(address(tok), tr.lower, tr.upper);
                ps.accrue(liq, rpl);
            } else {
                _finalizeExitForToken(pid, posKey, tok);
            }
            _claimRewards(posKey, tok, ownerAddr);
        }
    }

    /// @dev Check if a token is active in the pool's active token set
    function _isActiveToken(TokenSet storage active, IERC20 tok) private view returns (bool) {
        uint8 n = active.count;
        for (uint8 i; i < n;) {
            if (active.tokens[i] == tok) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Accrue across all tokens for a position
    function _accrueAcrossTokens(PoolId pid, bytes32 positionKey, int24 lower, int24 upper, uint128 liquidity)
        internal
    {
        TokenSet storage ts = poolTokenSet[pid];
        RangePool.State storage pool = poolRewards[pid];
        uint8 n = ts.count;
        for (uint8 i; i < n; ++i) {
            IERC20 tok = ts.tokens[i];
            RangePosition.State storage ps = positionRewards[positionKey][tok];
            uint256 rpl = pool.rangeRplX128(address(tok), lower, upper);
            ps.accrue(liquidity, rpl);
        }
    }

    /// @dev Claim across all tokens for a position
    function _claimAcrossTokens(PoolId pid, bytes32 positionKey, address to, bool clear) internal {
        TokenSet storage ts = poolTokenSet[pid];
        uint8 n = ts.count;
        for (uint8 i; i < n; ++i) {
            IERC20 tok = ts.tokens[i];
            _claimRewards(positionKey, tok, to);
            if (clear) delete positionRewards[positionKey][tok];
        }
    }

    /// @dev Finalize snapshot for a single token if present
    function _finalizeExitForToken(PoolId, /*pid*/ bytes32 positionKey, IERC20 token) internal {
        uint256 snap = exitSnapshots[positionKey][token];
        if (snap != 0) {
            RangePosition.State storage ps = positionRewards[positionKey][token];
            uint256 delta = snap - ps.rewardsPerLiquidityLastX128;
            if (delta != 0) {
                ps.rewardsAccrued += FullMath.mulDiv(delta, exitLiquidity[positionKey], FixedPoint128.Q128);
                ps.rewardsPerLiquidityLastX128 = snap;
            }
            exitSnapshots[positionKey][token] = 0;
        }
    }

    /// @dev Finalize snapshots across all tokens for a position
    function _finalizeExitForPosition(PoolId pid, bytes32 positionKey) internal {
        TokenSet storage ts = poolTokenSet[pid];
        uint8 n = ts.count;
        for (uint8 i; i < n; ++i) {
            IERC20 tok = ts.tokens[i];
            uint256 snapTok = exitSnapshots[positionKey][tok];
            if (snapTok == 0) continue;
            RangePosition.State storage ps = positionRewards[positionKey][tok];
            uint256 delta = snapTok - ps.rewardsPerLiquidityLastX128;
            if (delta != 0) {
                ps.rewardsAccrued += FullMath.mulDiv(delta, exitLiquidity[positionKey], FixedPoint128.Q128);
                ps.rewardsPerLiquidityLastX128 = snapTok;
            }
            exitSnapshots[positionKey][tok] = 0;
        }
    }

    /// @dev Apply liquidity delta using only pid; positiveAdd indicates whether to pass token list for outside init
    function _applyLiquidityDeltaByPid(PoolId pid, int24 lower, int24 upper, int128 liquidityDelta, bool positiveAdd)
        internal
    {
        address[] memory addrs;
        if (positiveAdd) {
            TokenSet storage ts = poolTokenSet[pid];
            uint8 n = ts.count;
            addrs = new address[](n);
            for (uint8 i; i < n; ++i) {
                addrs[i] = address(ts.tokens[i]);
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
                // Include exit snapshot debt if present for this token
                uint256 snap = exitSnapshots[positionKey][token];
                if (snap != 0) {
                    uint256 exitDelta;
                    unchecked {
                        exitDelta = snap - ps.rewardsPerLiquidityLastX128;
                    }
                    return
                        ps.rewardsAccrued + FullMath.mulDiv(exitDelta, exitLiquidity[positionKey], FixedPoint128.Q128);
                }
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

        for (uint256 r; r < regLen; ++r) {
            IERC20 tok = reg[r];
            uint256 total;
            for (uint256 i; i < klen; ++i) {
                total += _pendingForPosTok(keys[i], tok, pid);
            }
            list[r] = Pending({token: tok, amount: total});
        }
    }

    /// @dev full helper that computes pending reward for a position key and token for given pool using tick range
    function _pendingForPosTok(bytes32 posKey, IERC20 tok, PoolId pid) internal view returns (uint256) {
        uint128 liq = positionLiquidity[posKey];
        RangePosition.State storage ps = positionRewards[posKey][tok];
        if (liq == 0) {
            // Include exit snapshot debt if present for this token
            uint256 snap = exitSnapshots[posKey][tok];
            if (snap != 0) {
                uint256 exitDelta;
                unchecked {
                    exitDelta = snap - ps.rewardsPerLiquidityLastX128;
                }
                return ps.rewardsAccrued + FullMath.mulDiv(exitDelta, exitLiquidity[posKey], FixedPoint128.Q128);
            }
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
        TokenSet storage active = poolTokenSet[pid];
        uint8 len = active.count;
        if (len == 0) return;

        RangePool.State storage pool = poolRewards[pid];
        uint256 poolLast = pool.lastUpdated;
        uint256 nowTs = block.timestamp;

        address[] memory addrs = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint8 i; i < len; ++i) {
            IERC20 tok = active.tokens[i];
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
        }
        // Always call sync when initialized so tick adjusts even if dt == 0
        pool.sync(addrs, amounts, poolTickSpacing[pid], currentTick);

        // Bookkeeping for active tokens
        for (uint8 i; i < len; ++i) {
            IERC20 tok = active.tokens[i];
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
                if (nowTs >= info.periodFinish || info.remaining == 0) {
                    // Deactivate
                    info.remaining = 0;
                    info.rewardRate = 0;
                    emit IncentiveDeactivated(pid, tok);

                    // Activate next from queue if available
                    _refillFromQueue(pid, i, nowTs);
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

    /// @dev Unsubscribe path: bump cumulatives per token and store snapshots (no per-token ps.accrue)
    function _snapshotExitOnUnsubscribe(PoolId pid, bytes32 positionKey) internal {
        TokenSet storage ts = poolTokenSet[pid];
        uint8 n = ts.count;
        if (n == 0) return;

        RangePool.State storage pool = poolRewards[pid];
        uint128 liq = pool.liquidity;
        uint256 last = pool.lastUpdated;
        uint256 nowTs = block.timestamp;
        bool anyAmt;

        // Common delta for the typical case where periodFinish >= nowTs
        uint256 dtCommon = nowTs - last;

        for (uint8 i; i < n;) {
            if (_bumpAndSnapshotToken(pid, ts, pool, positionKey, i, liq, last, nowTs, dtCommon)) {
                anyAmt = true;
            }
            unchecked {
                ++i;
            }
        }
        if (anyAmt) {
            pool.lastUpdated = uint64(nowTs);
        }
    }

    /// @dev Per-token helper to compute amt, bump cumulative, and snapshot with minimal locals
    function _bumpAndSnapshotToken(
        PoolId pid,
        TokenSet storage ts,
        RangePool.State storage pool,
        bytes32 positionKey,
        uint8 i,
        uint128 liq,
        uint256 last,
        uint256 nowTs,
        uint256 dtCommon
    ) internal returns (bool bumped) {
        IERC20 tok = ts.tokens[i];
        IncentiveInfo storage info = incentives[pid][tok];
        uint256 amt;
        if (info.rewardRate > 0) {
            if (info.periodFinish >= nowTs) {
                unchecked {
                    amt = uint256(info.rewardRate) * dtCommon;
                }
            } else if (info.periodFinish > last) {
                unchecked {
                    amt = uint256(info.rewardRate) * (info.periodFinish - last);
                }
            }
        }

        address aTok = address(tok);
        uint256 c = pool.rewardsPerLiquidityCumulativeX128[aTok];
        if (amt != 0 && liq != 0) {
            uint256 d = (amt << 128) / liq;
            if (d != 0) {
                bumped = true;
                c += d;
                pool.rewardsPerLiquidityCumulativeX128[aTok] = c;
            }
        }
        exitSnapshots[positionKey][tok] = c;
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
        TokenSet storage ts = poolTokenSet[pid];

        // Add position and store tokenId
        RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, positionKey, liquidity);

        // save tick range and tokenId
        positionTicks[positionKey] = TickRange({lower: tickLower, upper: tickUpper});
        positionTokenIds[positionKey] = tokenId;

        // Update pool state once (batched) using adapter-provided tick
        _updatePool(pid, currentTick);

        // Apply add liquidity first so tick outside is initialised for tokens if flips occur
        _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, SafeCast.toInt128(uint256(liquidity)), true);

        // Snapshot rewards for each token AFTER outside init to avoid non-monotonic deltas
        for (uint8 t; t < ts.count; ++t) {
            IERC20 tok = ts.tokens[t];
            uint256 snap = poolRewards[pid].rangeRplX128(address(tok), tickLower, tickUpper);
            if (snap != 0) {
                positionRewards[positionKey][tok].initSnapshot(snap);
            }
        }
    }

    /// @notice Optimized unsubscribe path with pre-fetched context from the adapter
    function notifyUnsubscribeWithContext(
        uint256 tokenId,
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Snapshot exit rewards for each token
        _snapshotExitOnUnsubscribe(pid, positionKey);

        // Apply removal of liquidity in pool accounting
        if (liquidity != 0) {
            // Lazy removal: queue range deltas; immediate in-range L is adjusted inside RangePool
            poolRewards[pid].queueRemoval(tickLower, tickUpper, liquidity);
        }

        // Defer all claims for consistency; keep per-token state for later claim and prune
        exitLiquidity[positionKey] = liquidity;
        positionLiquidity[positionKey] = 0;
    }

    /// @notice Called by PositionManagerAdapter when a position is burned (context-based).
    function notifyBurnWithContext(
        uint256, /*tokenId*/
        bytes32 positionKey,
        bytes32 poolIdRaw,
        address ownerAddr,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Update pool state once (batched) using adapter-provided tick
        _updatePool(pid, currentTick);

        // Batch accrue across all tokens, remove once, then clean
        _accrueAcrossTokens(pid, positionKey, tickLower, tickUpper, uint128(liquidity));

        if (liquidity != 0) {
            _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, -SafeCast.toInt128(uint256(liquidity)), false);
        }

        _claimAcrossTokens(pid, positionKey, ownerAddr, true);

        // Clean up position tracking
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, ownerAddr, positionKey);
        delete positionTicks[positionKey];
        delete positionTokenIds[positionKey];
        delete exitLiquidity[positionKey];
    }

    /// @notice Called by PositionManagerAdapter when a position's liquidity is modified (context-based).
    function notifyModifyLiquidityWithContext(
        uint256, /*tokenId*/
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityChange,
        uint128 liquidityAfter
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Always update cached liquidity (keep position tracked even at 0)
        positionLiquidity[positionKey] = liquidityAfter;

        // Batch update pool once using adapter-provided tick
        _updatePool(pid, currentTick);

        // Accrue rewards with liquidity before change across all tokens (cast-safe)
        int128 delta128 = SafeCast.toInt128(liquidityChange);
        uint128 liquidityBefore =
            delta128 >= 0 ? liquidityAfter - uint128(uint128(delta128)) : liquidityAfter + uint128(uint128(-delta128));

        _accrueAcrossTokens(pid, positionKey, tickLower, tickUpper, liquidityBefore);

        // Apply user-requested delta once; on positive adds pass all tokens to ensure per-token outside init on first flips. On removals (and zero) pass empty list to avoid unnecessary writes.
        _applyLiquidityDeltaByPid(pid, tickLower, tickUpper, SafeCast.toInt128(liquidityChange), liquidityChange > 0);
    }
}
