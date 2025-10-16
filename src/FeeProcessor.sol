// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {IDailyEpochGauge} from "./interfaces/IDailyEpochGauge.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";
import {InternalSwapFlag} from "./libraries/InternalSwapFlag.sol";

/**
 * @title FeeProcessor
 * @notice Splits and manages swap fees forwarded by hooks.
 *         97% is converted into BMX via onchain buyback and streamed to DailyEpochGauge;
 *         the remaining 3% is retained in wBLT for voter distribution. Governance can
 *         adjust split ratios and slippage limits or recover mistaken tokens.
 *
 * Flow summary
 * 1. Hooks call {collectFee} transferring wBLT fees here (internal swaps are flagged but still charged).
 * 2. Amount is split into a per-pool buyback buffer and a global voter buffer; pools with nonzero
 *    buffers are tracked for keepers.
 * 3. When a buyback pool is configured and buffer ≥ MIN_WBLT_FOR_BUYBACK, keepers call {flushBuffer}
 *    to execute swaps via PoolManager.unlock; BMX out is validated against a provided minimum.
 * 4. BMX obtained from buybacks is forwarded to DailyEpochGauge via {addRewards}.
 */
contract FeeProcessor is Ownable2Step, SafeCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using InternalSwapFlag for bytes;
    using TransientStateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/

    Currency public immutable WBLT;
    address public immutable BMX;
    IDailyEpochGauge public immutable DAILY_GAUGE;

    // minimum wBLT amount required to execute a buyback (1 wBLT)
    uint256 public constant MIN_WBLT_FOR_BUYBACK = 1e18;

    // configurable share for buyback (in basis points, 9700 = 97%).
    uint16 public buybackBps = 9700;

    // poolKey to use for buyback swaps (BMX/wBLT pool)
    PoolKey public buybackPoolKey;
    bool public buybackPoolSet;

    // pending swap state
    uint256 private _pendingAmount;
    PoolId private _pendingSourcePool;
    uint256 private _expectedMinBmxOut;

    // Accumulated wBLT awaiting swap → BMX buyback (per-pool tracking)
    mapping(PoolId => uint256) public pendingWbltForBuyback;
    uint256 public pendingWbltForVoter;

    mapping(address => bool) public isHook; // Authorized hooks
    mapping(address => bool) public isKeeper; // Authorized keepers

    // Tracking of pools with pending buyback buffers for efficient keeper queries
    PoolId[] private pendingPools;
    mapping(PoolId => uint256) private pendingPoolIndex; // 1-based index; 0 means not present

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeCollected(
        address indexed hook,
        PoolId indexed poolId,
        uint256 totalAmount,
        uint256 buybackPortion,
        uint256 voterPortion,
        bool indexed isInternalSwap
    );
    event BuybackPoolSet(PoolId poolId);
    event BuybackExecuted(PoolId indexed poolId, uint256 wbltIn, uint256 bmxOut);
    event BuybackBpsUpdated(uint16 newBps);
    event VoterFeesClaimed(uint256 amount, address to);
    event TokenSwept(address indexed token, uint256 amount, address indexed to);
    event HookAuthorised(address hook, bool enabled);
    event KeeperAuthorised(address keeper, bool enabled);

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager, address _hook, address _wblt, address _bmx, IDailyEpochGauge _dailyGauge)
        Ownable(msg.sender)
        SafeCallback(_poolManager)
    {
        poolManager = _poolManager;
        isHook[_hook] = true; // whitelist initial hook

        emit HookAuthorised(_hook, true);

        WBLT = Currency.wrap(_wblt);
        BMX = _bmx;
        DAILY_GAUGE = _dailyGauge;
    }

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHook() {
        if (!isHook[msg.sender]) revert DeliErrors.NotHook();
        _;
    }

    modifier onlyKeeper() {
        if (!(isKeeper[msg.sender] || msg.sender == address(this))) revert DeliErrors.NotAllowed();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers the accumulated 3 % voter share (stored as wBLT) to `_to`.
    /// @param _to Recipient address that receives the buffered wBLT.
    /// @dev Intended to be called once per week by governance after
    ///      converting the amount to wETH off-chain and before forwarding to the
    ///      Voter contract.
    function claimVoterFees(address _to) external onlyOwner {
        uint256 amt = pendingWbltForVoter;
        if (amt == 0) revert DeliErrors.NoFunds();
        pendingWbltForVoter = 0;
        IERC20(Currency.unwrap(WBLT)).safeTransfer(_to, amt);
        emit VoterFeesClaimed(amt, _to);
    }

    /// @notice Governance setter for the buy-back share (in basis points).
    /// @param _newBps New buy-back percentage expressed in BPS (0 ‑ 10 000).
    function setBuybackBps(uint16 _newBps) external onlyOwner {
        if (_newBps > 10_000) revert DeliErrors.InvalidBps();
        buybackBps = _newBps;
        emit BuybackBpsUpdated(_newBps);
    }

    /// @notice Authorise or de-authorise a keeper address.
    /// @param _keeper The address to authorise or de-authorise.
    /// @param _enabled Whether to authorise or de-authorise the address.
    function setKeeper(address _keeper, bool _enabled) external onlyOwner {
        if (_keeper == address(0)) revert DeliErrors.ZeroAddress();
        isKeeper[_keeper] = _enabled;
        emit KeeperAuthorised(_keeper, _enabled);
    }

    /// @notice Configuration of the BMX/wBLT pool used for buy-backs.
    /// @param _key The poolKey of the BMX/wBLT pool.
    function setBuybackPoolKey(PoolKey calldata _key) external onlyOwner {
        // pair must consist of BMX and wBLT
        bool hasBmx = Currency.unwrap(_key.currency0) == BMX || Currency.unwrap(_key.currency1) == BMX;
        bool hasWblt = _key.currency0 == WBLT || _key.currency1 == WBLT;
        if (!(hasBmx && hasWblt)) revert DeliErrors.InvalidPoolKey();
        buybackPoolKey = _key;
        if (!buybackPoolSet) {
            buybackPoolSet = true;
        }
        emit BuybackPoolSet(_key.toId());
    }

    /// @notice Authorise or de-authorise a hook address.
    /// @param _hook The address to authorise or de-authorise.
    /// @param _enabled Whether to authorise or de-authorise the address.
    function setHook(address _hook, bool _enabled) external onlyOwner {
        if (_hook == address(0)) revert DeliErrors.ZeroAddress();
        isHook[_hook] = _enabled;
        emit HookAuthorised(_hook, _enabled);
    }

    /// @notice Owner can recover arbitrary ERC-20 tokens mistakenly sent to this
    ///         contract, except BMX and wBLT which are part of the fee flow.
    /// @param _token The ERC-20 address to sweep.
    /// @param _amount Amount to transfer.
    /// @param _to Recipient of the swept tokens.
    function sweepERC20(address _token, uint256 _amount, address _to) external onlyOwner {
        if (_token == Currency.unwrap(WBLT) || _token == BMX) revert DeliErrors.NotAllowed();
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokenSwept(_token, _amount, _to);
    }

    /*//////////////////////////////////////////////////////////////
                        BUFFER AND FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes a pool's pending buy-back buffer using an explicit minimum expected BMX out.
    /// @dev Reverts if no buy-back pool key has been configured yet. Reverts if below threshold.
    /// @param poolId The pool ID whose pending wBLT buffer to flush.
    /// @param expectedBmxOut The minimum expected BMX output for slippage protection.
    function flushBuffer(PoolId poolId, uint256 expectedBmxOut) external onlyKeeper {
        if (!buybackPoolSet) revert DeliErrors.NoKey();
        uint256 poolPending = pendingWbltForBuyback[poolId];
        if (poolPending < MIN_WBLT_FOR_BUYBACK) revert DeliErrors.BelowMinimumThreshold();
        _pendingSourcePool = poolId;
        _expectedMinBmxOut = expectedBmxOut;
        _initiateSwap(poolPending);
    }

    /// @notice Batch version of {flushBuffer}.
    /// @dev If any flushBuffer call fails, the loop will continue.
    /// @param poolIds The pool IDs whose pending wBLT buffers to flush.
    /// @param expectedBmxOuts The minimum expected BMX outputs for slippage protection.
    function flushBuffers(PoolId[] calldata poolIds, uint256[] calldata expectedBmxOuts) external onlyKeeper {
        if (poolIds.length != expectedBmxOuts.length) revert DeliErrors.InvalidOption();
        for (uint256 i = 0; i < poolIds.length; i++) {
            // Use try-catch per iteration to avoid reverting the whole batch
            try this.flushBuffer(poolIds[i], expectedBmxOuts[i]) {} catch {}
        }
    }

    /// @notice Called by DeliHook after it transfers `amount` of the fee token to this contract.
    /// @dev Splits amount into buy-back and voter portions, buffers and/or swaps as needed.
    /// @param key The pool key of the pool that collected the fee.
    /// @param amountWblt The amount of wBLT fee collected.
    /// @param isInternalSwap Whether the swap is internal buyback swap.
    function collectFee(PoolKey calldata key, uint256 amountWblt, bool isInternalSwap) external onlyHook {
        if (amountWblt == 0) revert DeliErrors.ZeroAmount();

        PoolId poolId = key.toId();

        uint256 buybackPortion = (amountWblt * buybackBps) / 10_000;
        uint256 voterPortion = amountWblt - buybackPortion;

        emit FeeCollected(msg.sender, poolId, amountWblt, buybackPortion, voterPortion, isInternalSwap);

        uint256 oldBuyback = pendingWbltForBuyback[poolId];
        pendingWbltForBuyback[poolId] = oldBuyback + buybackPortion; // track per-pool buyback buffer
        pendingWbltForVoter += voterPortion; // track voter buffer for weekly sweep

        // If buffer transitioned from 0 -> >0, add to pending set
        if (oldBuyback == 0 && buybackPortion > 0 && pendingPoolIndex[poolId] == 0) {
            pendingPools.push(poolId);
            pendingPoolIndex[poolId] = pendingPools.length; // 1-based
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Removes a pool from the pending set using swap-and-pop.
    function _removePendingPool(PoolId poolId) internal {
        uint256 index = pendingPoolIndex[poolId];
        if (index == 0) return; // not present
        uint256 lastIdx = pendingPools.length;
        if (index != lastIdx) {
            PoolId lastPoolId = pendingPools[lastIdx - 1];
            pendingPools[index - 1] = lastPoolId;
            pendingPoolIndex[lastPoolId] = index;
        }
        pendingPools.pop();
        pendingPoolIndex[poolId] = 0;
    }

    /// @dev Initiates a WBLT -> BMX buyback swap for the specified amount.
    function _initiateSwap(uint256 amount) internal {
        // Track the amount to swap
        _pendingAmount = amount;

        // Clear the buffer
        pendingWbltForBuyback[_pendingSourcePool] = 0;

        // Unlock and execute via callback
        poolManager.unlock("");
    }

    /// @inheritdoc SafeCallback
    function _unlockCallback(bytes calldata) internal override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert DeliErrors.NotPoolManager();
        _executeSwap();
        return bytes("");
    }

    /// @dev Executes the pending swap operation, called from _unlockCallback or directly if already unlocked.
    function _executeSwap() internal {
        uint256 amtIn = _pendingAmount;
        if (amtIn == 0) revert DeliErrors.NoSwap();

        // Derive pool orientation helpers
        Currency c0 = buybackPoolKey.currency0;
        Currency c1 = buybackPoolKey.currency1;
        bool wbltIsC0 = (c0 == WBLT);

        // Determine swap direction (wBLT on token0 side means zeroForOne)
        bool zeroForOne = wbltIsC0;

        // Settle input token from this contract into PoolManager
        (wbltIsC0 ? c0 : c1).settle(poolManager, address(this), uint128(amtIn), false);

        SwapParams memory sp = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amtIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Execute the swap
        BalanceDelta delta = poolManager.swap(buybackPoolKey, sp, abi.encode(InternalSwapFlag.INTERNAL_SWAP_FLAG));

        // Determine output values & currency helpers
        Currency outCurrency = zeroForOne ? c1 : c0;
        uint256 outAmt = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        if (outAmt < _expectedMinBmxOut) revert DeliErrors.Slippage();

        // Pull tokens owed from PoolManager
        outCurrency.take(poolManager, address(this), outAmt, false);

        // Output is BMX, stream to gauge
        IERC20(BMX).safeTransfer(address(DAILY_GAUGE), outAmt);
        DAILY_GAUGE.addRewards(_pendingSourcePool, outAmt);
        emit BuybackExecuted(_pendingSourcePool, amtIn, outAmt);

        _pendingAmount = 0;

        // If the pool's buffer is still zero after a successful buyback, remove it from the pending set
        PoolId sourcePool = _pendingSourcePool;
        _pendingSourcePool = PoolId.wrap(bytes32(0));
        _expectedMinBmxOut = 0;
        if (pendingWbltForBuyback[sourcePool] == 0) {
            _removePendingPool(sourcePool);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the list of pools that currently have a non-zero pending buyback buffer.
    /// @return pendingPools The list of pools that currently have a non-zero pending buyback buffer.
    function getPendingPools() external view returns (PoolId[] memory) {
        return pendingPools;
    }

    /// @notice Returns the count of pools with non-zero pending buyback buffers.
    /// @return pendingPoolsCount The count of pools with non-zero pending buyback buffers.
    function pendingPoolsCount() external view returns (uint256) {
        return pendingPools.length;
    }

    /// @notice Returns the poolId at a given index in the pending set.
    /// @param index The index of the pool to return.
    /// @return poolId The poolId at the given index.
    function getPendingPoolByIndex(uint256 index) external view returns (PoolId) {
        return pendingPools[index];
    }
}
