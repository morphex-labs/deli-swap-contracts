// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

import {IPoolKeys} from "./interfaces/IPoolKeys.sol";

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

    struct DeltaParams {
        PoolId pid;
        IERC20 token;
        bytes32 posKey;
        int24 tickLower;
        int24 tickUpper;
        int24 tickSpacing;
        uint128 liquidityBefore;
        int128 liquidityDelta;
    }

    struct Pending {
        IERC20 token;
        uint256 amount;
    }

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;

    address public gaugeSubscriber;

    mapping(address => bool) public isHook;

    // pool -> rewardToken -> incentive data
    mapping(PoolId => mapping(IERC20 => IncentiveInfo)) public incentives;

    // pool -> token -> poolState
    mapping(PoolId => mapping(IERC20 => RangePool.State)) public poolRewards;
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

    // per pool list of active incentive tokens
    mapping(PoolId => IERC20[]) internal poolTokens;

    // whitelist of reward tokens
    mapping(IERC20 => bool) public whitelist;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event WhitelistSet(IERC20 indexed token, bool allowed);
    event IncentiveCreated(PoolId indexed pid, IERC20 indexed token, uint256 amount, uint256 rate);
    event Claimed(address indexed user, IERC20 indexed token, uint256 amount);
    event GaugeSubscriberUpdated(address newGaugeSubscriber);
    event HookAuthorised(address hook, bool enabled);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _pm, IPositionManager _posManager, address _hook) Ownable(msg.sender) {
        POOL_MANAGER = _pm;
        POSITION_MANAGER = _posManager;
        isHook[_hook] = true;
        emit HookAuthorised(_hook, true);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGaugeSubscriber() {
        if (msg.sender != gaugeSubscriber) revert DeliErrors.NotSubscriber();
        _;
    }

    modifier onlyHook() {
        if (!isHook[msg.sender]) revert DeliErrors.NotHook();
        _;
    }

    /// @notice Authorise or de-authorise a hook address.
    function setHook(address hook, bool enabled) external onlyOwner {
        if (hook == address(0)) revert DeliErrors.ZeroAddress();
        isHook[hook] = enabled;
        emit HookAuthorised(hook, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                                   ADMIN
    //////////////////////////////////////////////////////////////*/

    function setWhitelist(IERC20 token, bool ok) external onlyOwner {
        whitelist[token] = ok;
        emit WhitelistSet(token, ok);
    }

    function setGaugeSubscriber(address _gs) external onlyOwner {
        if (_gs == address(0)) revert DeliErrors.ZeroAddress();
        gaugeSubscriber = _gs;
        emit GaugeSubscriberUpdated(_gs);
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by DeliHook to update pool state
    function pokePool(PoolKey calldata key) external onlyHook {
        PoolId pid = key.toId();
        IERC20[] storage toks = poolTokens[pid];
        uint256 len = toks.length;
        if (len == 0) return;

        (, int24 currentTick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        for (uint256 i; i < len; ++i) {
            _updatePool(key, pid, toks[i], currentTick);
        }
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
        IncentiveInfo storage info = incentives[pid][rewardToken];

        // pull tokens
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 leftover;
        if (block.timestamp < info.periodFinish) {
            uint256 remainingTime = info.periodFinish - block.timestamp;
            leftover = remainingTime * info.rewardRate;
        }

        uint256 newTotal = amount + leftover;
        info.rewardRate = uint128(newTotal / TimeLibrary.WEEK);
        info.periodFinish = uint64(block.timestamp + TimeLibrary.WEEK);
        info.lastUpdate = uint64(block.timestamp);
        info.remaining = uint128(newTotal);

        emit IncentiveCreated(pid, rewardToken, amount, info.rewardRate);

        // Track token in pool list if first time
        _addTokenToPool(pid, rewardToken);

        // Bootstrap poolRewards state so that streaming can start accruing immediately even if no further pool interactions happen before the first poke. We also preload the active liquidity so that the first liquidity modification for pre-existing positions cannot underflow.
        RangePool.State storage pool = poolRewards[pid][rewardToken];
        // Ensure pool struct exists (initPool may have initialised a sentinel entry)
        if (pool.lastUpdated == 0) {
            (, int24 currentTick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
            pool.initialize(currentTick);
        }

        // If no liquidity cached yet, seed with current pool liquidity so that accumulate() can divide correctly and early negative liquidity deltas cannot underflow.
        if (pool.liquidity == 0) {
            uint128 activeLiq = StateLibrary.getLiquidity(POOL_MANAGER, pid);
            if (activeLiq > 0) pool.liquidity = activeLiq;
        }
    }

    /// @notice Claim accrued token rewards for a single position key.
    /// @param token The token to claim rewards for.
    /// @param positionKey The position key to claim rewards for.
    /// @param to The address to transfer the rewards to.
    function claim(IERC20 token, bytes32 positionKey, address to) external returns (uint256 amount) {
        amount = positionRewards[positionKey][token].claim();
        if (amount > 0) token.safeTransfer(to, amount);
        emit Claimed(to, token, amount);
    }

    /// @notice Claim all token rewards for an owner across multiple pools.
    /// @param pids The pools to claim rewards for.
    /// @param owner The owner to claim rewards for.
    function claimAllForOwner(PoolId[] calldata pids, address owner) external {
        uint256 plen = pids.length;
        for (uint256 p; p < plen; ++p) {
            PoolId pid = pids[p];
            IERC20[] storage toks = poolTokens[pid];
            if (toks.length == 0) continue; // nothing to claim
            bytes32[] storage keys = ownerPositions[pid][owner];

            for (uint256 i; i < keys.length; ++i) {
                bytes32 k = keys[i];
                for (uint256 t; t < toks.length; ++t) {
                    IERC20 tok = toks[t];
                    RangePosition.State storage ps = positionRewards[k][tok];
                    // accrue pending delta before claim
                    TickRange storage tr = positionTicks[k];
                    ps.accrue(positionLiquidity[k], poolRewards[pid][tok].rangeRplX128(tr.lower, tr.upper));
                    uint256 amt = ps.claim();
                    if (amt > 0) tok.safeTransfer(owner, amt);
                    emit Claimed(owner, tok, amt);
                }
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

    /// @notice Returns the pending reward for a position key and token for given pool using tick range
    function pendingRewards(bytes32 posKey, IERC20 token, uint128 currentLiquidity, PoolId pid)
        external
        view
        returns (uint256 amount)
    {
        TickRange storage tr = positionTicks[posKey];
        RangePosition.State storage ps = positionRewards[posKey][token];
        uint256 rangeRpl = poolRewards[pid][token].rangeRplX128(tr.lower, tr.upper);
        uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
        amount = ps.rewardsAccrued + (delta * currentLiquidity) / FixedPoint128.Q128;
    }

    /// @notice Batch version, returns array aligned to `tokens` input
    function pendingRewardsBatch(bytes32 posKey, IERC20[] calldata tokens, uint128 currentLiquidity, PoolId pid)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 len = tokens.length;
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            TickRange storage tr = positionTicks[posKey];
            RangePosition.State storage ps = positionRewards[posKey][tokens[i]];
            uint256 rangeRpl = poolRewards[pid][tokens[i]].rangeRplX128(tr.lower, tr.upper);
            uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
            amounts[i] = ps.rewardsAccrued + (delta * currentLiquidity) / FixedPoint128.Q128;
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

    /// @dev internal helper to add a token to a pool
    function _addTokenToPool(PoolId pid, IERC20 token) internal {
        IERC20[] storage arr = poolTokens[pid];
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == token) return;
        }
        arr.push(token);
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
                total += _pendingForPosTokFull(keys[i], tok, pid);
            }
            list[t] = Pending({token: tok, amount: total});
        }
    }

    /// @dev small helper to compute pending for one position & token
    function _pendingForPosTok(bytes32 posKey, IERC20 tok, uint256 poolRpl) internal view returns (uint256) {
        RangePosition.State storage ps = positionRewards[posKey][tok];
        uint256 delta = poolRpl - ps.rewardsPerLiquidityLastX128;
        return ps.rewardsAccrued + (delta * positionLiquidity[posKey]) / FixedPoint128.Q128;
    }

    /// @dev full helper that computes pending reward for a position key and token for given pool using tick range
    function _pendingForPosTokFull(bytes32 posKey, IERC20 tok, PoolId pid) internal view returns (uint256) {
        TickRange storage tr = positionTicks[posKey];
        uint256 rangeRpl = poolRewards[pid][tok].rangeRplX128(tr.lower, tr.upper);
        RangePosition.State storage ps = positionRewards[posKey][tok];
        uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
        return ps.rewardsAccrued + (delta * positionLiquidity[posKey]) / FixedPoint128.Q128;
    }

    /// @dev internal helper to update pool state
    function _updatePool(PoolKey memory key, PoolId pid, IERC20 token, int24 currentTick) internal {
        IncentiveInfo storage info = incentives[pid][token];
        if (info.rewardRate == 0) return;

        // Sync pool state (init, accumulate, tick adjust) in one call
        poolRewards[pid][token].sync(info.rewardRate, key.tickSpacing, currentTick);

        // update incentive streaming bookkeeping
        uint256 dt = block.timestamp - info.lastUpdate;
        if (dt > 0) {
            uint256 streamed = dt * info.rewardRate;
            if (streamed > info.remaining) streamed = info.remaining;
            info.remaining -= uint128(streamed);
            info.lastUpdate = uint64(block.timestamp);
            if (info.remaining == 0) info.rewardRate = 0;
        }
    }

    /// @dev internal helper to apply liquidity delta to a position
    function _applyLiquidityDelta(DeltaParams memory d) internal {
        RangePool.State storage pool = poolRewards[d.pid][d.token];

        // ensure boundary ticks stay initialised
        _ensureTickInitialised(pool, d.tickLower, d.tickSpacing);
        _ensureTickInitialised(pool, d.tickUpper, d.tickSpacing);

        RangePosition.State storage ps = positionRewards[d.posKey][d.token];

        // Accrue rewards before mutating liquidity using range-aware accumulator
        uint256 rangeRpl = pool.rangeRplX128(d.tickLower, d.tickUpper);
        ps.accrue(d.liquidityBefore, rangeRpl);

        // Ensure each boundary tick holds at least `liquidityBefore` gross
        // liquidity so that subsequent negative deltas cannot underflow the uint128 maths in RangePool.updateTick.
        //
        // This situation arises when the position we are about to *remove* is the only provider at that boundary and the tick currently carries only the 1-wei sentinel added by `_ensureTickInitialised`.
        // If we directly apply a negative delta equal to `liquidityBefore` the call would revert inside `LiquidityMath.addDelta`.
        //
        // Fix: top-up the tick with the *missing* amount first, then apply the user requested delta.

        uint128 grossLower = pool.ticks[d.tickLower].liquidityGross;
        if (d.liquidityBefore > grossLower) {
            int128 diff = SafeCast.toInt128(uint256(d.liquidityBefore - grossLower));
            pool.modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: d.tickLower,
                    tickUpper: d.tickUpper,
                    liquidityDelta: diff,
                    tickSpacing: d.tickSpacing
                })
            );
            ps.initSnapshot(pool.rangeRplX128(d.tickLower, d.tickUpper));
        }

        uint128 grossUpper = pool.ticks[d.tickUpper].liquidityGross;
        if (d.liquidityBefore > grossUpper) {
            int128 diff = SafeCast.toInt128(uint256(d.liquidityBefore - grossUpper));
            pool.modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: d.tickLower,
                    tickUpper: d.tickUpper,
                    liquidityDelta: diff,
                    tickSpacing: d.tickSpacing
                })
            );
            // snapshot already done above; no need to repeat
        }

        // Apply user-requested delta
        pool.modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: d.liquidityDelta,
                tickSpacing: d.tickSpacing
            })
        );
    }

    /// @dev internal helper to ensure a tick is initialised
    function _ensureTickInitialised(RangePool.State storage pool, int24 tick, int24 spacing) internal {
        RangePool.TickInfo storage info = pool.ticks[tick];
        if (info.liquidityGross == 0) {
            // snapshot current accumulator on the opposite side
            info.rewardsPerLiquidityOutsideX128 = pool.rewardsPerLiquidityCumulativeX128;
            // set a sentinel liquidity so the tick is treated as initialised
            info.liquidityGross = 1;
            // no change to liquidityNet keeps net math untouched
            pool.tickBitmap.flipTick(tick, spacing);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SUBSCRIPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PositionManager through GaugeSubscriber when a new position is created.
    function notifySubscribe(uint256 tokenId, bytes memory) external onlyGaugeSubscriber {
        (PoolKey memory key, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);
        address owner = IERC721(address(POSITION_MANAGER)).ownerOf(tokenId);

        PoolId pid = key.toId();

        // ensure pool accumulators updated for each token
        IERC20[] storage toks = poolTokens[pid];
        {
            (, int24 _currTick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
            for (uint256 t; t < toks.length; ++t) {
                _updatePool(key, pid, toks[t], _currTick);
            }
        }

        // index posKey once
        bytes32 posKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));
        RangePosition.addPosition(ownerPositions, positionLiquidity, pid, owner, posKey, liquidity);

        // save tick range
        positionTicks[posKey] = TickRange({lower: info.tickLower(), upper: info.tickUpper()});

        // snapshot per token
        for (uint256 t; t < toks.length; ++t) {
            positionRewards[posKey][toks[t]].initSnapshot(
                poolRewards[pid][toks[t]].rangeRplX128(info.tickLower(), info.tickUpper())
            );
        }
        for (uint256 t; t < toks.length; ++t) {
            poolRewards[pid][toks[t]].modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: info.tickLower(),
                    tickUpper: info.tickUpper(),
                    liquidityDelta: SafeCast.toInt128(uint256(liquidity)),
                    tickSpacing: key.tickSpacing
                })
            );
        }
    }

    /// @notice Called by PositionManager through GaugeSubscriber when a position is removed.
    function notifyUnsubscribe(uint256 tokenId) external onlyGaugeSubscriber {
        (PoolKey memory key, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);
        address owner = IERC721(address(POSITION_MANAGER)).ownerOf(tokenId);
        PoolId pid = key.toId();

        IERC20[] storage _tokens = poolTokens[pid];
        uint256 _len = _tokens.length;
        {
            (, int24 _currTick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
            for (uint256 t; t < _len; ++t) {
                _updatePool(key, pid, _tokens[t], _currTick);
            }
        }

        bytes32 posKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));
        int24 _tickLower = info.tickLower();
        int24 _tickUpper = info.tickUpper();
        int24 _spacing = key.tickSpacing;

        for (uint256 t; t < _len; ++t) {
            _applyLiquidityDelta(
                DeltaParams({
                    pid: pid,
                    token: _tokens[t],
                    posKey: posKey,
                    tickLower: _tickLower,
                    tickUpper: _tickUpper,
                    tickSpacing: _spacing,
                    liquidityBefore: liquidity,
                    liquidityDelta: -SafeCast.toInt128(int256(uint256(liquidity)))
                })
            );
        }
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, owner, posKey);
        delete positionTicks[posKey];
        for (uint256 t; t < _len; ++t) {
            delete positionRewards[posKey][_tokens[t]];
        }
    }

    /// @notice Called by PositionManager through GaugeSubscriber when a position is burned.
    function notifyBurn(uint256 tokenId, address ownerAddr, PositionInfo info, uint256 liquidity, BalanceDelta)
        external
        onlyGaugeSubscriber
    {
        PoolKey memory key = IPoolKeys(address(POSITION_MANAGER)).poolKeys(info.poolId());
        PoolId pid = key.toId();

        IERC20[] storage _tokensB = poolTokens[pid];
        uint256 _lenB = _tokensB.length;
        {
            (, int24 _currTick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
            for (uint256 t; t < _lenB; ++t) {
                _updatePool(key, pid, _tokensB[t], _currTick);
            }
        }

        bytes32 posKey = keccak256(abi.encode(ownerAddr, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));
        int24 _tickLower = info.tickLower();
        int24 _tickUpper = info.tickUpper();
        int24 _spacingB = key.tickSpacing;

        for (uint256 t; t < _lenB; ++t) {
            _applyLiquidityDelta(
                DeltaParams({
                    pid: pid,
                    token: _tokensB[t],
                    posKey: posKey,
                    tickLower: _tickLower,
                    tickUpper: _tickUpper,
                    tickSpacing: _spacingB,
                    liquidityBefore: uint128(liquidity),
                    liquidityDelta: -SafeCast.toInt128(int256(uint256(liquidity)))
                })
            );
        }
        RangePosition.removePosition(ownerPositions, positionLiquidity, pid, ownerAddr, posKey);
        for (uint256 t; t < _lenB; ++t) {
            delete positionRewards[posKey][_tokensB[t]];
        }
    }

    /// @notice Called by PositionManager through GaugeSubscriber when a position's liquidity is modified.
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta)
        external
        onlyGaugeSubscriber
    {
        (PoolKey memory key, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        PoolId pid = key.toId();

        uint128 currentLiq = POSITION_MANAGER.getPositionLiquidity(tokenId);
        uint128 liquidityBefore = uint128(int128(currentLiq) - int128(liquidityChange));

        IERC20[] storage toks = poolTokens[pid];
        {
            (, int24 _currTick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
            for (uint256 t; t < toks.length; ++t) {
                _updatePool(key, pid, toks[t], _currTick);
            }
        }

        address owner = IERC721(address(POSITION_MANAGER)).ownerOf(tokenId);
        bytes32 posKey = keccak256(abi.encode(owner, info.tickLower(), info.tickUpper(), bytes32(tokenId), pid));

        // Cache
        int24 _tickLower = info.tickLower();
        int24 _tickUpper = info.tickUpper();
        int24 _tickSpacing = key.tickSpacing;

        int128 _delta = SafeCast.toInt128(liquidityChange);

        for (uint256 t; t < toks.length; ++t) {
            _applyLiquidityDelta(
                DeltaParams({
                    pid: pid,
                    token: toks[t],
                    posKey: posKey,
                    tickLower: _tickLower,
                    tickUpper: _tickUpper,
                    tickSpacing: _tickSpacing,
                    liquidityBefore: liquidityBefore,
                    liquidityDelta: _delta
                })
            );
        }

        if (currentLiq == 0) {
            RangePosition.removePosition(ownerPositions, positionLiquidity, pid, owner, posKey);
            delete positionTicks[posKey];
            for (uint256 t; t < toks.length; ++t) {
                delete positionRewards[posKey][toks[t]];
            }
        } else {
            positionLiquidity[posKey] = currentLiq;
        }
    }
}
