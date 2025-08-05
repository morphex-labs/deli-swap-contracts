// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IIncentiveGauge} from "./interfaces/IIncentiveGauge.sol";
import {IFeeProcessor} from "./interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "./interfaces/IDailyEpochGauge.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";
import {InternalSwapFlag} from "./libraries/InternalSwapFlag.sol";

/**
 * @title DeliHook
 * @notice Uniswap v4 hook that (1) collects swap fees and forwards them to
 *         FeeProcessor, and (2) keeps DailyEpochGauge and IncentiveGauge in
 *         sync on every swap. Pools that wish to use this hook MUST include
 *         wBLT as either currency0 or currency1; this constraint is enforced
 *         during pool initialisation.
 */
contract DeliHook is Ownable2Step, BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using CurrencyDelta for Currency;
    using SafeCast for uint256;
    using InternalSwapFlag for bytes;
    using LPFeeLibrary for uint24;

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    uint24 public constant MAX_FEE = 50000; // 5%

    address public immutable WBLT;
    address public immutable BMX;

    IFeeProcessor public feeProcessor;
    IDailyEpochGauge public dailyEpochGauge;
    IIncentiveGauge public incentiveGauge;

    // Temporary fee info cached between beforeSwap and afterSwap.
    uint256 private _pendingFee; // amount of wBLT fee owed for current swap
    bool private _pullFromSender; // true if we must pull extra fee token from trader (input side)
    Currency private _pendingCurrency; // fee token for current swap
    bool private _isInternalSwap; // true if current swap is internal buyback

    // Fee registration system
    mapping(bytes32 => uint24) private _pendingPoolFees; // poolKey hash => registered fee

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeForwarded(address indexed pool, uint256 amount, bool indexed isBmxPool);
    event FeeProcessorUpdated(address indexed newFeeProcessor);
    event DailyEpochGaugeUpdated(address indexed newGauge);
    event IncentiveGaugeUpdated(address indexed newGauge);
    event PoolFeeRegistered(
        Currency indexed currency0, Currency indexed currency1, int24 tickSpacing, uint24 fee, address registrant
    );
    event PoolFeeSet(PoolId indexed poolId, uint24 fee);

    /*//////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager _poolManager,
        IFeeProcessor _feeProcessor,
        IDailyEpochGauge _dailyEpochGauge,
        IIncentiveGauge _incentiveGauge,
        address _wblt,
        address _bmx
    ) Ownable(msg.sender) BaseHook(_poolManager) {
        if (_wblt == address(0) || _bmx == address(0)) revert DeliErrors.ZeroAddress();

        feeProcessor = _feeProcessor;
        dailyEpochGauge = _dailyEpochGauge;
        incentiveGauge = _incentiveGauge;
        WBLT = _wblt;
        BMX = _bmx;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the address of the FeeProcessor contract.
    /// @param _fp The address of the FeeProcessor contract.
    function setFeeProcessor(address _fp) external onlyOwner {
        if (_fp == address(0)) revert DeliErrors.ZeroAddress();
        feeProcessor = IFeeProcessor(_fp);
        emit FeeProcessorUpdated(_fp);
    }

    /// @notice Set the address of the DailyEpochGauge contract.
    /// @param _gauge The address of the DailyEpochGauge contract.
    function setDailyEpochGauge(address _gauge) external onlyOwner {
        if (_gauge == address(0)) revert DeliErrors.ZeroAddress();
        dailyEpochGauge = IDailyEpochGauge(_gauge);
        emit DailyEpochGaugeUpdated(_gauge);
    }

    /// @notice Set the address of the IncentiveGauge contract.
    /// @param _gauge The address of the IncentiveGauge contract.
    function setIncentiveGauge(address _gauge) external onlyOwner {
        if (_gauge == address(0)) revert DeliErrors.ZeroAddress();
        incentiveGauge = IIncentiveGauge(_gauge);
        emit IncentiveGaugeUpdated(_gauge);
    }

    /*//////////////////////////////////////////////////////////////
                              FEE REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Register desired fee for a pool before initialization
    /// @param currency0 First currency of the pool
    /// @param currency1 Second currency of the pool
    /// @param tickSpacing Tick spacing of the pool
    /// @param desiredFee The fee to set (in hundredths of a bip, max 100000 = 10%)
    function registerPoolFee(Currency currency0, Currency currency1, int24 tickSpacing, uint24 desiredFee) external {
        // Validate fee is reasonable (must be > 0 and <= 5%)
        if (desiredFee == 0 || desiredFee > MAX_FEE) revert DeliErrors.InvalidFee();

        // Calculate pool key hash
        bytes32 keyHash = _hashPoolKey(currency0, currency1, tickSpacing);

        // Store the pending fee
        _pendingPoolFees[keyHash] = desiredFee;

        emit PoolFeeRegistered(currency0, currency1, tickSpacing, desiredFee, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
        p.beforeSwapReturnDelta = true;
        return p;
    }

    /*//////////////////////////////////////////////////////////////
                         POOL INITIALIZATION CHECK
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure any pool that chooses this hook includes wBLT as one of the two currencies.
    function _beforeInitialize(address, /*sender*/ PoolKey calldata key, uint160 /*sqrtPriceX96*/ )
        internal
        view
        override
        returns (bytes4)
    {
        // Disallow native ETH
        if (Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0)) {
            revert DeliErrors.NativeEthNotSupported();
        }

        // Require wBLT to be either token of the pair
        if (!(key.currency0 == Currency.wrap(WBLT) || key.currency1 == Currency.wrap(WBLT))) {
            revert DeliErrors.WbltMissing();
        }

        // Require pool to use dynamic fee (to override LP fees)
        if (!key.fee.isDynamicFee()) {
            revert DeliErrors.MustUseDynamicFee();
        }

        // Require deployed gauges + fee processor
        if (address(dailyEpochGauge) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(incentiveGauge) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(feeProcessor) == address(0)) revert DeliErrors.ComponentNotDeployed();

        // Check that a fee has been registered for this pool
        bytes32 keyHash = _hashPoolKey(key.currency0, key.currency1, key.tickSpacing);
        if (_pendingPoolFees[keyHash] == 0) {
            revert DeliErrors.PoolFeeNotRegistered();
        }

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Bootstraps the DailyEpochGauge pool state and sets the registered fee.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Bootstrap DailyEpochGauge pool state
        PoolId pid = key.toId();
        dailyEpochGauge.initPool(pid, tick);

        // Get and set the registered fee
        bytes32 keyHash = _hashPoolKey(key.currency0, key.currency1, key.tickSpacing);
        uint24 registeredFee = _pendingPoolFees[keyHash];

        // Set the dynamic fee
        poolManager.updateDynamicLPFee(key, registeredFee);

        // Clean up
        delete _pendingPoolFees[keyHash];

        emit PoolFeeSet(pid, registeredFee);

        return BaseHook.afterInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                             CALLBACK OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PoolManager before executing the swap.
    ///         Internal swaps still calculate fees but handle them differently.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Check if this is an internal buy-back swap
        bool isInternalSwap = hookData.length >= 4 && bytes4(hookData) == InternalSwapFlag.INTERNAL_SWAP_FLAG
            && sender == address(feeProcessor);

        // Determine swap metadata
        bool exactInput = params.amountSpecified < 0;
        bool zeroForOne = params.zeroForOne;

        // Identify specified currency to compute absolute amount
        uint256 absAmountSpecified = exactInput
            ? uint256(uint128(uint256(-params.amountSpecified)))
            : uint256(uint128(uint256(params.amountSpecified)));

        // Get the actual fee for this pool from PoolManager
        (,,, uint24 poolFee) = StateLibrary.getSlot0(poolManager, key.toId());

        // Compute fee amount based on actual pool fee
        uint256 feeAmount = (absAmountSpecified * uint256(poolFee)) / 1_000_000;

        // Identify whether this is BMX/wBLT pool (different logic)
        bool isBmxPool = (Currency.unwrap(key.currency0) == BMX) || (Currency.unwrap(key.currency1) == BMX);

        // Identify fee token
        Currency feeCurrency = isBmxPool
            ? (key.currency0 == Currency.wrap(BMX) ? key.currency0 : key.currency1)
            : (key.currency0 == Currency.wrap(WBLT) ? key.currency0 : key.currency1);

        // Identify input currency
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;

        // For non-BMX pools: use BeforeSwapDelta when fee is on input side (exact input swaps)
        // Never pull from sender for internal swaps
        _pullFromSender = (!isInternalSwap && !isBmxPool && feeCurrency == inputCurrency && exactInput);

        // Persist info for _afterSwap
        _pendingFee = feeAmount;
        _pendingCurrency = feeCurrency;
        _isInternalSwap = isInternalSwap;

        // Calculate BeforeSwapDelta
        int128 specifiedDelta = 0;

        if (_pullFromSender && feeAmount > 0) {
            // For exact input with fee on input side:
            // Reduce the swap input by the fee amount by returning a positive delta
            specifiedDelta = SafeCast.toInt128(int256(feeAmount));
        } else if (isBmxPool && feeCurrency == inputCurrency && feeAmount > 0) {
            // BMX pool: pre-credit to offset later take()
            specifiedDelta = SafeCast.toInt128(int256(feeAmount));
        }

        return (
            BaseHook.beforeSwap.selector,
            specifiedDelta == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(specifiedDelta, 0),
            poolFee | LPFeeLibrary.OVERRIDE_FEE_FLAG // Return actual fee with override flag
        );
    }

    /// @notice Responsible for forwarding collected fees and epoch maintenance
    function _afterSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, /*balanceDelta*/
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        // Collect the wBLT fee owed from beforeSwap
        uint256 feeOwed = _pendingFee;
        Currency feeCurrency = _pendingCurrency;
        bool isInternalSwap = _isInternalSwap;

        // Reset pending fee storage
        _pendingFee = 0;
        _pendingCurrency = Currency.wrap(address(0));
        _isInternalSwap = false;

        // Skip gauge updates for internal swaps but still collect fees
        if (!isInternalSwap) {
            // Lazy-roll daily epoch & checkpoint pool **before** fee handling so that any deltas they create are cleared first.
            dailyEpochGauge.rollIfNeeded(key.toId());
            dailyEpochGauge.pokePool(key);
            incentiveGauge.pokePool(key);
        }

        // Clear the deltas produced by the gauge calls so we start fee logic from a zero-balance baseline.
        _clearHookDeltas(key);

        // Forward the swap fee to FeeProcessor
        int128 hookDeltaUnspecified = 0;

        if (feeOwed > 0) {
            // Always take the fee from PoolManager
            feeCurrency.take(poolManager, address(feeProcessor), feeOwed, false);

            if (isInternalSwap) {
                // For internal swaps from BMX pool, distribute fees directly
                // All internal swaps use BMX/wBLT pool, so fee is always BMX
                feeProcessor.collectInternalFee(feeOwed);
            } else {
                // Normal fee collection
                feeProcessor.collectFee(key, feeOwed);
            }

            // Only return positive delta when fee is on OUTPUT side
            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

            // If fee was NOT handled by BeforeSwapDelta (i.e., fee is on output side)
            if (Currency.unwrap(feeCurrency) != Currency.unwrap(inputCurrency)) {
                // Return positive delta to offset the negative delta created by take()
                hookDeltaUnspecified = SafeCast.toInt128(int256(feeOwed));
            }
        }

        // Clear hook deltas
        _clearHookDeltas(key);

        return (BaseHook.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @dev Zero out any outstanding deltas the hook has for both pool currencies. Uses settle() when the hook owes tokens and take() when the pool owes the hook. After execution the hook’s delta for each currency is guaranteed to be zero so PoolManager won’t revert.
    function _clearHookDeltas(PoolKey memory key) internal returns (int128 res0, int128 res1) {
        // --- currency0 ---
        int256 d0 = key.currency0.getDelta(address(this));
        if (d0 < 0) {
            key.currency0.settle(poolManager, address(this), uint256(-d0), false);
        } else if (d0 > 0) {
            key.currency0.take(poolManager, address(this), uint256(d0), false);
        }

        // --- currency1 ---
        int256 d1 = key.currency1.getDelta(address(this));
        if (d1 < 0) {
            key.currency1.settle(poolManager, address(this), uint256(-d1), false);
        } else if (d1 > 0) {
            key.currency1.take(poolManager, address(this), uint256(d1), false);
        }

        // return updated deltas after operations
        res0 = SafeCast.toInt128(key.currency0.getDelta(address(this)));
        res1 = SafeCast.toInt128(key.currency1.getDelta(address(this)));
    }

    /// @dev Hash a pool key for fee registration lookup
    function _hashPoolKey(Currency currency0, Currency currency1, int24 tickSpacing) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                currency0,
                currency1,
                tickSpacing,
                address(this) // hook
            )
        );
    }
}
