// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/src/interfaces/IHookEvents.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {
    BeforeSwapDeltaLibrary, BeforeSwapDelta, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @dev Multi-pool custom curve implementation that combines BaseCustomAccounting and BaseCustomCurve logic.
 *
 * This contract follows OpenZeppelin's design pattern but supports multiple pools in a single hook instance.
 * It combines the public liquidity management functions from BaseCustomAccounting with the
 * custom curve swap logic from BaseCustomCurve.
 *
 * Key features:
 * - Supports multiple pools via PoolKey parameter
 * - Custom curve logic for swaps (override _getUnspecifiedAmount)
 * - Hook-owned liquidity with ERC-6909 tokens
 * - Follows OpenZeppelin's exact pattern but multi-pool
 */
abstract contract MultiPoolCustomCurve is BaseHook, IHookEvents, IUnlockCallback {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    /**
     * @dev A liquidity modification order was attempted to be executed after the deadline.
     */
    error ExpiredPastDeadline();

    /**
     * @dev Pool was not initialized.
     */
    error PoolNotInitialized();

    /**
     * @dev Principal delta of liquidity modification resulted in too much slippage.
     */
    error TooMuchSlippage();

    /**
     * @dev Liquidity was attempted to be added or removed via the `PoolManager` instead of the hook.
     */
    error LiquidityOnlyViaHook();

    /**
     * @dev Native currency was not sent with the correct amount.
     */
    error InvalidNativeValue();

    struct AddLiquidityParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 userInputSalt;
    }

    struct RemoveLiquidityParams {
        uint256 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 userInputSalt;
    }

    struct CallbackDataCustom {
        address sender;
        PoolKey key;
        int128 amount0;
        int128 amount1;
    }

    // Track which pools have been initialized
    mapping(PoolId => bool) public poolInitialized;

    // Track current operation context (used during unlock operations)
    PoolKey internal _currentPoolKey;
    bool internal _inCallback;

    /**
     * @dev Ensure the deadline of a liquidity modification request is not expired.
     */
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    /**
     * @dev Set the pool `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Adds liquidity to the specified pool.
     *
     * @param key The pool key identifying which pool to add liquidity to.
     * @param params The parameters for the liquidity addition.
     * @return delta The principal delta of the liquidity addition.
     */
    function addLiquidity(PoolKey calldata key, AddLiquidityParams calldata params)
        external
        payable
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Revert if msg.value is non-zero but currency0 is not native
        bool isNative = key.currency0.isAddressZero();
        if (!isNative && msg.value > 0) revert InvalidNativeValue();

        // Set current pool context
        _currentPoolKey = key;

        // Get the liquidity modification parameters and the amount of liquidity shares to mint
        (bytes memory modifyParams, uint256 shares) = _getAddLiquidity(key, sqrtPriceX96, params);

        // Apply the liquidity modification
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(key, modifyParams);

        // Mint the liquidity shares to sender
        _mint(key, params, callerDelta, feesAccrued, shares);

        // Get the principal delta by subtracting the fee delta from the caller delta
        delta = callerDelta - feesAccrued;

        // Check for slippage on principal delta
        uint128 amount0 = uint128(-delta.amount0());
        if (amount0 < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }

        // If the currency0 is native, refund any remaining msg.value
        if (isNative) {
            if (msg.value < amount0) revert InvalidNativeValue();
            key.currency0.transfer(msg.sender, msg.value - amount0);
        }
    }

    /**
     * @notice Removes liquidity from the specified pool.
     *
     * @param key The pool key identifying which pool to remove liquidity from.
     * @param params The parameters for the liquidity removal.
     * @return delta The principal delta of the liquidity removal.
     */
    function removeLiquidity(PoolKey calldata key, RemoveLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Set current pool context
        _currentPoolKey = key;

        // Get the liquidity modification parameters and the amount of liquidity shares to burn
        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(key, params);

        // Apply the liquidity modification
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(key, modifyParams);

        // Burn the liquidity shares from the sender
        _burn(key, params, callerDelta, feesAccrued, shares);

        // Get the principal delta by subtracting the fee delta from the caller delta
        delta = callerDelta - feesAccrued;

        // Check for slippage
        if (uint128(delta.amount0()) < params.amount0Min || uint128(delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /**
     * @dev Defines how the liquidity modification data is encoded and returned
     * for an add liquidity request.
     */
    function _getAddLiquidity(PoolKey memory key, uint160, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 shares) = _getAmountIn(key, params);
        return (abi.encode(amount0.toInt128(), amount1.toInt128()), shares);
    }

    /**
     * @dev Defines how the liquidity modification data is encoded and returned
     * for a remove liquidity request.
     */
    function _getRemoveLiquidity(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 shares) = _getAmountOut(key, params);
        return (abi.encode(-amount0.toInt128(), -amount1.toInt128()), shares);
    }

    /**
     * @dev Overides the custom accounting logic to support the custom curve integer amounts.
     *
     * @param key The pool key for context.
     * @param params The parameters for the liquidity modification, encoded in the
     * {_getAddLiquidity} or {_getRemoveLiquidity} function.
     * @return callerDelta The balance delta from the liquidity modification. This is the total of both principal and fee deltas.
     * @return feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    function _modifyLiquidity(PoolKey memory key, bytes memory params)
        internal
        virtual
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        (int128 amount0, int128 amount1) = abi.decode(params, (int128, int128));
        (callerDelta, feesAccrued) = abi.decode(
            poolManager.unlock(abi.encode(CallbackDataCustom(msg.sender, key, amount0, amount1))),
            (BalanceDelta, BalanceDelta)
        );
    }

    /**
     * @dev Decodes the callback data and applies the liquidity modifications, overriding the custom
     * accounting logic to mint and burn ERC-6909 claim tokens which are used in swaps.
     *
     * @param rawData The callback data encoded in the {_modifyLiquidity} function.
     * @return returnData The encoded caller and fees accrued deltas.
     */
    function unlockCallback(bytes calldata rawData)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackDataCustom memory data = abi.decode(rawData, (CallbackDataCustom));

        // Mark that we're in a callback for context
        _inCallback = true;
        _currentPoolKey = data.key;

        int128 amount0 = 0;
        int128 amount1 = 0;

        PoolKey memory key = data.key;

        // Remove liquidity if amount0 is negative
        if (data.amount0 < 0) {
            // Burns ERC-6909 tokens to receive tokens
            key.currency0.settle(poolManager, address(this), uint256(int256(-data.amount0)), true);
            // Sends tokens from the pool to the user
            key.currency0.take(poolManager, data.sender, uint256(int256(-data.amount0)), false);
            // Record the amount so that it can be then encoded into the delta
            amount0 = -data.amount0;
        }

        // Remove liquidity if amount1 is negative
        if (data.amount1 < 0) {
            // Burns ERC-6909 tokens to receive tokens
            key.currency1.settle(poolManager, address(this), uint256(int256(-data.amount1)), true);
            // Sends tokens from the pool to the user
            key.currency1.take(poolManager, data.sender, uint256(int256(-data.amount1)), false);
            // Record the amount so that it can be then encoded into the delta
            amount1 = -data.amount1;
        }

        // Add liquidity if amount0 is positive
        if (data.amount0 > 0) {
            // First settle (send) tokens from user to pool
            key.currency0.settle(poolManager, data.sender, uint256(int256(data.amount0)), false);
            // Take (mint) ERC-6909 tokens to be received by this hook
            key.currency0.take(poolManager, address(this), uint256(int256(data.amount0)), true);
            // Record the amount so that it can be then encoded into the delta
            amount0 = -data.amount0;
        }

        // Add liquidity if amount1 is positive
        if (data.amount1 > 0) {
            // First settle (send) tokens from user to pool
            key.currency1.settle(poolManager, data.sender, uint256(int256(data.amount1)), false);
            // Take (mint) ERC-6909 tokens to be received by this hook
            key.currency1.take(poolManager, address(this), uint256(int256(data.amount1)), true);
            // Record the amount so that it can be then encoded into the delta
            amount1 = -data.amount1;
        }

        emit HookModifyLiquidity(PoolId.unwrap(key.toId()), data.sender, amount0, amount1);

        // Clear callback context
        _inCallback = false;

        // Return the encoded caller and fees accrued (zero by default) deltas
        return abi.encode(toBalanceDelta(amount0, amount1), BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev Overides the default swap logic of the `PoolManager` and calls the {_getUnspecifiedAmount}
     * to get the amount of tokens to be sent to the receiver.
     *
     * NOTE: In order to take and settle tokens from the pool, the hook must hold the liquidity added
     * via the {addLiquidity} function.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Set current pool context for nested calls
        _currentPoolKey = key;

        // Determine if the swap is exact input or exact output
        bool exactInput = params.amountSpecified < 0;

        // Determine which currency is specified and which is unspecified
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // Get the positive specified amount
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Get the amount of the unspecified currency to be taken or settled
        (uint256 unspecifiedAmount) = _getUnspecifiedAmount(key, params);

        // Get the total amount of fees to be paid in the swap
        uint256 swapFeeAmount = _getSwapFeeAmount(key, params, unspecifiedAmount);

        // New delta must be returned, so store in memory
        BeforeSwapDelta returnDelta;

        if (exactInput) {
            // For exact input swaps:
            // 1. Take the specified input (user-given) amount from this contract's balance in the pool
            specified.take(poolManager, address(this), specifiedAmount, true);
            // 2. Send the calculated output amount to this contract's balance in the pool
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // For exact output swaps:
            // 1. Take the calculated input amount from this contract's balance in the pool
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            // 2. Send the specified (user-given) output amount to this contract's balance in the pool
            specified.settle(poolManager, address(this), specifiedAmount, true);

            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }

        // Emit the swap event with the amounts ordered correctly
        // NOTE: the fee is paid in the input currency
        if (specified == key.currency0) {
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                specifiedAmount.toInt128(),
                unspecifiedAmount.toInt128(),
                exactInput ? swapFeeAmount.toUint128() : 0, // if specified is currency0 and exactInput = true, the fee is paid in currency0
                exactInput ? 0 : swapFeeAmount.toUint128() // if specified is currency0 and exactInput = false, the fee is paid in currency1
            );
        } else {
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                unspecifiedAmount.toInt128(),
                specifiedAmount.toInt128(),
                exactInput ? 0 : swapFeeAmount.toUint128(),
                exactInput ? swapFeeAmount.toUint128() : 0
            );
        }

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    /**
     * @dev Initialize hook for the pool.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();

        // Mark pool as initialized
        poolInitialized[poolId] = true;

        return this.beforeInitialize.selector;
    }

    /**
     * @dev Revert when liquidity is attempted to be added via the `PoolManager`.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @dev Revert when liquidity is attempted to be removed via the `PoolManager`.
     */
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @dev Calculate the amount of the unspecified currency to be taken or settled from the swapper, depending on the swap
     * direction and the fee amount to be paid to LPs.
     *
     * @param key The pool key for context.
     * @param params The swap parameters.
     * @return unspecifiedAmount The amount of the unspecified currency to be taken or settled.
     */
    function _getUnspecifiedAmount(PoolKey memory key, SwapParams calldata params)
        internal
        virtual
        returns (uint256 unspecifiedAmount);

    /**
     * @dev Calculate the amount of fees to be paid to LPs in a swap.
     *
     * @param key The pool key for context.
     * @param params The swap parameters.
     * @param unspecifiedAmount The amount of the unspecified currency to be taken or settled.
     * @return swapFeeAmount The amount of fees to be paid to LPs in the swap (in currency0 and currency1).
     */
    function _getSwapFeeAmount(PoolKey memory key, SwapParams calldata params, uint256 unspecifiedAmount)
        internal
        virtual
        returns (uint256 swapFeeAmount);

    /**
     * @dev Calculate the amount of tokens to use and liquidity shares to mint for an add liquidity request.
     * @param key The pool key for context.
     * @return amount0 The amount of token0 to be sent by the liquidity provider.
     * @return amount1 The amount of token1 to be sent by the liquidity provider.
     * @return shares The amount of liquidity shares to be minted by the liquidity provider.
     */
    function _getAmountIn(PoolKey memory key, AddLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * @dev Calculate the amount of tokens to use and liquidity shares to burn for a remove liquidity request.
     * @param key The pool key for context.
     * @return amount0 The amount of token0 to be received by the liquidity provider.
     * @return amount1 The amount of token1 to be received by the liquidity provider.
     * @return shares The amount of liquidity shares to be burned by the liquidity provider.
     */
    function _getAmountOut(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * @dev Mint liquidity shares to the sender.
     *
     * @param key The pool key for context.
     * @param params The parameters for the liquidity addition.
     * @param callerDelta The balance delta from the liquidity addition. This is the total of both principal and fee delta.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     * @param shares The liquidity shares to mint.
     */
    function _mint(
        PoolKey memory key,
        AddLiquidityParams memory params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        uint256 shares
    ) internal virtual;

    /**
     * @dev Burn liquidity shares from the sender.
     *
     * @param key The pool key for context.
     * @param params The parameters for the liquidity removal.
     * @param callerDelta The balance delta from the liquidity removal. This is the total of both principal and fee delta.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     * @param shares The liquidity shares to burn.
     */
    function _burn(
        PoolKey memory key,
        RemoveLiquidityParams memory params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        uint256 shares
    ) internal virtual;

    /**
     * @dev Set the hook permissions, specifically `beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`,
     * `beforeSwap`, and `beforeSwapReturnDelta`
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
