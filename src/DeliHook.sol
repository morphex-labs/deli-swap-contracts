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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

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

    uint24 public constant MIN_FEE = 100; // 0.01%
    uint24 public constant MAX_FEE = 30_000; // 3%

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

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeForwarded(address indexed pool, uint256 amount, bool indexed isBmxPool);
    event FeeProcessorUpdated(address indexed newFeeProcessor);
    event DailyEpochGaugeUpdated(address indexed newGauge);
    event IncentiveGaugeUpdated(address indexed newGauge);
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
        address _bmx,
        address _owner
    ) Ownable(_owner) BaseHook(_poolManager) {
        if (_wblt == address(0) || _bmx == address(0) || _owner == address(0)) revert DeliErrors.ZeroAddress();

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

    /// @notice Owner override to set a pool's dynamic LP fee.
    /// @param key The pool key identifying the pool
    /// @param newFee The new LP fee in hundredths of a bip (max 30,000 = 3%)
    function setPoolFee(PoolKey calldata key, uint24 newFee) external onlyOwner {
        if (newFee > MAX_FEE || newFee < MIN_FEE) revert DeliErrors.InvalidFee();
        poolManager.updateDynamicLPFee(key, newFee);
        emit PoolFeeSet(key.toId(), newFee);
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
                            POOL INITIALIZATION
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

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Bootstraps the DailyEpochGauge pool state and sets the derived fee.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Bootstrap DailyEpochGauge pool state
        PoolId pid = key.toId();
        dailyEpochGauge.initPool(pid, tick);

        // Derive and set the fee from tick spacing; reverts if unsupported
        uint24 derivedFee = getPoolFeeFromTickSpacing(key.tickSpacing);

        // Set the dynamic fee
        poolManager.updateDynamicLPFee(key, derivedFee);

        emit PoolFeeSet(pid, derivedFee);

        return BaseHook.afterInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP CALLBACK LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PoolManager before executing the swap.
    ///         Internal swaps still calculate fees but handle them differently.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Check if this is an internal buy-back swap
        _isInternalSwap = hookData.length >= 4 && bytes4(hookData) == InternalSwapFlag.INTERNAL_SWAP_FLAG
            && sender == address(feeProcessor);

        // Determine swap metadata
        bool exactInput = params.amountSpecified < 0;

        // Identify specified token index
        bool specifiedIs0 = params.zeroForOne ? exactInput : !exactInput;

        // Determine absolute amount of the specified token (v4 deltas are keyed to the specified token)
        uint256 absAmountSpecified = exactInput
            ? uint256(uint128(uint256(-params.amountSpecified)))
            : uint256(uint128(uint256(params.amountSpecified)));

        // Get the current sqrt price and LP fee for this pool from PoolManager
        (uint160 sqrtPriceX96,,, uint24 poolFee) = StateLibrary.getSlot0(poolManager, key.toId());

        // Compute base fee in specified-token units
        // We first denominate the fee in the specified token, then convert to the
        // designated fee currency (BMX or wBLT) using sqrtPriceX96 if needed.
        uint256 baseFeeSpecified = (absAmountSpecified * uint256(poolFee)) / 1_000_000;

        // Identify fee token (BMX on BMX pools, otherwise wBLT) and persist immediately
        bool feeCurrencyIs0 = (Currency.unwrap(key.currency0) == BMX || Currency.unwrap(key.currency1) == BMX)
            ? (Currency.unwrap(key.currency0) == BMX)
            : (Currency.unwrap(key.currency0) == WBLT);
        _pendingCurrency = feeCurrencyIs0 ? key.currency0 : key.currency1;

        // Convert fee to feeCurrency units if it differs from specified token
        // Price p = (sqrtPriceX96^2) / 2^192 (token1 per token0).
        // Conversions follow v4 rounding conventions:
        //  - token0 -> token1: floor(base * p)
        //  - token1 -> token0: ceil(base / p)
        if (feeCurrencyIs0 == specifiedIs0) {
            _pendingFee = baseFeeSpecified;
        } else {
            if (specifiedIs0) {
                // specified = token0, feeCurrency = token1
                uint256 inter = FullMath.mulDiv(baseFeeSpecified, sqrtPriceX96, FixedPoint96.Q96);
                _pendingFee = FullMath.mulDiv(inter, sqrtPriceX96, FixedPoint96.Q96);
            } else {
                // specified = token1, feeCurrency = token0
                uint256 inter = FullMath.mulDivRoundingUp(baseFeeSpecified, FixedPoint96.Q96, sqrtPriceX96);
                _pendingFee = FullMath.mulDivRoundingUp(inter, FixedPoint96.Q96, sqrtPriceX96);
            }
        }

        // For non-BMX pools: use BeforeSwapDelta when fee is on input side (exact input swaps)
        // Never pull tokens from sender for internal swaps (fees still apply but are handled differently)
        bool feeMatchesSpecified = (feeCurrencyIs0 == specifiedIs0);
        bool isFeeBmx = Currency.unwrap(_pendingCurrency) == BMX;
        _pullFromSender = (!_isInternalSwap && !isFeeBmx && feeMatchesSpecified && exactInput);

        // Calculate BeforeSwapDelta
        int128 specifiedDelta = 0;

        // Pre-credit the specified side by the fee whenever the fee currency matches the specified token.
        // This handles both exact input (fee on input) and exact output (fee on output) uniformly.
        if (feeMatchesSpecified) {
            specifiedDelta = SafeCast.toInt128(int256(_pendingFee));
        }

        return (
            BaseHook.beforeSwap.selector,
            specifiedDelta == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(specifiedDelta, 0),
            LPFeeLibrary.OVERRIDE_FEE_FLAG // Override classic LP fee to 0; hook collects and forwards fees itself
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

        // Lazy-roll daily epoch & checkpoint pool **before** fee handling so that any deltas they create are cleared first.
        dailyEpochGauge.rollIfNeeded(key.toId());
        dailyEpochGauge.pokePool(key);
        incentiveGauge.pokePool(key);

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

            // Only return positive delta when fee is on the unspecified side (relative to specified token)
            // After-swap delta must be expressed in the unspecified token per v4.
            bool exactInput = params.amountSpecified < 0;
            bool zeroForOne = params.zeroForOne;
            Currency specifiedCurrency =
                zeroForOne ? (exactInput ? key.currency0 : key.currency1) : (exactInput ? key.currency1 : key.currency0);
            if (Currency.unwrap(feeCurrency) != Currency.unwrap(specifiedCurrency)) {
                // Return positive delta in the unspecified token equal to the fee taken
                hookDeltaUnspecified = SafeCast.toInt128(int256(feeOwed));
            }
        }

        return (BaseHook.afterSwap.selector, hookDeltaUnspecified);
    }

    /*//////////////////////////////////////////////////////////////
                             FEE DETERMINATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the LP fee for a supported tick spacing (in hundredths of a bip, out of 1_000_000)
    /// @dev Reverts with InvalidTickSpacing for unsupported spacings
    function getPoolFeeFromTickSpacing(int24 tickSpacing) public pure returns (uint24) {
        if (tickSpacing == 1) return 100; // 0.01%
        if (tickSpacing == 10) return 300; // 0.03%
        if (tickSpacing == 40) return 1_500; // 0.15%
        if (tickSpacing == 60) return 3_000; // 0.30%
        if (tickSpacing == 100) return 4_000; // 0.40%
        if (tickSpacing == 200) return 6_500; // 0.65%
        if (tickSpacing == 300) return 10_000; // 1.00%
        if (tickSpacing == 400) return 17_500; // 1.75%
        if (tickSpacing == 600) return 25_000; // 2.50%
        revert DeliErrors.InvalidTickSpacing();
    }
}
