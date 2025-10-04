// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MultiPoolCustomCurve} from "./base/MultiPoolCustomCurve.sol";

import {IIncentiveGauge} from "./interfaces/IIncentiveGauge.sol";
import {IFeeProcessor} from "./interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "./interfaces/IDailyEpochGauge.sol";
import {IV2PositionHandler} from "./interfaces/IV2PositionHandler.sol";

import {Math} from "./libraries/Math.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";
import {InternalSwapFlag} from "./libraries/InternalSwapFlag.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @title DeliHookConstantProduct
 * @notice Uniswap V4 hook implementing x*y=k AMM with fee forwarding and gauge updates
 * @dev Extends MultiPoolCustomCurve to override V4's concentrated liquidity
 */
contract DeliHookConstantProduct is Ownable2Step, MultiPoolCustomCurve {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyDelta for Currency;
    using InternalSwapFlag for bytes;

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    struct V2Pool {
        uint128 reserve0;
        uint128 reserve1;
        uint256 totalSupply;
    }

    // Pool states indexed by PoolId
    mapping(PoolId => V2Pool) public pools;

    // Liquidity shares per user per pool
    mapping(PoolId => mapping(address => uint256)) public liquidityShares;

    // Minimum liquidity locked forever in first mint
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    // Fee and gauge contracts
    address public immutable WBLT;
    address public immutable BMX;

    IFeeProcessor public feeProcessor;
    IDailyEpochGauge public dailyEpochGauge;
    IIncentiveGauge public incentiveGauge;
    IV2PositionHandler public v2PositionHandler;

    // Temporary swap info cached between beforeSwap and afterSwap
    uint256 private _pendingFeeAmount;
    Currency private _pendingFeeCurrency;
    bool private _isInternalSwap;
    bool private _feeFromOutput;
    int256 private _swapAmountSpecified;
    bool private _swapZeroForOne;

    /*//////////////////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event PairCreated(PoolId indexed poolId, Currency indexed currency0, Currency indexed currency1, uint24 fee);
    event Sync(PoolId indexed poolId, uint128 reserve0, uint128 reserve1);
    event Mint(PoolId indexed poolId, address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(PoolId indexed poolId, address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event FeeProcessorUpdated(address indexed newFeeProcessor);
    event DailyEpochGaugeUpdated(address indexed newGauge);
    event IncentiveGaugeUpdated(address indexed newGauge);
    event V2PositionHandlerUpdated(address indexed newHandler);

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager _poolManager,
        IFeeProcessor _feeProcessor,
        IDailyEpochGauge _dailyEpochGauge,
        IIncentiveGauge _incentiveGauge,
        address _wblt,
        address _bmx,
        address _owner
    ) Ownable(_owner) MultiPoolCustomCurve(_poolManager) {
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

    /// @notice Set the address of the V2PositionHandler contract.
    /// @param _handler The address of the V2PositionHandler contract.
    function setV2PositionHandler(address _handler) external onlyOwner {
        if (_handler == address(0)) revert DeliErrors.ZeroAddress();
        v2PositionHandler = IV2PositionHandler(_handler);
        emit V2PositionHandlerUpdated(_handler);
    }

    /*//////////////////////////////////////////////////////////////
                            HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        return p;
    }

    /*//////////////////////////////////////////////////////////////
                           POOL INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Verifies the pool is valid before initialization.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
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

        // V2 pools must use tick spacing 1 to avoid tick alignment issues
        if (key.tickSpacing != 1) revert DeliErrors.InvalidTickSpacing();
        // Enforce fixed sqrtPrice at tick 0 (2^96) for V2 pools for consistency
        if (sqrtPriceX96 != (uint160(1) << 96)) revert DeliErrors.InvalidSqrtPrice();
        // Enforce minimum fee of 0.1% (1000 in hundredths of basis points)
        if (key.fee < 1000) revert DeliErrors.InvalidFee();

        // Require all components to be deployed before pool creation
        if (address(dailyEpochGauge) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(incentiveGauge) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(feeProcessor) == address(0)) revert DeliErrors.ComponentNotDeployed();
        if (address(v2PositionHandler) == address(0)) revert DeliErrors.ComponentNotDeployed();

        emit PairCreated(key.toId(), key.currency0, key.currency1, key.fee);

        // Let the base class handle pool initialization tracking
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @dev Bootstraps the DailyEpochGauge and IncentiveGauge pool state.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        // Bootstrap DailyEpochGauge pool state
        // V2 pools always use tick 0 for gauge tracking
        dailyEpochGauge.initPool(key, 0);
        incentiveGauge.initPool(key, 0);

        return this.afterInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP CALLBACK LOGIC
    //////////////////////////////////////////////////////////////*/

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Check if this is an internal swap (from FeeProcessor)
        // Must verify both the flag AND that sender is actually FeeProcessor to prevent impersonation
        _isInternalSwap = hookData.length >= 4 && bytes4(hookData) == InternalSwapFlag.INTERNAL_SWAP_FLAG
            && sender == address(feeProcessor);

        // Calculate the implicit fee amount for V2 swaps
        _calculateImplicitFee(key, params);

        // Store parameters for afterSwap calculation
        _swapAmountSpecified = params.amountSpecified;
        _swapZeroForOne = params.zeroForOne;

        // Let MultiPoolCustomCurve handle the swap entirely
        return super._beforeSwap(sender, key, params, hookData);
    }

    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, // swapDelta
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Get pool
        PoolId poolId = key.toId();
        V2Pool storage pool = pools[poolId];

        // Calculate and update reserves
        _updateReservesAfterSwap(poolId, pool, key);

        // Enforce slippage against final virtual V2 price using updated reserves
        if (params.sqrtPriceLimitX96 != 0) {
            _enforceVirtualPriceLimit(key, params);
        }

        // Checkpoint pool
        dailyEpochGauge.pokePool(key);
        incentiveGauge.pokePool(key);

        // Forward the fee to FeeProcessor
        if (_pendingFeeAmount > 0) {
            _transferFeeTokens(_pendingFeeCurrency, _pendingFeeAmount);
            feeProcessor.collectFee(key, _pendingFeeAmount, _isInternalSwap);
        }

        // Reset pending fee storage and swap parameters
        _pendingFeeAmount = 0;
        _pendingFeeCurrency = Currency.wrap(address(0));
        _feeFromOutput = false;
        _swapAmountSpecified = 0;
        _swapZeroForOne = false;
        _isInternalSwap = false;

        return (this.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CONSTANT PRODUCT IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _getUnspecifiedAmount(PoolKey memory key, SwapParams calldata params)
        internal
        view
        override
        returns (uint256)
    {
        PoolId poolId = key.toId();
        if (!poolInitialized[poolId]) revert DeliErrors.PoolNotInitialized();
        V2Pool storage pool = pools[poolId];

        bool zeroForOne = params.zeroForOne;
        uint128 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint128 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        if (reserveIn == 0 || reserveOut == 0) revert DeliErrors.NoLiquidity();

        uint256 amountSpecified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Determine whether the fee is taken from the output currency
        (bool feeFromOutput,) = _isFeeFromOutput(key, zeroForOne);

        if (params.amountSpecified < 0) {
            // exact input
            // Always use fee-inclusive output
            return _getAmountOut(zeroForOne, amountSpecified, pool.reserve0, pool.reserve1, key.fee);
        } else {
            // exact output
            // Calculate input for exact output
            if (feeFromOutput) {
                // Compute gross output using 1/(1 - f) with rounding up, then compute input at zero LP fee
                uint256 grossOut = FullMath.mulDivRoundingUp(amountSpecified, 1_000_000, 1_000_000 - uint256(key.fee));
                return _getAmountIn(zeroForOne, grossOut, pool.reserve0, pool.reserve1, 0);
            } else {
                // Standard V2 exact-output calc with fee in input
                return _getAmountIn(zeroForOne, amountSpecified, pool.reserve0, pool.reserve1, key.fee);
            }
        }
    }

    function _getSwapFeeAmount(PoolKey memory, SwapParams calldata, uint256) internal pure override returns (uint256) {
        // Fee is already included in the constant product calculation
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function _getAmountIn(PoolKey memory key, AddLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId poolId = key.toId();
        if (!poolInitialized[poolId]) revert DeliErrors.PoolNotInitialized();
        V2Pool storage pool = pools[poolId];

        // V2 positions are always full-range, ignore user-provided ticks
        if (params.tickLower != 0 || params.tickUpper != 0) revert DeliErrors.InvalidPositionParams();

        uint256 _totalSupply = pool.totalSupply;

        if (_totalSupply == 0) {
            // First mint
            shares = Math.sqrt(params.amount0Desired * params.amount1Desired) - MINIMUM_LIQUIDITY;
            amount0 = params.amount0Desired;
            amount1 = params.amount1Desired;

            if (shares == 0) revert DeliErrors.InsufficientLiquidity();
        } else {
            // Calculate optimal amounts
            uint256 amount1Optimal = (params.amount0Desired * pool.reserve1) / pool.reserve0;

            if (amount1Optimal <= params.amount1Desired) {
                if (amount1Optimal < params.amount1Min) revert DeliErrors.Slippage();
                amount0 = params.amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = (params.amount1Desired * pool.reserve0) / pool.reserve1;
                if (amount0Optimal > params.amount0Desired || amount0Optimal < params.amount0Min) {
                    revert DeliErrors.Slippage();
                }
                amount0 = amount0Optimal;
                amount1 = params.amount1Desired;
            }

            // Calculate shares
            shares = Math.min((amount0 * _totalSupply) / pool.reserve0, (amount1 * _totalSupply) / pool.reserve1);

            if (shares == 0) revert DeliErrors.InsufficientLiquidity();
        }
    }

    function _getAmountOut(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId poolId = key.toId();
        if (!poolInitialized[poolId]) revert DeliErrors.PoolNotInitialized();
        V2Pool storage pool = pools[poolId];

        // V2 positions are always full-range, ignore user-provided ticks
        if (params.tickLower != 0 || params.tickUpper != 0) revert DeliErrors.InvalidPositionParams();

        shares = params.liquidity;

        // Use stored reserves for pro-rata distribution (now isolated per pool)
        amount0 = (shares * pool.reserve0) / pool.totalSupply;
        amount1 = (shares * pool.reserve1) / pool.totalSupply;

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert DeliErrors.InsufficientOutput();
    }

    function _mint(
        PoolKey memory key,
        AddLiquidityParams memory, // params
        BalanceDelta callerDelta,
        BalanceDelta,
        uint256 shares
    ) internal override {
        PoolId poolId = key.toId();
        V2Pool storage pool = pools[poolId];

        // Calculate actual amounts from caller delta (negative means user provided tokens)
        uint256 amount0 = uint256(uint128(-callerDelta.amount0()));
        uint256 amount1 = uint256(uint128(-callerDelta.amount1()));

        // Update total supply
        if (pool.totalSupply == 0) {
            // First mint - lock minimum liquidity
            pool.totalSupply = shares + MINIMUM_LIQUIDITY;
            liquidityShares[poolId][address(0)] = MINIMUM_LIQUIDITY;

            // For first mint, use actual amounts to set initial reserves
            _update(poolId, amount0, amount1);
        } else {
            pool.totalSupply += shares;

            // For subsequent mints, add the actual amounts to reserves
            _update(poolId, pool.reserve0 + amount0, pool.reserve1 + amount1);
        }

        // Update user's shares
        liquidityShares[poolId][msg.sender] += shares;

        // Notify V2 position handler
        v2PositionHandler.notifyAddLiquidity(key, msg.sender, shares.toUint128());

        emit Mint(poolId, msg.sender, amount0, amount1);
    }

    function _burn(
        PoolKey memory key,
        RemoveLiquidityParams memory,
        BalanceDelta callerDelta,
        BalanceDelta,
        uint256 shares
    ) internal override {
        PoolId poolId = key.toId();
        V2Pool storage pool = pools[poolId];

        // Calculate actual amounts from caller delta (positive means user receives tokens)
        uint256 amount0 = uint256(uint128(callerDelta.amount0()));
        uint256 amount1 = uint256(uint128(callerDelta.amount1()));

        // Update total supply
        pool.totalSupply -= shares;

        // Update user's shares
        liquidityShares[poolId][msg.sender] -= shares;

        // Notify V2 position handler
        v2PositionHandler.notifyRemoveLiquidity(key, msg.sender, shares.toUint128());

        // Update reserves by subtracting removed amounts
        _update(poolId, pool.reserve0 - amount0, pool.reserve1 - amount1);

        emit Burn(poolId, msg.sender, amount0, amount1, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper to determine if the fee is taken from the output currency
    function _isFeeFromOutput(PoolKey memory key, bool zeroForOne)
        private
        view
        returns (bool feeFromOutput, Currency feeCurrency)
    {
        // Always use wBLT as fee currency
        Currency _feeCurrency = (key.currency0 == Currency.wrap(WBLT)) ? key.currency0 : key.currency1;
        Currency _outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        return (_feeCurrency == _outputCurrency, _feeCurrency);
    }

    /// @dev Helper to enforce sqrtPriceLimitX96 slippage against virtual V2 price after applying swap and fee removal.
    ///      In contrast to Uniswap v4 and like v2, swaps will revert if price reaches the limit.
    function _enforceVirtualPriceLimit(PoolKey calldata key, SwapParams calldata params) private view {
        V2Pool storage pool = pools[key.toId()];
        uint256 priceAfterX128 = FullMath.mulDiv(uint256(pool.reserve1), uint256(1) << 128, uint256(pool.reserve0));
        uint256 sqrtAfterX64 = Math.sqrt(priceAfterX128);
        uint160 sqrtAfterX96 = uint160(sqrtAfterX64 << 32);
        uint160 limit = params.sqrtPriceLimitX96;

        if (params.zeroForOne) {
            if (sqrtAfterX96 < limit) revert DeliErrors.Slippage();
        } else {
            if (sqrtAfterX96 > limit) revert DeliErrors.Slippage();
        }
    }

    /// @dev Update the reserves of a pool
    function _update(PoolId poolId, uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint128).max || balance1 > type(uint128).max) revert DeliErrors.BalanceOverflow();
        V2Pool storage pool = pools[poolId];
        pool.reserve0 = uint128(balance0);
        pool.reserve1 = uint128(balance1);
        emit Sync(poolId, pool.reserve0, pool.reserve1);
    }

    /// @dev Calculate output amount for a given input using V2 math
    function _getAmountOut(bool zeroForOne, uint256 amountIn, uint256 reserve0, uint256 reserve1, uint24 fee)
        private
        pure
        returns (uint256 amountOut)
    {
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

        uint256 feeBasis = 1000000 - uint256(fee);
        if (feeBasis == 0) return 0;

        uint256 amountInWithFee = amountIn * feeBasis;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000000 + amountInWithFee;
        return numerator / denominator;
    }

    /// @dev Calculate input amount for a given output using V2 math
    function _getAmountIn(bool zeroForOne, uint256 amountOut, uint256 reserve0, uint256 reserve1, uint24 fee)
        private
        pure
        returns (uint256 amountIn)
    {
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

        if (amountOut >= reserveOut) revert DeliErrors.InsufficientLiquidity();

        uint256 feeBasis = 1000000 - uint256(fee);
        if (feeBasis == 0) revert DeliErrors.InvalidFee();

        uint256 numerator = reserveIn * amountOut * 1000000;
        uint256 denominator = (reserveOut - amountOut) * feeBasis;
        return (numerator / denominator) + 1; // Round up
    }

    /// @dev Update reserves after a swap
    function _updateReservesAfterSwap(PoolId poolId, V2Pool storage pool, PoolKey memory key) private {
        // Calculate swap amounts based on stored parameters
        bool exactInput = _swapAmountSpecified < 0;
        uint256 specifiedAmount = exactInput ? uint256(-_swapAmountSpecified) : uint256(_swapAmountSpecified);

        int256 delta0;
        int256 delta1;
        uint24 effectiveFee = key.fee;

        if (exactInput) {
            // For exact input swaps, always compute fee-inclusive output
            uint256 amountOut =
                _getAmountOut(_swapZeroForOne, specifiedAmount, pool.reserve0, pool.reserve1, effectiveFee);

            if (_swapZeroForOne) {
                delta0 = int256(specifiedAmount);
                delta1 = -int256(amountOut);
            } else {
                delta0 = -int256(amountOut);
                delta1 = int256(specifiedAmount);
            }
        } else {
            // For exact output swaps
            uint256 amountIn;
            if (_feeFromOutput) {
                // Compute input against gross output with zero LP fee (preserve K), where grossOut = ceil(netOut / (1 - f))
                uint256 grossOut =
                    FullMath.mulDivRoundingUp(specifiedAmount, 1_000_000, 1_000_000 - uint256(effectiveFee));
                amountIn = _getAmountIn(_swapZeroForOne, grossOut, pool.reserve0, pool.reserve1, 0);
            } else {
                // Standard exact-output with LP fee in input
                amountIn = _getAmountIn(_swapZeroForOne, specifiedAmount, pool.reserve0, pool.reserve1, effectiveFee);
            }

            if (_swapZeroForOne) {
                delta0 = int256(amountIn);
                delta1 = -int256(specifiedAmount);
            } else {
                delta0 = -int256(specifiedAmount);
                delta1 = int256(amountIn);
            }
        }

        // Adjust for fee removal, fees are extracted and sent to FeeProcessor
        if (_pendingFeeAmount > 0) {
            // Always deduct fee from reserves when forwarding to FeeProcessor
            // This is necessary because the hook receives the tokens that will be forwarded as fees
            if (_pendingFeeCurrency == key.currency0) {
                delta0 -= int256(_pendingFeeAmount);
            } else {
                delta1 -= int256(_pendingFeeAmount);
            }
        }

        // Update reserves
        _update(
            poolId, uint256(int256(uint256(pool.reserve0)) + delta0), uint256(int256(uint256(pool.reserve1)) + delta1)
        );
    }

    /// @dev Helper to calculate output-based fee for exact input swaps
    function _calculateOutputFee(bool zeroForOne, uint256 amountIn, uint128 reserve0, uint128 reserve1, uint24 fee)
        private
        pure
        returns (uint256)
    {
        // Calculate actual output with fee
        uint256 outputWithFee = _getAmountOut(zeroForOne, amountIn, reserve0, reserve1, fee);
        // Calculate theoretical output without fee
        uint256 outputWithoutFee = _getAmountOut(zeroForOne, amountIn, reserve0, reserve1, 0);
        // Fee is the difference
        return outputWithoutFee > outputWithFee ? outputWithoutFee - outputWithFee : 0;
    }

    /// @dev Calculate the implicit fee from a V2 swap
    function _calculateImplicitFee(PoolKey calldata key, SwapParams calldata params) private {
        PoolId poolId = key.toId();
        V2Pool storage pool = pools[poolId];

        bool exactInput = params.amountSpecified < 0;
        bool zeroForOne = params.zeroForOne;

        // Set flag for whether fee is taken from output and identify fee currency
        (_feeFromOutput, _pendingFeeCurrency) = _isFeeFromOutput(key, zeroForOne);

        uint256 amountSpecified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        uint256 feeAmount;
        if (exactInput) {
            if (_feeFromOutput) {
                // EXACT INPUT + FEE FROM OUTPUT (e.g., swap 1 WETH for WBLT, fee in WBLT)
                // Fee is the reduction in output amount due to V2's implicit fee
                // User provides exact input, receives less output (fee already deducted)
                feeAmount = _calculateOutputFee(zeroForOne, amountSpecified, pool.reserve0, pool.reserve1, key.fee);
            } else {
                // EXACT INPUT + FEE FROM INPUT (e.g., swap 100 WBLT for WETH, fee in WBLT)
                // Fee is a percentage of the input amount
                // User provides exact input including fee, receives calculated output
                feeAmount = (amountSpecified * uint256(key.fee)) / 1_000_000;
            }
        } else {
            if (_feeFromOutput) {
                // EXACT OUTPUT + FEE FROM OUTPUT: compute grossOut via 1/(1 - f), fee = grossOut - netOut
                uint256 grossOut = FullMath.mulDivRoundingUp(amountSpecified, 1_000_000, 1_000_000 - uint256(key.fee));
                feeAmount = grossOut - amountSpecified;
            } else {
                // EXACT OUTPUT + FEE FROM INPUT (e.g., get exactly 1 WETH, fee in WBLT)
                // Fee is the extra input required beyond theoretical amount
                uint256 inputWithFee = _getAmountIn(zeroForOne, amountSpecified, pool.reserve0, pool.reserve1, key.fee);
                uint256 inputWithoutFee = _getAmountIn(zeroForOne, amountSpecified, pool.reserve0, pool.reserve1, 0);
                feeAmount = inputWithFee > inputWithoutFee ? inputWithFee - inputWithoutFee : 0;
            }
        }

        _pendingFeeAmount = feeAmount;
    }

    /// @dev Helper to transfer fee tokens from hook to FeeProcessor
    function _transferFeeTokens(Currency feeCurrency, uint256 feeAmount) private {
        // Since the fee is already part of the V2 swap reserves, we need to:
        // 1. Burn the fee amount of ERC-6909 tokens from hook's balance
        // 2. Take the actual tokens (not claims) and send to FeeProcessor

        // First burn ERC-6909 tokens from hook's balance
        poolManager.burn(address(this), CurrencyLibrary.toId(feeCurrency), feeAmount);

        // Then take the actual tokens and send to FeeProcessor
        feeCurrency.take(poolManager, address(feeProcessor), feeAmount, false);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the reserves of a pool
    /// @param poolId The pool ID to query
    /// @return reserve0 The reserve of the first currency
    /// @return reserve1 The reserve of the second currency
    function getReserves(PoolId poolId) external view returns (uint128, uint128) {
        V2Pool storage pool = pools[poolId];
        return (pool.reserve0, pool.reserve1);
    }

    /// @notice Get the total supply of a pool
    /// @param poolId The pool ID to query
    /// @return totalSupply The total supply of the pool
    function getTotalSupply(PoolId poolId) external view returns (uint256) {
        return pools[poolId].totalSupply;
    }

    /// @notice Get the balance of a user in a pool
    /// @param poolId The pool ID to query
    /// @param account The address of the user to query
    /// @return balance The balance of the user in the pool
    function balanceOf(PoolId poolId, address account) external view returns (uint256) {
        return liquidityShares[poolId][account];
    }

    /// @notice External getSlot0-style view for constant-product pools.
    /// @dev    Returns virtual sqrtPriceX96 derived from reserves; protocolFee and tick are always 0 for V2 pools;
    ///         lpFee is the per-pool LP fee.
    /// @param poolId The pool ID to query
    /// @return sqrtPriceX96 The virtual sqrtPriceX96
    /// @return tick The tick
    /// @return protocolFee The protocol fee
    /// @return lpFee The per-pool LP fee
    function getSlot0(IPoolManager, /*manager*/ PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        V2Pool storage pool = pools[poolId];
        // Fetch fees and tick=0 from core PoolManager; we expose virtual price only
        (, tick, protocolFee, lpFee) = StateLibrary.getSlot0(poolManager, poolId);

        if (pool.reserve0 == 0 || pool.reserve1 == 0) {
            // Uninitialized/empty: return zeros
            return (0, tick, protocolFee, lpFee);
        }

        // Compute price in Q128 then scale sqrt to Q96 to prevent overflow
        uint256 priceX128 = FullMath.mulDiv(uint256(pool.reserve1), uint256(1) << 128, uint256(pool.reserve0));
        uint256 sqrtX64 = Math.sqrt(priceX128);
        sqrtPriceX96 = uint160(sqrtX64 << 32);
    }

    /// @notice Given some amount of an asset and pair reserves, returns an equivalent amount of the other asset (no fee)
    /// @param amountA The amount of the first asset
    /// @param reserveA The reserve of the first asset
    /// @param reserveB The reserve of the second asset
    /// @return amountB The amount of the second asset
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB) {
        if (amountA == 0) revert DeliErrors.ZeroAmount();
        if (reserveA == 0 || reserveB == 0) revert DeliErrors.InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Ratio-only quote using live pool reserves (no fee)
    /// @param key The pool key
    /// @param zeroForOne Whether the input amount is in the zero or one currency
    /// @param amountIn The input amount
    /// @return amountOut The output amount
    function quote(PoolKey memory key, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        if (amountIn == 0) revert DeliErrors.ZeroAmount();
        V2Pool storage pool = pools[key.toId()];
        if (pool.reserve0 == 0 || pool.reserve1 == 0) revert DeliErrors.NoLiquidity();
        uint256 rIn = zeroForOne ? uint256(pool.reserve0) : uint256(pool.reserve1);
        uint256 rOut = zeroForOne ? uint256(pool.reserve1) : uint256(pool.reserve0);
        amountOut = (amountIn * rOut) / rIn;
    }

    /// @notice Math-only: maximum output amount for exact input at given reserves and fee
    /// @param amountIn The input amount
    /// @param reserveIn The input reserve
    /// @param reserveOut The output reserve
    /// @param feePips The fee in hundredths of a basis point
    /// @return amountOut The output amount
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint24 feePips)
        external
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert DeliErrors.ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert DeliErrors.InsufficientLiquidity();
        // Delegate to internal constant-product helper by orienting reserves
        amountOut = _getAmountOut(true, amountIn, reserveIn, reserveOut, feePips);
    }

    /// @notice Maximum output amount for exact input using live pool state
    /// @param key The pool key
    /// @param zeroForOne Whether the input amount is in the zero or one currency
    /// @param amountIn The input amount
    /// @return amountOut The output amount
    function getAmountOut(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert DeliErrors.ZeroAmount();
        V2Pool storage pool = pools[key.toId()];
        if (pool.reserve0 == 0 || pool.reserve1 == 0) revert DeliErrors.NoLiquidity();
        amountOut = _getAmountOut(zeroForOne, amountIn, pool.reserve0, pool.reserve1, key.fee);
    }

    /// @notice Math-only: required input amount for exact output at given reserves and fee (fee in input)
    /// @param amountOut The output amount
    /// @param reserveIn The input reserve
    /// @param reserveOut The output reserve
    /// @param feePips The fee in hundredths of a basis point
    /// @return amountIn The input amount
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint24 feePips)
        external
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert DeliErrors.ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert DeliErrors.InsufficientLiquidity();
        amountIn = _getAmountIn(true, amountOut, reserveIn, reserveOut, feePips);
    }

    /// @notice Required input amount for exact output using live pool state
    /// @param key The pool key
    /// @param zeroForOne Whether the output amount is in the zero or one currency
    /// @param amountOut The output amount
    /// @return amountIn The input amount
    function getAmountIn(PoolKey memory key, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert DeliErrors.ZeroAmount();
        V2Pool storage pool = pools[key.toId()];
        if (pool.reserve0 == 0 || pool.reserve1 == 0) revert DeliErrors.NoLiquidity();

        (bool feeFromOutput,) = _isFeeFromOutput(key, zeroForOne);
        if (feeFromOutput) {
            // Use grossOut = ceil(netOut / (1 - f)) to compute input at zero fee
            uint256 grossOut = FullMath.mulDivRoundingUp(amountOut, 1_000_000, 1_000_000 - uint256(key.fee));
            uint256 rOut = zeroForOne ? uint256(pool.reserve1) : uint256(pool.reserve0);
            if (grossOut >= rOut) revert DeliErrors.InsufficientLiquidity();
            amountIn = _getAmountIn(zeroForOne, grossOut, pool.reserve0, pool.reserve1, 0);
        } else {
            amountIn = _getAmountIn(zeroForOne, amountOut, pool.reserve0, pool.reserve1, key.fee);
        }
    }

    /// @notice Multi-hop exact-input quote over a route of pools
    /// @param amountIn The input amount
    /// @param route The route of pools
    /// @param zeroForOnes Whether the input amount is in the zero or one currency for each pool
    /// @return amounts The amounts of each pool in the route
    function getAmountsOut(uint256 amountIn, PoolKey[] calldata route, bool[] calldata zeroForOnes)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 n = route.length;
        if (n == 0 || n != zeroForOnes.length) revert DeliErrors.NotAllowed();
        amounts = new uint256[](n + 1);
        amounts[0] = amountIn;
        for (uint256 i; i < n; ++i) {
            V2Pool storage pool = pools[route[i].toId()];
            if (pool.reserve0 == 0 || pool.reserve1 == 0) revert DeliErrors.NoLiquidity();
            amounts[i + 1] = _getAmountOut(zeroForOnes[i], amounts[i], pool.reserve0, pool.reserve1, route[i].fee);
        }
    }

    /// @notice Multi-hop exact-output quote over a route of pools
    /// @param amountOut The output amount
    /// @param route The route of pools
    /// @param zeroForOnes Whether the output amount is in the zero or one currency for each pool
    /// @return amounts The amounts of each pool in the route
    function getAmountsIn(uint256 amountOut, PoolKey[] calldata route, bool[] calldata zeroForOnes)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 n = route.length;
        if (n == 0 || n != zeroForOnes.length) revert DeliErrors.NotAllowed();
        amounts = new uint256[](n + 1);
        amounts[n] = amountOut;
        for (uint256 i = n; i > 0;) {
            unchecked {
                --i;
            }
            V2Pool storage pool = pools[route[i].toId()];
            if (pool.reserve0 == 0 || pool.reserve1 == 0) revert DeliErrors.NoLiquidity();

            (bool feeFromOutput,) = _isFeeFromOutput(route[i], zeroForOnes[i]);
            if (feeFromOutput) {
                uint256 grossOut =
                    FullMath.mulDivRoundingUp(amounts[i + 1], 1_000_000, 1_000_000 - uint256(route[i].fee));
                uint256 rOut = zeroForOnes[i] ? uint256(pool.reserve1) : uint256(pool.reserve0);
                if (grossOut >= rOut) revert DeliErrors.InsufficientLiquidity();
                amounts[i] = _getAmountIn(zeroForOnes[i], grossOut, pool.reserve0, pool.reserve1, 0);
            } else {
                amounts[i] = _getAmountIn(zeroForOnes[i], amounts[i + 1], pool.reserve0, pool.reserve1, route[i].fee);
            }
        }
    }
}
