// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
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
    using BalanceDeltaLibrary for BalanceDelta;

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
    uint256 private _pendingFee; // base fee in specified-token units; converted to wBLT in _afterSwap
    Currency private _pendingCurrency; // fee token for current swap
    bool private _isInternalSwap; // true if current swap is internal buyback

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

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
    /// @param _key The pool key identifying the pool
    /// @param _newFee The new LP fee in hundredths of a bip (max 30,000 = 3%)
    function setPoolFee(PoolKey calldata _key, uint24 _newFee) external onlyOwner {
        if (_newFee > MAX_FEE || _newFee < MIN_FEE) revert DeliErrors.InvalidFee();
        poolManager.updateDynamicLPFee(_key, _newFee);
        emit PoolFeeSet(_key.toId(), _newFee);
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

    /// @notice Bootstraps the DailyEpochGauge and IncentiveGauge pool state.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        dailyEpochGauge.initPool(key, tick);
        incentiveGauge.initPool(key, tick);

        // Derive and set the fee from tick spacing; reverts if unsupported
        uint24 derivedFee = getPoolFeeFromTickSpacing(key.tickSpacing);

        // Set the dynamic fee
        poolManager.updateDynamicLPFee(key, derivedFee);

        emit PoolFeeSet(key.toId(), derivedFee);

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
        uint256 absAmountSpecified;
        unchecked {
            absAmountSpecified = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
        }

        // Get the current LP fee for this pool from PoolManager
        (,,, uint24 poolFee) = StateLibrary.getSlot0(poolManager, key.toId());

        // Compute fee-aware budget in specified-token units to respect price-limit on input.
        // - exact input:  F_pre = floor(S0 * fee / (1e6 + fee))  → net budget S0 - F_pre
        // - exact output: F_pre = floor(S0 * fee / (1e6 - fee))  → gross requirement S0 + F_pre
        uint256 baseFeeSpecified = exactInput
            ? FullMath.mulDivRoundingUp(absAmountSpecified, uint256(poolFee), 1_000_000 + uint256(poolFee))
            : FullMath.mulDivRoundingUp(absAmountSpecified, uint256(poolFee), 1_000_000 - uint256(poolFee));

        // Identify fee token: always collect in wBLT
        bool feeCurrencyIs0 = (Currency.unwrap(key.currency0) == WBLT);
        _pendingCurrency = feeCurrencyIs0 ? key.currency0 : key.currency1;

        // Cache base fee (specified-token units). Conversion to wBLT is done in _afterSwap
        _pendingFee = baseFeeSpecified;

        // Use BeforeSwapDelta when fee is on input side (exact input swaps)
        bool feeMatchesSpecified = (feeCurrencyIs0 == specifiedIs0);
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
        BalanceDelta swapDelta,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        // Retrieve cached base fee (specified-token units) from beforeSwap
        uint256 baseFeeSpecified = _pendingFee;
        Currency feeCurrency = _pendingCurrency;
        bool isInternalSwap = _isInternalSwap;

        // Reset pending fee storage
        _pendingFee = 0;
        _pendingCurrency = Currency.wrap(address(0));
        _isInternalSwap = false;

        // Checkpoint pool **before** fee handling so that any deltas they create are cleared first.
        dailyEpochGauge.pokePool(key);
        incentiveGauge.pokePool(key);

        // Forward the swap fee to FeeProcessor
        int128 hookDeltaUnspecified = 0;

        if (baseFeeSpecified > 0) {
            (uint256 feeOwed, bool feeOnUnspecified) = _computeFeeOwedAndDelta(key, params, swapDelta, baseFeeSpecified);

            // Always take the fee from PoolManager
            feeCurrency.take(poolManager, address(feeProcessor), feeOwed, false);

            // Send wBLT fee to FeeProcessor
            feeProcessor.collectFee(key, feeOwed, isInternalSwap);

            // Only return positive delta when fee is on the unspecified side (relative to specified token)
            // After-swap delta must be expressed in the unspecified token per v4.
            if (feeOnUnspecified) {
                // Return positive delta in the unspecified token equal to the fee taken
                hookDeltaUnspecified = SafeCast.toInt128(int256(feeOwed));
            }
        }

        return (BaseHook.afterSwap.selector, hookDeltaUnspecified);
    }

    function _computeFeeOwedAndDelta(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        uint256 baseFeeSpecified
    ) private view returns (uint256 feeOwed, bool feeOnUnspecified) {
        bool specifiedIs0 = params.zeroForOne ? (params.amountSpecified < 0) : !(params.amountSpecified < 0);
        bool feeCurrencyIs0 = (Currency.unwrap(key.currency0) == WBLT);

        (uint160 sqrtPriceX96,,, uint24 poolFee) = StateLibrary.getSlot0(poolManager, key.toId());

        uint256 absActualSpecified = uint256(
            specifiedIs0
                ? (swapDelta.amount0() < 0 ? -int256(swapDelta.amount0()) : int256(swapDelta.amount0()))
                : (swapDelta.amount1() < 0 ? -int256(swapDelta.amount1()) : int256(swapDelta.amount1()))
        );

        // Base fee on actual traded amount (dust-protect)
        uint256 baseFeeActual = FullMath.mulDivRoundingUp(absActualSpecified, uint256(poolFee), 1_000_000);

        if (feeCurrencyIs0 == specifiedIs0) {
            // Fee is on the specified side: derive fee from ACTUAL specified-side delta,
            // then cap by the pre-withheld budget to respect price limits and partial fills.
            bool exactInput = params.amountSpecified < 0;
            uint256 feeFromDelta = exactInput
                // exact input: afterSwap specified delta is NET => F = ceil(net * f / (1e6 - f))
                ? FullMath.mulDivRoundingUp(absActualSpecified, uint256(poolFee), 1_000_000 - uint256(poolFee))
                // exact output: afterSwap specified delta is GROSS => F = ceil(gross * f / (1e6 + f))
                : FullMath.mulDivRoundingUp(absActualSpecified, uint256(poolFee), 1_000_000 + uint256(poolFee));

            feeOwed = feeFromDelta > baseFeeSpecified ? baseFeeSpecified : feeFromDelta;
            feeOnUnspecified = false;
            return (feeOwed, feeOnUnspecified);
        }

        // Conversion at post-swap price with v4 rounding conventions
        if (specifiedIs0) {
            // token0 (specified) -> token1 (wBLT): floor(base * p)
            feeOwed = FullMath.mulDiv(
                FullMath.mulDiv(baseFeeActual, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
            );
        } else {
            // token1 (specified) -> token0 (wBLT): ceil(base / p), avoid double rounding-up
            feeOwed = FullMath.mulDivRoundingUp(
                FullMath.mulDiv(baseFeeActual, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );
        }

        feeOnUnspecified = true;
        return (feeOwed, feeOnUnspecified);
    }

    /*//////////////////////////////////////////////////////////////
                             FEE DETERMINATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the LP fee for a supported tick spacing (in hundredths of a bip, out of 1_000_000)
    /// @dev Reverts with InvalidTickSpacing for unsupported spacings
    function getPoolFeeFromTickSpacing(int24 _tickSpacing) public pure returns (uint24) {
        if (_tickSpacing == 1) return 100; // 0.01%
        if (_tickSpacing == 10) return 300; // 0.03%
        if (_tickSpacing == 40) return 1_500; // 0.15%
        if (_tickSpacing == 60) return 3_000; // 0.30%
        if (_tickSpacing == 100) return 4_000; // 0.40%
        if (_tickSpacing == 200) return 6_500; // 0.65%
        if (_tickSpacing == 300) return 10_000; // 1.00%
        if (_tickSpacing == 400) return 17_500; // 1.75%
        if (_tickSpacing == 600) return 25_000; // 2.50%
        revert DeliErrors.InvalidTickSpacing();
    }
}
