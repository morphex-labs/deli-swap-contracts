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

import {IPoolKeys} from "./interfaces/IPoolKeys.sol";
import {IIncentiveGauge} from "./interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "./interfaces/IPositionManagerAdapter.sol";

import {RangePool} from "./libraries/RangePool.sol";
import {RangePosition} from "./libraries/RangePosition.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";

/**
 * @title DailyEpochGauge
 * @notice Streams buy-back BMX to Uniswap v4 LP positions on fixed 24-hour
 *         epochs.  Fees collected on day N are queued on day N+1, become the
 *         active stream on day N+2, and are fully distributed over that day.
 *         Accounting is range-aware so out-of-range positions do not accrue
 *         rewards.  The contract is designed to be called lazily—state stays
 *         consistent even if no interaction occurs for multiple days.
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

    struct EpochInfo {
        uint64 start; // inclusive
        uint64 end; // exclusive
        uint128 streamRate; // tokens/s streamed during current day (Day N)
        uint128 nextStreamRate; // tokens/s to stream NEXT day (Day N+1)
        uint128 queuedStreamRate; // tokens/s prepared for Day N+2 (derived from bucket just finished)
    }

    // cache the tick range for every position key so we can compute in-range
    // reward growth later (needed to stop accrual once price leaves the
    // position span)
    struct TickRange {
        int24 lower;
        int24 upper;
    }

    mapping(PoolId => EpochInfo) public epochInfo;
    mapping(PoolId => uint256) public collectBucket;

    // Reward math (tick-aware)
    mapping(PoolId => RangePool.State) public poolRewards;
    mapping(bytes32 => RangePosition.State) public positionRewards;

    // owner → list of position keys per pool (for batched claims)
    mapping(PoolId => mapping(address => bytes32[])) internal ownerPositions;
    // cached latest liquidity for each position key (needed by view helpers)
    mapping(bytes32 => uint128) internal positionLiquidity;

    mapping(address => bool) public isHook;
    mapping(bytes32 => TickRange) internal positionTicks;

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

    /// @notice One-time pool bootstrap called by DeliHook.beforeInitialize so that
    ///         accumulator state exists before the first swap.
    function initPool(PoolId pid, int24 initialTick) external onlyHook {
        RangePool.State storage pool = poolRewards[pid];
        pool.initialize(initialTick);
    }

    /// @notice Lazily rolls the epoch if we've crossed midnight UTC.
    function rollIfNeeded(PoolId poolId) external {
        EpochInfo storage e = epochInfo[poolId];

        // Initialise epoch if first ever call for this pool.
        if (e.end == 0) {
            uint256 start = block.timestamp.dayStart();
            e.start = uint64(start);
            e.end = uint64(start + TimeLibrary.DAY);
            e.streamRate = 0;
            e.nextStreamRate = 0;
            e.queuedStreamRate = 0;
            return;
        }

        // Fast-forward until current timestamp is within [start, end).
        while (block.timestamp >= e.end) {
            _rollOnce(poolId, e);
        }
    }

    /// @notice Adds freshly bought-back BMX to the pool's collect bucket.
    ///         Called directly by FeeProcessor in the same transaction.
    function addRewards(PoolId poolId, uint256 amount) external onlyFeeProcessor {
        collectBucket[poolId] += amount;
        emit RewardsAdded(poolId, amount);
    }

    /// @notice Called by hook on every swap to update only pool accumulator.
    function pokePool(PoolKey calldata key) external onlyHook {
        PoolId pid = key.toId();

        _syncPoolState(key, pid);
    }

    /// @notice Helper to fetch current streamRate.
    function streamRate(PoolId pid) public view returns (uint256) {
        return epochInfo[pid].streamRate;
    }

    /// @notice Claim accrued BMX for a single position.
    /// @param tokenId The NFT token ID of the position to claim for.
    /// @param to The address to send the rewards to.
    function claim(uint256 tokenId, address to) external returns (uint256 amount) {
        // Verify the caller owns the position
        address owner = positionManagerAdapter.ownerOf(tokenId);
        if (msg.sender != owner) revert DeliErrors.NotAuthorized();

        (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();

        // Sync pool state to ensure latest rewards
        _syncPoolState(key, pid);

        // Reconstruct the position key
        bytes32 positionKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));

        // Accrue latest rewards
        TickRange storage tr = positionTicks[positionKey];
        uint128 liq = positionLiquidity[positionKey];
        positionRewards[positionKey].accrue(liq, poolRewards[pid].rangeRplX128(tr.lower, tr.upper));

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

            // Sync pool state to ensure latest rewards
            // Look up the pool key from the position manager using IPoolKeys interface
            PoolKey memory key =
                IPoolKeys(positionManagerAdapter.positionManager()).poolKeys(bytes25(PoolId.unwrap(pid)));
            _syncPoolState(key, pid);

            // Accrue and claim BMX for every position key of this owner in the pool.
            for (uint256 i; i < keyLen; ++i) {
                bytes32 k = keys[i];
                RangePosition.State storage ps = positionRewards[k];
                uint128 liq = positionLiquidity[k];

                // Accrue any unaccounted rewards since last interaction.
                TickRange storage tr = positionTicks[k];
                ps.accrue(liq, poolRewards[pid].rangeRplX128(tr.lower, tr.upper));

                uint256 amt = ps.claim();
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

    /// @notice Returns core pool reward data.
    function getPoolData(PoolId pid)
        external
        view
        returns (uint256 currentStreamRate, uint256 rewardsPerLiquidityX128, uint128 activeLiquidity)
    {
        currentStreamRate = epochInfo[pid].streamRate;
        rewardsPerLiquidityX128 = poolRewards[pid].cumulativeRplX128();
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
            currentStreamRates[i] = epochInfo[pids[i]].streamRate;
            rewardsPerLiquidityX128s[i] = poolRewards[pids[i]].cumulativeRplX128();
            activeLiquidities[i] = poolRewards[pids[i]].liquidity;
        }
    }

    /// @notice Returns the number of seconds until the next epoch ends.
    function nextEpochEndsIn(PoolId pid) external view returns (uint256 secondsLeft) {
        uint64 end = epochInfo[pid].end;
        secondsLeft = end > block.timestamp ? end - block.timestamp : 0;
    }

    /// @notice Returns pending rewards for an active position by tokenId.
    function pendingRewardsByTokenId(uint256 tokenId) external view returns (uint256 amount) {
        try positionManagerAdapter.ownerOf(tokenId) returns (address owner) {
            (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
            PoolId pid = key.toId();
            bytes32 positionKey =
                keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));

            RangePosition.State storage ps = positionRewards[positionKey];
            uint128 liq = positionLiquidity[positionKey];

            if (liq > 0) {
                TickRange storage tr = positionTicks[positionKey];
                uint256 delta = poolRewards[pid].rangeRplX128(tr.lower, tr.upper) - ps.rewardsPerLiquidityLastX128;
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

    /// @dev internal helper used by both single & batch
    function _pendingRewardsOwner(PoolId pid, address owner) internal view returns (uint256 amount) {
        RangePool.State storage pool = poolRewards[pid];
        bytes32[] storage keys = ownerPositions[pid][owner];
        uint256 len = keys.length;
        for (uint256 i; i < len; ++i) {
            bytes32 k = keys[i];
            TickRange storage tr = positionTicks[k];
            RangePosition.State storage ps = positionRewards[k];
            uint256 rangeRpl = pool.rangeRplX128(tr.lower, tr.upper);
            uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
            amount += ps.rewardsAccrued + (delta * positionLiquidity[k]) / FixedPoint128.Q128;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev internal: perform a single 24-hour roll.
    function _rollOnce(PoolId poolId, EpochInfo storage e) internal {
        // 1. Current day's streamRate becomes the value prepared from previous roll
        e.streamRate = e.nextStreamRate;

        // 2. Move queued → next, compute new queued from bucket.
        e.nextStreamRate = e.queuedStreamRate;
        uint256 bucket = collectBucket[poolId];
        collectBucket[poolId] = 0;
        e.queuedStreamRate = uint128(bucket / TimeLibrary.DAY);

        // 3. Advance the epoch window by 1 day.
        uint256 nextStart = uint256(e.end);
        e.start = uint64(nextStart);
        e.end = uint64(nextStart + TimeLibrary.DAY);

        // 4. Reset pool accumulator timestamp to new epoch start so that
        //    subsequent accrue calls only count rewards from this day.
        poolRewards[poolId].lastUpdated = uint64(nextStart);

        emit EpochRolled(poolId, e.streamRate, nextStart);
    }

    /// @dev internal: remove a positionKey from indices (swap-pop) and delete liquidity cache
    function _removePosition(PoolId pid, address owner, bytes32 posKey) internal {
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, owner, posKey);
        delete positionTicks[posKey];
        delete positionRewards[posKey];
    }

    /// @dev internal: claim rewards for a position and transfer to recipient
    function _claimRewards(bytes32 posKey, address recipient) internal returns (uint256 amount) {
        amount = positionRewards[posKey].claim();
        if (amount > 0) {
            BMX.transfer(recipient, amount);
            emit Claimed(recipient, amount);
        }
    }

    /// @dev Ensures that the epoch window for `pid` is current. If the pool
    ///      has never been initialised or we have crossed midnight UTC since
    ///      the last interaction this will fast-forward by calling
    ///      `rollIfNeeded`.
    function _ensureEpoch(PoolId pid) internal {
        EpochInfo storage e = epochInfo[pid];
        if (e.end == 0) {
            uint256 start = block.timestamp.dayStart();
            e.start = uint64(start);
            e.end = uint64(start + TimeLibrary.DAY);
            e.streamRate = 0;
            e.nextStreamRate = 0;
            e.queuedStreamRate = 0;
            return;
        }

        // Fast-forward until the current timestamp fits in [start, end).
        while (block.timestamp >= e.end) {
            _rollOnce(pid, e);
        }
    }

    /// @dev Synchronise epoch, accumulator, tick, and pool initialisation in one call.
    /// @return currentTick The tick after adjustments, used by caller if needed.
    function _syncPoolState(PoolKey memory key, PoolId pid) internal returns (int24 currentTick) {
        // Ensure epoch window current.
        _ensureEpoch(pid);

        // Get current active tick from poolManager
        (, int24 tickNow,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);

        // One-liner: initialise (if needed), accumulate streamRate, adjust tick.
        poolRewards[pid].sync(streamRate(pid), key.tickSpacing, tickNow);

        return tickNow;
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
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: SafeCast.toInt128(uint256(liquidity)),
                tickSpacing: key.tickSpacing
            })
        );

        // index position
        bytes32 posKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));
        RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, posKey, liquidity);

        // store tick range for later range-aware accounting
        positionTicks[posKey] = TickRange({lower: info.tickLower(), upper: info.tickUpper()});

        // set snapshot
        positionRewards[posKey].initSnapshot(poolRewards[pid].rangeRplX128(info.tickLower(), info.tickUpper()));
    }

    /// @notice Called by PositionManagerAdapter when a position is withdrawn or unsubscribed.
    function notifyUnsubscribe(uint256 tokenId) external onlyPositionManagerAdapter {
        (PoolKey memory key, PositionInfo info) = positionManagerAdapter.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManagerAdapter.getPositionLiquidity(tokenId);
        address owner = positionManagerAdapter.ownerOf(tokenId);
        PoolId pid = key.toId();

        _syncPoolState(key, pid);

        bytes32 posKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));

        // 1. Accrue rewards with current liquidity
        positionRewards[posKey].accrue(liquidity, poolRewards[pid].rangeRplX128(info.tickLower(), info.tickUpper()));

        // 2. Remove liquidity from pool accounting
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: -SafeCast.toInt128(uint256(liquidity)),
                tickSpacing: key.tickSpacing
            })
        );

        // 3. Auto-claim any remaining rewards
        _claimRewards(posKey, owner);

        // 4. Clean up position data
        _removePosition(pid, owner, posKey);
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

        bytes32 posKey = keccak256(abi.encode(ownerAddr, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));

        // 1. Accrue rewards with current liquidity
        positionRewards[posKey].accrue(
            uint128(liquidity), poolRewards[pid].rangeRplX128(info.tickLower(), info.tickUpper())
        );

        // 2. Remove liquidity from pool accounting
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: -SafeCast.toInt128(liquidity),
                tickSpacing: key.tickSpacing
            })
        );

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
        address owner = positionManagerAdapter.ownerOf(tokenId);

        uint128 liquidityBefore = uint128(int128(currentLiq) - int128(liquidityChange));

        bytes32 posKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));

        // 1. Accrue rewards with liquidity before change
        positionRewards[posKey].accrue(
            liquidityBefore, poolRewards[pid].rangeRplX128(info.tickLower(), info.tickUpper())
        );

        // 2. Update pool liquidity delta
        poolRewards[pid].modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: SafeCast.toInt128(liquidityChange),
                tickSpacing: key.tickSpacing
            })
        );

        // update cached liq
        if (currentLiq == 0) {
            // 3. Auto-claim any remaining rewards
            _claimRewards(posKey, owner);

            // 4. Clean up position data
            _removePosition(pid, owner, posKey);
        } else {
            positionLiquidity[posKey] = currentLiq; // cache update stays
        }
    }
}
