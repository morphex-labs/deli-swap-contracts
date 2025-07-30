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

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable WBLT;
    address public immutable BMX;

    IFeeProcessor public feeProcessor;
    IDailyEpochGauge public dailyEpochGauge;
    IIncentiveGauge public incentiveGauge;

    // Temporary fee info cached between beforeSwap and afterSwap.
    uint256 private _pendingFee; // amount of wBLT fee owed for current swap
    bool private _pullFromSender; // true if we must pull extra fee token from trader (input side)
    Currency private _pendingCurrency; // fee token for current swap

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeForwarded(address indexed pool, uint256 amount, bool indexed isBmxPool);
    event FeeProcessorUpdated(address indexed newFeeProcessor);
    event DailyEpochGaugeUpdated(address indexed newGauge);
    event IncentiveGaugeUpdated(address indexed newGauge);

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
        // Require deployed gauges + fee processor
        if (address(dailyEpochGauge) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(incentiveGauge) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(feeProcessor) == address(0)) revert DeliErrors.ComponentNotDeployed();

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Bootstraps the DailyEpochGauge pool state.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Bootstrap DailyEpochGauge pool state
        PoolId pid = key.toId();
        dailyEpochGauge.initPool(pid, tick);

        return BaseHook.afterInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                             CALLBACK OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PoolManager before executing the swap.
    ///         If the calldata flag is present we bypass fee logic.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Skip logic for internal buy-back swaps.
        if (hookData.length >= 4 && bytes4(hookData) == InternalSwapFlag.INTERNAL_SWAP_FLAG) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Determine swap metadata
        bool exactInput = params.amountSpecified < 0;
        bool zeroForOne = params.zeroForOne;

        // Identify specified currency to compute absolute amount
        uint256 absAmountSpecified = exactInput
            ? uint256(uint128(uint256(-params.amountSpecified)))
            : uint256(uint128(uint256(params.amountSpecified)));

        // Compute fee amount based on pool fee
        uint256 feeAmount = (absAmountSpecified * uint256(key.fee)) / 1_000_000;

        // Identify whether this is BMX/wBLT pool (different logic)
        bool isBmxPool = (Currency.unwrap(key.currency0) == BMX) || (Currency.unwrap(key.currency1) == BMX);

        // Identify fee token
        Currency feeCurrency = isBmxPool
            ? (key.currency0 == Currency.wrap(BMX) ? key.currency0 : key.currency1)
            : (key.currency0 == Currency.wrap(WBLT) ? key.currency0 : key.currency1);

        // Identify input currency
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;

        // Pull the fee from the trader only when the fee token is wBLT **and** it is on the input side.
        // For the BMX pool we never pull, BMX is always borrowed via take()
        _pullFromSender = (!isBmxPool && feeCurrency == inputCurrency);

        // Persist info for _afterSwap
        _pendingFee = feeAmount;
        _pendingCurrency = feeCurrency;

        // Embed a positive specified-currency delta in the special case BMX pool, token0 -> token1
        // This offsets the negative token0 delta created later by `take()` so that the hook ends the swap with a zero balance in both currencies.
        int128 specifiedDelta = 0;
        if (isBmxPool && feeCurrency == inputCurrency && feeAmount > 0) {
            // When the trader pays the fee token (BMX) on the input side we pre-credit the same amount so the later take() leaves zero delta.
            specifiedDelta = SafeCast.toInt128(int256(feeAmount));
        }

        return (
            BaseHook.beforeSwap.selector,
            specifiedDelta == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(specifiedDelta, 0),
            0
        );
    }

    /// @notice Responsible for forwarding collected fees and epoch maintenance
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, /*balanceDelta*/
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Early exit for internal buy-back swaps (no fee, no epoch roll)
        if (hookData.length >= 4 && bytes4(hookData) == InternalSwapFlag.INTERNAL_SWAP_FLAG) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Collect the wBLT fee owed from beforeSwap
        uint256 feeOwed = _pendingFee;
        Currency feeCurrency = _pendingCurrency;

        // Reset pending fee storage
        _pendingFee = 0;
        _pendingCurrency = Currency.wrap(address(0));

        // Lazy-roll daily epoch & checkpoint pool **before** fee handling so that any deltas they create are cleared first.
        dailyEpochGauge.rollIfNeeded(key.toId());
        dailyEpochGauge.pokePool(key);
        incentiveGauge.pokePool(key);

        // Clear the deltas produced by the gauge calls so we start fee logic from a zero-balance baseline.
        _clearHookDeltas(key);

        // Identify whether this is the BMX/wBLT pool (different logic)
        bool isBmxPool = (Currency.unwrap(key.currency0) == BMX) || (Currency.unwrap(key.currency1) == BMX);

        // Forward the swap fee to FeeProcessor
        if (feeOwed > 0) {
            if (_pullFromSender) {
                // Trader pays the fee token in, move it into the PoolManager
                feeCurrency.settle(poolManager, sender, feeOwed, false);
            }

            if (isBmxPool) {
                // Move tokens to FeeProcessor so it holds the BMX
                feeCurrency.take(poolManager, address(feeProcessor), feeOwed, false);
                feeProcessor.collectFee(key, feeOwed);
            } else {
                if (params.zeroForOne) {
                    // token0 -> token1 (wBLT). Unspecified currency = token1.
                    // Borrow wBLT directly to FeeProcessor; hook books -fee delta on token1
                    feeCurrency.take(poolManager, address(feeProcessor), feeOwed, false);
                    feeProcessor.collectFee(key, feeOwed);
                } else {
                    // token1 -> token0 path: fee token (wBLT) is already held by PoolManager
                    // because we pulled it from the trader earlier in this swap.
                    // Simply move the fee amount from the PoolManager to the FeeProcessor; no borrow / settle cycle required.
                    feeCurrency.take(poolManager, address(feeProcessor), feeOwed, false);
                    feeProcessor.collectFee(key, feeOwed);
                }
            }
        }

        // Preserve whether we pulled the fee token from the trader. This is needed later for retDelta logic because _pullFromSender is reset to false before we reach that point.
        bool pulledFromSender = _pullFromSender;

        // Reconcile deltas once more *after* fee forwarding.
        // We want to zero-out the delta of the *specified* currency while leaving the delta on the *unspecified* side intact so it can be returned to PoolManager via the int128 return value.
        // Return delta to cancel negative balances introduced by take() operations in the cases where the hook borrowed the fee token from the pool (i.e. _pullFromSender == false) **and** the fee token is on the output side.
        int128 retDelta = 0;
        if (feeOwed > 0 && !pulledFromSender) {
            Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
            if (feeCurrency == outputCurrency) {
                retDelta = SafeCast.toInt128(int256(feeOwed));
            }
        }

        return (BaseHook.afterSwap.selector, retDelta);
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
}
