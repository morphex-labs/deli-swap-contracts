// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EfficientHashLib} from "lib/solady/src/utils/EfficientHashLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IIncentiveGauge} from "./interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "./interfaces/IPositionManagerAdapter.sol";

import {RangePool} from "./libraries/RangePool.sol";
import {RangePosition} from "./libraries/RangePosition.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";

/**
 * @title DailyEpochGauge
 * @notice Time-derived daily streaming of BMX to Uniswap v4 LP positions.
 *         Fees collected on day N are scheduled to stream on day N+2. The effective
 *         stream rate for a UTC day is bucket[day]/DAY, and reward accumulation is
 *         integrated piecewise across day boundaries on each update (swap, claim,
 *         or liquidity event) before adjusting to the current tick. Accounting is
 *         range-aware via `RangePool`, so only in-range liquidity accrues rewards.
 */
contract DailyEpochGauge is Ownable2Step {
    using TimeLibrary for uint256;
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;
    using TickBitmap for mapping(int16 => uint256);
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    // cache the tick range for every position key so we can compute in-range
    // reward growth later (needed to stop accrual once price leaves the
    // position span)
    struct TickRange {
        int24 lower;
        int24 upper;
    }

    IPositionManagerAdapter public positionManagerAdapter;
    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable BMX;

    address public feeProcessor;
    address public incentiveGauge;

    // Time-derived daily scheduling: PoolId -> dayIndex -> tokens to stream on that UTC day
    mapping(PoolId => mapping(uint32 => uint256)) public dayBuckets;

    // Reward math (tick-aware)
    mapping(PoolId => RangePool.State) public poolRewards;
    mapping(bytes32 => RangePosition.State) public positionRewards;

    // owner -> list of position keys per pool (for batched claims)
    mapping(PoolId => mapping(address => bytes32[])) internal ownerPositions;
    // cached latest liquidity for each position key (needed by view helpers)
    mapping(bytes32 => uint128) internal positionLiquidity;

    mapping(address => bool) public isHook;
    mapping(bytes32 => TickRange) internal positionTicks;
    mapping(bytes32 => uint256) internal positionTokenIds;
    // cache tickSpacing per pool to avoid external lookups on unsubscribe
    mapping(PoolId => int24) internal poolTickSpacing;

    // Exit snapshots for unsubscribe finalization (BMX only)
    mapping(bytes32 => uint256) internal exitCumRplX128;
    mapping(bytes32 => uint128) internal exitLiquidity;

    // Stale-unsubscribe deferral: pack t0Stored (pool.lastUpdated at unsubscribe), tExit, and pre-removal pool liquidity
    // Layout: [high 64 bits] = t0Stored (uint64), [next 64 bits] = tExit (uint64), [low 128 bits] = liqPre (uint128)
    mapping(bytes32 => uint256) internal exitMeta;
    // Base cumulative at unsubscribe time for order-independent finalize
    mapping(bytes32 => uint256) internal exitBaseCumX128;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event EpochRolled(PoolId indexed poolId, uint256 streamRate, uint256 timestamp);
    event RewardsAdded(PoolId indexed poolId, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event FeeProcessorUpdated(address newFeeProcessor);
    event HookAuthorised(address hook, bool enabled);
    event PositionManagerAdapterUpdated(address newAdapter);

    /*//////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _feeProcessor,
        IPoolManager _pm,
        IPositionManagerAdapter _posManagerAdapter,
        address _hook,
        IERC20 _bmx,
        address _incentiveGauge
    ) Ownable(msg.sender) {
        feeProcessor = _feeProcessor;
        POOL_MANAGER = _pm;
        positionManagerAdapter = _posManagerAdapter;
        BMX = _bmx;
        incentiveGauge = _incentiveGauge;
        isHook[_hook] = true;
        emit HookAuthorised(_hook, true);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyFeeProcessor() {
        if (msg.sender != feeProcessor) revert DeliErrors.NotFeeProcessor();
        _;
    }

    modifier onlyHook() {
        if (!isHook[msg.sender]) revert DeliErrors.NotHook();
        _;
    }

    modifier onlyPositionManagerAdapter() {
        if (msg.sender != address(positionManagerAdapter)) revert DeliErrors.NotSubscriber();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setFeeProcessor(address _fp) external onlyOwner {
        if (_fp == address(0)) revert DeliErrors.ZeroAddress();
        feeProcessor = _fp;
        emit FeeProcessorUpdated(_fp);
    }

    function setPositionManagerAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert DeliErrors.ZeroAddress();
        positionManagerAdapter = IPositionManagerAdapter(_adapter);
        emit PositionManagerAdapterUpdated(_adapter);
    }

    function setHook(address hook, bool enabled) external onlyOwner {
        if (hook == address(0)) revert DeliErrors.ZeroAddress();
        isHook[hook] = enabled;
        emit HookAuthorised(hook, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time pool bootstrap called by DeliHook.afterInitialize so that
    ///         accumulator state exists before the first swap.
    function initPool(PoolKey memory key, int24 initialTick) external onlyHook {
        PoolId pid = key.toId();
        RangePool.State storage pool = poolRewards[pid];
        pool.initialize(initialTick);
        // cache tick spacing for later fast syncs
        poolTickSpacing[pid] = key.tickSpacing;
    }

    /// @notice Adds freshly bought-back BMX to the pool's day bucket
    /// @dev Streams on Day N+2.
    function addRewards(PoolId poolId, uint256 amount) external onlyFeeProcessor {
        uint32 dayNow = TimeLibrary.dayCurrent();
        uint32 targetDay = dayNow + 2;
        dayBuckets[poolId][targetDay] += amount;
        emit RewardsAdded(poolId, amount);
    }

    /// @notice Called by hook on every swap to update only pool accumulator.
    function pokePool(PoolKey calldata key) external onlyHook {
        PoolId pid = key.toId();

        _syncPoolState(key, pid);
    }

    /// @notice Claim accrued BMX for a single position.
    /// @param tokenId The NFT token ID of the position to claim for.
    /// @param to The address to send the rewards to.
    function claim(uint256 tokenId, address to) external returns (uint256 amount) {
        // Verify the caller owns the position
        address owner = positionManagerAdapter.ownerOf(tokenId);
        if (msg.sender != owner) revert DeliErrors.NotAuthorized();

        (PoolKey memory key,) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();

        // Reconstruct the position key
        bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // Finalize any deferred/standard exit snapshot first, then sync and accrue
        _finalizeDeferredUnsubIfAny(pid, positionKey);
        _syncAndAccrue(key, pid, positionKey);

        // Claim and transfer
        amount = _claimRewards(positionKey, to);

        // If fully unsubscribed and no pending exit debt, remove from index
        if (
            positionLiquidity[positionKey] == 0 && exitLiquidity[positionKey] == 0
                && exitMeta[positionKey] == 0
        ) {
            _removePosition(pid, owner, positionKey);
        }
    }

    /// @notice Claim all accrued BMX (and incentive tokens) for every position an owner holds across multiple pools.
    /// @param pids  Array of pool identifiers to claim for.
    /// @param owner Recipient of the rewards.
    /// @return totalBmx Amount of BMX transferred.
    function claimAllForOwner(PoolId[] calldata pids, address owner) public returns (uint256 totalBmx) {
        uint256 poolLen = pids.length;
        for (uint256 p; p < poolLen; ++p) {
            PoolId pid = pids[p];

            // Skip if owner has no positions in this pool
            bytes32[] storage keys = ownerPositions[pid][owner];
            if (keys.length == 0) continue;

            // Look up the pool key using the adapter's fallback mechanism for V2 pools
            PoolKey memory key = positionManagerAdapter.getPoolKeyFromPoolId(pid);

            // Accrue and claim BMX for every position key of this owner in the pool.
            uint256 i;
            while (i < keys.length) {
                bytes32 posKey = keys[i];

                // Verify this position still belongs to the owner
                uint256 tokenId = positionTokenIds[posKey];
                if (tokenId == 0) {
                    // Position was removed elsewhere; skip entry
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                // Check ownership (use try-catch to handle burned tokens)
                try positionManagerAdapter.ownerOf(tokenId) returns (address currentOwner) {
                    if (currentOwner != owner) {
                        unchecked {
                            ++i;
                        }
                        continue; // Skip if no longer owned
                    }
                } catch {
                    unchecked {
                        ++i;
                    }
                    continue; // Skip if token doesn't exist or ownerOf reverts
                }

                // Finalize deferred/standard exit snapshot (if any), then sync and accrue
                _finalizeDeferredUnsubIfAny(pid, posKey);
                _syncAndAccrue(key, pid, posKey);

                uint256 amt = positionRewards[posKey].claim();
                if (amt > 0) totalBmx += amt;

                // If fully unsubscribed and no pending exit debt, remove from index (swap-pop)
                if (
                    positionLiquidity[posKey] == 0 && exitLiquidity[posKey] == 0 && exitMeta[posKey] == 0
                ) {
                    _removePosition(pid, owner, posKey);
                    // Do not increment i; new element has been swapped into index i
                } else {
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        // Call IncentiveGauge once to claim all incentive tokens, if set
        if (incentiveGauge != address(0)) {
            IIncentiveGauge(incentiveGauge).claimAllForOwner(pids, owner);
        }

        if (totalBmx > 0) {
            BMX.transfer(owner, totalBmx);
            emit Claimed(owner, totalBmx);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Effective stream rate for the current UTC day.
    function streamRate(PoolId pid) public view returns (uint256) {
        uint32 dayNow = TimeLibrary.dayCurrent();
        uint256 amt = dayBuckets[pid][dayNow];
        return amt == 0 ? 0 : amt / TimeLibrary.DAY;
    }

    /// @notice Returns core pool reward data.
    function getPoolData(PoolId pid)
        external
        view
        returns (uint256 currentStreamRate, uint256 rewardsPerLiquidityX128, uint128 activeLiquidity)
    {
        currentStreamRate = streamRate(pid);
        rewardsPerLiquidityX128 = poolRewards[pid].cumulativeRplX128(address(BMX));
        activeLiquidity = poolRewards[pid].liquidity;
    }

    /// @notice Batched version, returns array aligned to `pids` input.
    function getPoolDataBatch(PoolId[] calldata pids)
        external
        view
        returns (
            uint256[] memory currentStreamRates,
            uint256[] memory rewardsPerLiquidityX128s,
            uint128[] memory activeLiquidities
        )
    {
        uint256 len = pids.length;
        currentStreamRates = new uint256[](len);
        rewardsPerLiquidityX128s = new uint256[](len);
        activeLiquidities = new uint128[](len);
        for (uint256 i; i < len; ++i) {
            currentStreamRates[i] = streamRate(pids[i]);
            rewardsPerLiquidityX128s[i] = poolRewards[pids[i]].cumulativeRplX128(address(BMX));
            activeLiquidities[i] = poolRewards[pids[i]].liquidity;
        }
    }

    /// @notice Returns the number of seconds until the next epoch ends.
    function nextEpochEndsIn(PoolId) external view returns (uint256 secondsLeft) {
        uint256 end = TimeLibrary.dayNext(block.timestamp);
        secondsLeft = end > block.timestamp ? end - block.timestamp : 0;
    }

    /// @notice Returns pending rewards for an active position by tokenId.
    function pendingRewardsByTokenId(uint256 tokenId) external view returns (uint256 amount) {
        try positionManagerAdapter.ownerOf(tokenId) returns (address) {
            (PoolKey memory key,) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
            PoolId pid = key.toId();
            bytes32 positionKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

            RangePosition.State storage ps = positionRewards[positionKey];
            uint128 liq = positionLiquidity[positionKey];

            if (liq > 0) {
                TickRange storage tr = positionTicks[positionKey];
                uint256 delta =
                    poolRewards[pid].rangeRplX128(address(BMX), tr.lower, tr.upper) - ps.rewardsPerLiquidityLastX128;
                amount = ps.rewardsAccrued + (delta * liq) / FixedPoint128.Q128;
            } else {
                // Add deferred exit snapshot debt if present
                uint256 snap = exitCumRplX128[positionKey];
                if (snap != 0) {
                    uint256 exitDelta = snap - ps.rewardsPerLiquidityLastX128;
                    amount = ps.rewardsAccrued + (exitDelta * exitLiquidity[positionKey]) / FixedPoint128.Q128;
                } else {
                    amount = ps.rewardsAccrued;
                }
            }
        } catch {
            // Position doesn't exist
            amount = 0;
        }
    }

    /// @notice Aggregate pending BMX across **all** positions an owner has in a pool.
    function pendingRewardsOwner(PoolId pid, address owner) external view returns (uint256 amount) {
        amount = _pendingRewardsOwner(pid, owner);
    }

    /// @notice Batched version, returns array aligned to `pids` input.
    function pendingRewardsOwnerBatch(PoolId[] calldata pids, address owner)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 len = pids.length;
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            amounts[i] = _pendingRewardsOwner(pids[i], owner);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev internal helper to sync pool state and accrue position rewards
    function _syncAndAccrue(PoolKey memory key, PoolId pid, bytes32 positionKey) internal {
        // Sync pool state to ensure latest rewards
        _syncPoolState(key, pid);

        // Accrue latest rewards
        TickRange storage tr = positionTicks[positionKey];
        uint128 liq = positionLiquidity[positionKey];
        positionRewards[positionKey].accrue(liq, poolRewards[pid].rangeRplX128(address(BMX), tr.lower, tr.upper));
    }

    /// @dev Finalize exit snapshot (if any) by crediting owed amount at stored exit cumulative
    function _finalizeExitIfAny(PoolId, bytes32 positionKey) internal {
        uint128 liqExit = exitLiquidity[positionKey];
        if (liqExit == 0) return;
        uint256 exitCum = exitCumRplX128[positionKey];
        RangePosition.State storage ps = positionRewards[positionKey];
        uint256 delta = exitCum - ps.rewardsPerLiquidityLastX128;
        if (delta != 0) {
            ps.rewardsAccrued += FullMath.mulDiv(delta, liqExit, FixedPoint128.Q128);
            ps.rewardsPerLiquidityLastX128 = exitCum;
        }
        delete exitLiquidity[positionKey];
        delete exitCumRplX128[positionKey];
    }

    /// @dev Finalize any deferred unsubscribe for a position; ensures exit snapshot is set exactly
    function _finalizeDeferredUnsubIfAny(PoolId pid, bytes32 positionKey) internal {
        uint256 meta = exitMeta[positionKey];
        if (meta == 0) {
            _finalizeExitIfAny(pid, positionKey);
            return;
        }

        uint64 t0Stored = uint64(meta >> 192);
        uint64 tExit = uint64(meta >> 128);
        uint128 liqPre = uint128(meta);
        uint256 baseCum = exitBaseCumX128[positionKey];
        uint256 snap = baseCum;
        if (tExit > t0Stored && liqPre != 0) {
            uint256 amtExit = _amountOverWindow(pid, t0Stored, tExit);
            if (amtExit != 0) {
                uint256 dExit = (amtExit << 128) / liqPre;
                snap += dExit;
            }
        }

        exitCumRplX128[positionKey] = snap;
        delete exitMeta[positionKey];
        delete exitBaseCumX128[positionKey];

        // Finalize standard exit snapshot math if liquidity was captured earlier
        _finalizeExitIfAny(pid, positionKey);
    }

    /// @dev internal: remove a positionKey from indices (swap-pop) and delete liquidity cache
    function _removePosition(PoolId pid, address owner, bytes32 posKey) internal {
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, owner, posKey);
        delete positionTicks[posKey];
        delete positionRewards[posKey];
        delete positionTokenIds[posKey];
    }

    /// @dev internal: claim rewards for a position and transfer to recipient
    function _claimRewards(bytes32 posKey, address recipient) internal returns (uint256 amount) {
        amount = positionRewards[posKey].claim();
        if (amount > 0) {
            BMX.transfer(recipient, amount);
            emit Claimed(recipient, amount);
        }
    }

    /// @dev internal helper used by both single & batch
    function _pendingRewardsOwner(PoolId pid, address owner) internal view returns (uint256 amount) {
        RangePool.State storage pool = poolRewards[pid];
        bytes32[] storage keys = ownerPositions[pid][owner];
        uint256 len = keys.length;
        for (uint256 i; i < len; ++i) {
            bytes32 k = keys[i];
            TickRange storage tr = positionTicks[k];
            RangePosition.State storage ps = positionRewards[k];
            uint256 rangeRpl = pool.rangeRplX128(address(BMX), tr.lower, tr.upper);
            uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
            uint128 liq = positionLiquidity[k];
            amount += ps.rewardsAccrued + (delta * liq) / FixedPoint128.Q128;
            // Include deferred exit snapshot debt when liquidity is zero
            if (liq == 0) {
                uint256 snap = exitCumRplX128[k];
                if (snap != 0) {
                    uint256 exitDelta = snap - ps.rewardsPerLiquidityLastX128;
                    amount += (exitDelta * exitLiquidity[k]) / FixedPoint128.Q128;
                }
            }
        }
    }

    /// @dev Integrate day-bucket rates over [t0, t1) and return the total amount accrued.
    function _amountOverWindow(PoolId pid, uint256 t0, uint256 t1) internal view returns (uint256 total) {
        if (t1 <= t0) return 0;

        // Compute day starts once
        uint256 dayStart0 = TimeLibrary.dayStart(t0);
        uint256 dayStart1 = TimeLibrary.dayStart(t1);

        // Same day: single mulDiv
        if (dayStart0 == dayStart1) {
            uint256 amtSame = dayBuckets[pid][TimeLibrary.dayIndex(dayStart0)];
            return amtSame == 0 ? 0 : (amtSame * (t1 - t0)) / TimeLibrary.DAY;
        }

        uint32 d0 = TimeLibrary.dayIndex(dayStart0);
        uint32 d1 = TimeLibrary.dayIndex(dayStart1);

        // First partial day
        uint32 startD;
        if (t0 > dayStart0) {
            uint256 amt0 = dayBuckets[pid][d0];
            if (amt0 > 0) {
                total += (amt0 * ((dayStart0 + TimeLibrary.DAY) - t0)) / TimeLibrary.DAY;
            }
            unchecked {
                startD = d0 + 1;
            }
        } else {
            // t0 exactly at day start => include this day fully in full-day loop
            startD = d0;
        }

        // Last partial day
        uint32 endD = d1 - 1;

        // Full days in between: sum buckets directly (no mulDiv)
        if (startD <= endD) {
            for (uint32 d = startD; d <= endD;) {
                total += dayBuckets[pid][d];
                unchecked {
                    ++d;
                }
            }
        }

        // Last partial day
        if (t1 > dayStart1) {
            uint256 amt1 = dayBuckets[pid][d1];
            if (amt1 > 0) {
                total += (amt1 * (t1 - dayStart1)) / TimeLibrary.DAY;
            }
        }
    }

    /// @dev Piecewise integrate daily rates over elapsed time and sync pool accumulator; then adjust to current tick.
    function _syncPoolState(PoolKey memory key, PoolId pid) internal {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        int24 tickNow = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        _syncPoolStateCore(pid, tickNow, key.tickSpacing);
    }

    /// @dev Core sync logic shared by both wrappers
    function _syncPoolStateCore(PoolId pid, int24 activeTick, int24 tickSpacing) internal {
        RangePool.State storage pool = poolRewards[pid];
        uint256 t0 = pool.lastUpdated;
        uint256 t1 = block.timestamp;
        address[] memory toks = new address[](1);
        toks[0] = address(BMX);
        uint256[] memory amts = new uint256[](1);
        if (t1 > t0) {
            amts[0] = _amountOverWindow(pid, t0, t1);
        } else {
            amts[0] = 0;
        }
        pool.sync(toks, amts, tickSpacing, activeTick);
    }

    /*//////////////////////////////////////////////////////////////
                            SUBSCRIPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PositionManagerAdapter when a new position is created (context-based).
    function notifySubscribeWithContext(
        uint256 tokenId,
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Sync pool using cached tickSpacing and adapter-provided currentTick
        _syncPoolStateCore(pid, currentTick, poolTickSpacing[pid]);

        // Add liquidity to in-range pool accounting
        address[] memory toks = new address[](1);
        toks[0] = address(BMX);
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: SafeCast.toInt128(uint256(liquidity)),
                tickSpacing: poolTickSpacing[pid]
            }),
            toks
        );

        // Index position
        RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, posKey, liquidity);
        positionTokenIds[posKey] = tokenId;
        positionTicks[posKey] = TickRange({lower: tickLower, upper: tickUpper});

        // Set snapshot
        positionRewards[posKey].initSnapshot(poolRewards[pid].rangeRplX128(address(BMX), tickLower, tickUpper));
    }

    /// @notice Optimized unsubscribe with pre-fetched context from adapter
    /// @dev Typed args avoid dynamic-bytes packing/decoding overhead
    function notifyUnsubscribeWithContext(
        uint256, /*tokenId*/
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        RangePool.State storage pool = poolRewards[pid];
        uint256 t0 = pool.lastUpdated;
        uint256 t1 = block.timestamp;
        if (TimeLibrary.dayStart(t0) == TimeLibrary.dayStart(t1)) {
            // Fast path: sync now and snapshot exit cumulative
            if (t1 > t0) {
                uint256 amt = _amountOverWindow(pid, t0, t1);
                if (amt > 0) {
                    pool.creditSingleTokenNoTick(address(BMX), amt);
                }
            }
            exitCumRplX128[posKey] = pool.cumulativeRplX128(address(BMX));
            exitLiquidity[posKey] = liquidity;
        } else {
            // Stale path: defer exit snapshot; record exit info compactly and queue removal
            // Pack: [high 64]=t0 (pool.lastUpdated at unsubscribe), [next 64]=tExit (now), [low 128]=liqPre (pool.liquidity)
            uint256 meta = (uint256(uint64(t0)) << 192) | (uint256(uint64(t1)) << 128) | uint256(pool.liquidity);
            exitMeta[posKey] = meta;
            exitBaseCumX128[posKey] = pool.cumulativeRplX128(address(BMX));
            // Always capture per-position liquidity for exit accrual during finalize
            exitLiquidity[posKey] = liquidity;
        }

        // Soft removal and zero cached liquidity
        if (liquidity != 0) {
            pool.queueRemoval(tickLower, tickUpper, liquidity);
        }
        positionLiquidity[posKey] = 0;
    }

    /// @notice Called by PositionManagerAdapter when a position is burned (context-based).
    function notifyBurnWithContext(
        uint256, /*tokenId*/
        bytes32 posKey,
        bytes32 poolIdRaw,
        address ownerAddr,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Sync pool using cached tickSpacing and adapter-provided currentTick
        _syncPoolStateCore(pid, currentTick, poolTickSpacing[pid]);

        // 1. Accrue rewards with current liquidity
        positionRewards[posKey].accrue(
            uint128(liquidity), poolRewards[pid].rangeRplX128(address(BMX), tickLower, tickUpper)
        );

        // 2. Remove liquidity from pool accounting
        if (liquidity != 0) {
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -SafeCast.toInt128(liquidity),
                    tickSpacing: poolTickSpacing[pid]
                }),
                new address[](0)
            );
        }

        // 3. Auto-claim any remaining rewards
        _claimRewards(posKey, ownerAddr);

        // 4. Clean up position data
        _removePosition(pid, ownerAddr, posKey);
    }

    /// @notice Called by PositionManagerAdapter when a position's liquidity is modified (context-based).
    function notifyModifyLiquidityWithContext(
        uint256, /*tokenId*/
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityChange,
        uint128 liquidityAfter
    ) external onlyPositionManagerAdapter {
        PoolId pid = PoolId.wrap(poolIdRaw);

        // Sync pool using cached tickSpacing and adapter-provided currentTick
        _syncPoolStateCore(pid, currentTick, poolTickSpacing[pid]);

        // Compute liquidity before the change using a cast-safe path
        int128 delta128 = SafeCast.toInt128(liquidityChange);
        uint128 liquidityBefore =
            delta128 >= 0 ? liquidityAfter - uint128(uint128(delta128)) : liquidityAfter + uint128(uint128(-delta128));

        // 1. Accrue rewards with liquidity before change
        positionRewards[posKey].accrue(
            liquidityBefore, poolRewards[pid].rangeRplX128(address(BMX), tickLower, tickUpper)
        );

        // 2. Update pool liquidity delta
        if (liquidityChange > 0) {
            address[] memory toks = new address[](1);
            toks[0] = address(BMX);
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: SafeCast.toInt128(liquidityChange),
                    tickSpacing: poolTickSpacing[pid]
                }),
                toks
            );
        } else {
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: SafeCast.toInt128(liquidityChange),
                    tickSpacing: poolTickSpacing[pid]
                }),
                new address[](0)
            );
        }

        // Always update cached liquidity (keep position tracked even at 0)
        positionLiquidity[posKey] = liquidityAfter;
    }
}
