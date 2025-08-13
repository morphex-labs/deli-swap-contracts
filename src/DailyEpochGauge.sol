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

    IPositionManagerAdapter public positionManagerAdapter;
    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable BMX;

    address public feeProcessor;
    address public incentiveGauge;

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

        // Sync pool state and accrue rewards
        _syncAndAccrue(key, pid, positionKey);

        // Claim and transfer
        amount = _claimRewards(positionKey, to);
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
            uint256 keyLen = keys.length;
            if (keyLen == 0) continue;

            // Look up the pool key using the adapter's fallback mechanism for V2 pools
            PoolKey memory key = positionManagerAdapter.getPoolKeyFromPoolId(pid);

            // Accrue and claim BMX for every position key of this owner in the pool.
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

                // Sync pool state and accrue rewards
                _syncAndAccrue(key, pid, posKey);

                uint256 amt = positionRewards[posKey].claim();
                if (amt > 0) totalBmx += amt;
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
                // Position might be unclaimed or have no rewards
                amount = ps.rewardsAccrued;
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

    /// @dev internal helper to accrue and remove liquidity with provided params
    function _accrueAndRemove(PoolId pid, bytes32 posKey, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
    {
        positionRewards[posKey].accrue(liquidity, poolRewards[pid].rangeRplX128(address(BMX), tickLower, tickUpper));
        if (liquidity != 0) {
            PoolKey memory key = positionManagerAdapter.getPoolKeyFromPoolId(pid);
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -SafeCast.toInt128(uint256(liquidity)),
                    tickSpacing: key.tickSpacing
                }),
                new address[](0)
            );
        }
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
            amount += ps.rewardsAccrued + (delta * positionLiquidity[k]) / FixedPoint128.Q128;
        }
    }

    /// @dev Integrate day-bucket rates over [t0, t1) and return the total amount accrued.
    function _amountOverWindow(PoolId pid, uint256 t0, uint256 t1) internal view returns (uint256 total) {
        if (t1 <= t0) return 0;
        uint256 t = t0;
        while (true) {
            uint256 dayStart = TimeLibrary.dayStart(t);
            uint32 dayIndex = TimeLibrary.dayIndex(dayStart);
            uint256 dayEnd = dayStart + TimeLibrary.DAY;
            uint256 segEnd = t1 < dayEnd ? t1 : dayEnd;
            uint256 dt = segEnd - t;
            if (dt > 0) {
                uint256 amt = dayBuckets[pid][dayIndex];
                if (amt > 0) total += FullMath.mulDiv(amt, dt, TimeLibrary.DAY);
            }
            if (segEnd == t1) break;
            t = segEnd;
        }
    }

    /// @dev Piecewise integrate daily rates over elapsed time and sync pool accumulator; then adjust to current tick.
    function _syncPoolState(PoolKey memory key, PoolId pid) internal {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        int24 tickNow = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        _syncPoolStateCore(pid, tickNow, key.tickSpacing);
    }

    /// @dev Variant of _syncPoolState using provided currentTick
    function _syncPoolStateWithParams(PoolId pid, int24 currentTick) internal {
        PoolKey memory key = positionManagerAdapter.getPoolKeyFromPoolId(pid);
        _syncPoolStateCore(pid, currentTick, key.tickSpacing);
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

    /// @notice Called by PositionManagerAdapter when a new position is created.
    function notifySubscribe(uint256 tokenId, bytes memory) external onlyPositionManagerAdapter {
        (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManagerAdapter.getPositionLiquidity(tokenId);
        address owner = positionManagerAdapter.ownerOf(tokenId);

        PoolId pid = key.toId();

        _syncPoolState(key, pid);

        // ---- add liquidity to in-range pool accounting ----
        address[] memory toks = new address[](1);
        toks[0] = address(BMX);
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: SafeCast.toInt128(uint256(liquidity)),
                tickSpacing: key.tickSpacing
            }),
            toks
        );

        // index position
        bytes32 posKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));
        RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, posKey, liquidity);
        positionTokenIds[posKey] = tokenId;

        // store tick range for later range-aware accounting
        positionTicks[posKey] = TickRange({lower: info.tickLower(), upper: info.tickUpper()});

        // set snapshot
        positionRewards[posKey].initSnapshot(
            poolRewards[pid].rangeRplX128(address(BMX), info.tickLower(), info.tickUpper())
        );
    }

    /// @notice Optimized unsubscribe with pre-fetched context from adapter
    /// @dev Context layout: (bytes32 poolIdRaw, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)
    function notifyUnsubscribeWithContext(uint256 tokenId, bytes calldata data) external onlyPositionManagerAdapter {
        (bytes32 poolIdRaw, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick) =
            abi.decode(data, (bytes32, int24, int24, uint128, int24));

        PoolId pid = PoolId.wrap(poolIdRaw);
        bytes32 posKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        _syncPoolStateWithParams(pid, currentTick);

        _accrueAndRemove(pid, posKey, tickLower, tickUpper, liquidity);
        // Defer claims; keep indices for later batch claim and prune
        positionLiquidity[posKey] = 0;
    }

    /// @notice Called by PositionManagerAdapter when a position is burned.
    function notifyBurn(uint256 tokenId, address ownerAddr, PositionInfo info, uint256 liquidity, BalanceDelta)
        external
        onlyPositionManagerAdapter
    {
        // For burned positions, we can't look up the tokenId normally
        PoolKey memory key = positionManagerAdapter.getPoolKeyFromPositionInfo(info);
        PoolId pid = key.toId();

        _syncPoolState(key, pid);

        bytes32 posKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // 1. Accrue rewards with current liquidity
        positionRewards[posKey].accrue(
            uint128(liquidity), poolRewards[pid].rangeRplX128(address(BMX), info.tickLower(), info.tickUpper())
        );

        // 2. Remove liquidity from pool accounting
        if (liquidity != 0) {
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: info.tickLower(),
                    tickUpper: info.tickUpper(),
                    liquidityDelta: -SafeCast.toInt128(liquidity),
                    tickSpacing: key.tickSpacing
                }),
                new address[](0)
            );
        }

        // 3. Auto-claim any remaining rewards
        _claimRewards(posKey, ownerAddr);

        // 4. Clean up position data
        _removePosition(pid, ownerAddr, posKey);
    }

    /// @notice Called by PositionManagerAdapter when a position's liquidity is modified.
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta)
        external
        onlyPositionManagerAdapter
    {
        (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();

        _syncPoolState(key, pid);

        uint128 currentLiq = positionManagerAdapter.getPositionLiquidity(tokenId);

        // Compute liquidity before the change using a cast-safe path
        int128 delta128 = SafeCast.toInt128(liquidityChange);
        uint128 liquidityBefore = delta128 >= 0
            ? currentLiq - uint128(uint128(delta128))
            : currentLiq + uint128(uint128(-delta128));

        bytes32 posKey = EfficientHashLib.hash(bytes32(tokenId), bytes32(PoolId.unwrap(pid)));

        // 1. Accrue rewards with liquidity before change
        positionRewards[posKey].accrue(
            liquidityBefore, poolRewards[pid].rangeRplX128(address(BMX), info.tickLower(), info.tickUpper())
        );

        // 2. Update pool liquidity delta
        // Pass BMX token on positive adds to initialize per-token outside; empty list for removals/zero
        if (liquidityChange > 0) {
            address[] memory toks2 = new address[](1);
            toks2[0] = address(BMX);
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: info.tickLower(),
                    tickUpper: info.tickUpper(),
                    liquidityDelta: SafeCast.toInt128(liquidityChange),
                    tickSpacing: key.tickSpacing
                }),
                toks2
            );
        } else {
            poolRewards[pid].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: info.tickLower(),
                    tickUpper: info.tickUpper(),
                    liquidityDelta: SafeCast.toInt128(liquidityChange),
                    tickSpacing: key.tickSpacing
                }),
                new address[](0)
            );
        }

        // Always update cached liquidity (keep position tracked even at 0)
        positionLiquidity[posKey] = currentLiq;
    }
}
