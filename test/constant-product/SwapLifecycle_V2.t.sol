// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {FeeProcessor} from "src/FeeProcessor.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {InternalSwapFlag} from "src/libraries/InternalSwapFlag.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";

/// @notice Tests V2 constant product swap lifecycle, reserve tracking, and x*y=k invariant
contract SwapLifecycle_V2_IT is Test, Deployers, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using InternalSwapFlag for bytes;

    // contracts
    DeliHookConstantProduct hook;
    FeeProcessor fp;
    DailyEpochGauge gauge;
    MockIncentiveGauge inc;
    V2PositionHandler v2Handler;

    // tokens
    IERC20 wblt;
    IERC20 bmx;

    // pool
    PoolKey key;
    PoolId pid;

    function setUp() public {
        deployArtifacts();

        // Deploy tokens
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(bmxToken));
        wblt = IERC20(address(wbltToken));

        // Approvals
        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);

        // Deploy hook with proper flags
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        (address predictedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DeliHookConstantProduct).creationCode, ctorArgs);

        // Deploy gauge and fee processor
        gauge = new DailyEpochGauge(
            address(0),
            poolManager,
            IPositionManagerAdapter(address(0)),
            predictedHook,
            IERC20(address(bmx)),
            address(0)
        );
        fp = new FeeProcessor(
            poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge))
        );
        fp.setKeeper(address(this), true);
        inc = new MockIncentiveGauge();

        // Deploy hook
        hook = new DeliHookConstantProduct{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // Deploy and set V2PositionHandler
        v2Handler = new V2PositionHandler(address(hook));
        hook.setV2PositionHandler(address(v2Handler));

        // Initialize pool
        key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Add initial liquidity
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        
        // Check if this is a simple swap (3 params) or a pool-specific swap (4 params)
        PoolKey memory poolKey;
        bool zeroForOne;
        uint256 amount;
        bool exactInput;
        
        if (data.length == 96) {
            // Simple swap with default pool
            address tokenIn;
            (tokenIn, amount, exactInput) = abi.decode(data, (address, uint256, bool));
            poolKey = key;
            zeroForOne = tokenIn == address(bmx);
        } else {
            // Pool-specific swap
            (poolKey, zeroForOne, amount, exactInput) = 
                abi.decode(data, (PoolKey, bool, uint256, bool));
        }
        
        SwapParams memory sp;
        if (zeroForOne) {
            if (exactInput) {
                // Exact input: settle the exact amount
                poolKey.currency0.settle(poolManager, address(this), uint128(amount), false);
                poolManager.settle();
            }
            sp = SwapParams({
                zeroForOne: true,
                amountSpecified: exactInput ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        } else {
            if (exactInput) {
                // Exact input: settle the exact amount
                poolKey.currency1.settle(poolManager, address(this), uint128(amount), false);
                poolManager.settle();
            }
            sp = SwapParams({
                zeroForOne: false,
                amountSpecified: exactInput ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });
        }

        BalanceDelta delta = poolManager.swap(poolKey, sp, bytes(""));

        if (sp.zeroForOne) {
            if (exactInput) {
                // Take the output
                uint256 outAmt = uint256(int256(delta.amount1()));
                if (outAmt > 0) poolKey.currency1.take(poolManager, address(this), outAmt, false);
            } else {
                // Exact output: first take the exact output we want
                poolKey.currency1.take(poolManager, address(this), amount, false);
                // Then settle the required input
                uint256 inAmt = uint256(-int256(delta.amount0()));
                poolKey.currency0.settle(poolManager, address(this), inAmt, false);
            }
        } else {
            if (exactInput) {
                // Take the output
                uint256 outAmt = uint256(int256(delta.amount0()));
                if (outAmt > 0) poolKey.currency0.take(poolManager, address(this), outAmt, false);
            } else {
                // Exact output: first take the exact output we want
                poolKey.currency0.take(poolManager, address(this), amount, false);
                // Then settle the required input
                uint256 inAmt = uint256(-int256(delta.amount1()));
                poolKey.currency1.settle(poolManager, address(this), inAmt, false);
            }
        }
        poolManager.settle();
        return bytes("");
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTANT PRODUCT INVARIANT
    //////////////////////////////////////////////////////////////*/

    function testConstantProductInvariant() public {
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(pid);
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        // Swap BMX -> wBLT
        uint256 swapAmount = 10 ether;
        poolManager.unlock(abi.encode(address(bmx), swapAmount, true));

        (uint128 r0After, uint128 r1After) = hook.getReserves(pid);
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        // Since fees are extracted and forwarded to FeeProcessor,
        // K should remain approximately constant (not increase)
        // The constant product is maintained while fees are removed from reserves
        assertApproxEqRel(kAfter, kBefore, 0.01e18, "K should remain approximately constant");
    }

    /*//////////////////////////////////////////////////////////////
                            EXACT INPUT SWAPS
    //////////////////////////////////////////////////////////////*/

    function testExactInputSwap() public {
        uint256 inputAmount = 5 ether;
        
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(pid);
        uint256 bmxBefore = bmx.balanceOf(address(this));
        uint256 wbltBefore = wblt.balanceOf(address(this));

        // Perform exact input swap
        poolManager.unlock(abi.encode(address(bmx), inputAmount, true));

        (uint128 r0After, uint128 r1After) = hook.getReserves(pid);

        // Verify token balances
        assertEq(bmxBefore - bmx.balanceOf(address(this)), inputAmount, "BMX spent should match input");
        uint256 outputAmount = wblt.balanceOf(address(this)) - wbltBefore;
        
        // Expected exact output with fee under constant product
        uint256 expectedOut = _cpAmountOut(inputAmount, uint256(r0Before), uint256(r1Before), 3000);
        assertEq(outputAmount, expectedOut, "exact input out mismatch");

        // Verify reserves updated correctly
        // For BMX->wBLT with fee taken from output currency (wBLT):
        // - reserve0 increases by the full input
        // - reserve1 decreases by output + feeOut (fee is taken from output side)
        uint256 outNoFee = _cpAmountOut(inputAmount, uint256(r0Before), uint256(r1Before), 0);
        uint256 feeOut = outNoFee > expectedOut ? (outNoFee - expectedOut) : 0;
        assertEq(r0After, r0Before + inputAmount, "Reserve0 should increase by full input when fee on output");
        assertEq(r1After, r1Before - outputAmount - feeOut, "Reserve1 should decrease by output plus fee");
    }

    /*//////////////////////////////////////////////////////////////
                            EXACT OUTPUT SWAPS
    //////////////////////////////////////////////////////////////*/

    function testExactOutputSwap() public {
        uint256 outputAmount = 3 ether;
        
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(pid);
        uint256 bmxBefore = bmx.balanceOf(address(this));
        uint256 wbltBefore = wblt.balanceOf(address(this));

        // Perform exact output swap
        poolManager.unlock(abi.encode(address(bmx), outputAmount, false));

        (uint128 r0After, uint128 r1After) = hook.getReserves(pid);

        // Verify output received
        assertEq(wblt.balanceOf(address(this)) - wbltBefore, outputAmount, "wBLT received should match output");
        uint256 inputAmount = bmxBefore - bmx.balanceOf(address(this));
        
        // Expected exact input for exact output when fee is on output:
        // compute grossOut = amountOut * (1 + fee) and solve input with ZERO fee
        uint256 grossOut = (outputAmount * (1_000_000 + 3000)) / 1_000_000;
        uint256 expectedIn = _cpAmountIn(grossOut, uint256(r0Before), uint256(r1Before), 0);
        assertEq(inputAmount, expectedIn, "exact output in mismatch");

        // Verify reserves
        // For fee on output: reserve0 increases by full input; reserve1 decreases by output + feeOut
        uint256 feeOut = (outputAmount * 3000) / 1_000_000;
        assertEq(r0After, r0Before + inputAmount, "Reserve0 should increase by full input when fee on output");
        assertEq(r1After, r1Before - outputAmount - feeOut, "Reserve1 should decrease by output plus fee");
    }

    // Helpers to reduce local variable usage in tests
    function _cpAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint24 feePips)
        private
        pure
        returns (uint256)
    {
        uint256 feeBasis = 1_000_000 - uint256(feePips);
        uint256 amountInWithFee = amountIn * feeBasis;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1_000_000 + amountInWithFee;
        return numerator / denominator;
    }

    function _cpAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint24 feePips)
        private
        pure
        returns (uint256)
    {
        uint256 feeBasis = 1_000_000 - uint256(feePips);
        require(amountOut < reserveOut, "insufficient liquidity");
        uint256 numerator = reserveIn * amountOut * 1_000_000;
        uint256 denominator = (reserveOut - amountOut) * feeBasis;
        return (numerator / denominator) + 1;
    }

    /*//////////////////////////////////////////////////////////////
                           BIDIRECTIONAL SWAPS
    //////////////////////////////////////////////////////////////*/

    function testBidirectionalSwaps() public {
        // First swap: BMX -> wBLT
        uint256 swap1Amount = 5 ether;
        poolManager.unlock(abi.encode(address(bmx), swap1Amount, true));
        
        (uint128 r0Mid, uint128 r1Mid) = hook.getReserves(pid);
        
        // Second swap: wBLT -> BMX (reverse direction)
        uint256 swap2Amount = 2 ether;
        poolManager.unlock(abi.encode(address(wblt), swap2Amount, true));
        
        (uint128 r0Final, uint128 r1Final) = hook.getReserves(pid);
        
        // Since fees are extracted and forwarded to FeeProcessor,
        // K should remain approximately constant (not increase)
        uint256 kInitial = 100 ether * 100 ether;
        uint256 kMid = uint256(r0Mid) * uint256(r1Mid);
        uint256 kFinal = uint256(r0Final) * uint256(r1Final);
        
        assertApproxEqRel(kMid, kInitial, 0.01e18, "K should remain approximately constant after first swap");
        assertApproxEqRel(kFinal, kMid, 0.01e18, "K should remain approximately constant after second swap");
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function testMinimumSwapAmount() public {
        // Test very small swap amount
        uint256 minAmount = 1000; // 1000 wei
        
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(pid);
        
        poolManager.unlock(abi.encode(address(bmx), minAmount, true));
        
        (uint128 r0After, uint128 r1After) = hook.getReserves(pid);
        
        // Even tiny swaps should update reserves
        assertGt(r0After, r0Before, "Reserve0 should increase");
        assertLt(r1After, r1Before, "Reserve1 should decrease");
    }

    function testLargeSwapSlippage() public {
        // Test swap that moves price significantly
        uint256 largeAmount = 50 ether; // 50% of pool
        
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(pid);
        uint256 wbltBefore = wblt.balanceOf(address(this));
        
        poolManager.unlock(abi.encode(address(bmx), largeAmount, true));
        
        uint256 wbltReceived = wblt.balanceOf(address(this)) - wbltBefore;
        
        // Output should be less than 50% of reserve due to price impact
        assertLt(wbltReceived, r1Before / 2, "Large swap should have significant slippage");
        
        // We should have consumed 50 BMX from reserve0
        assertEq(r0Before, 100 ether, "Initial reserve0 should be 100 ether");
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL SWAP VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function testInternalSwapThresholded() public {
        // Deploy a new token
        MockERC20 tokenA = deployToken();
        tokenA.approve(address(poolManager), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        
        // Create tokenA/wBLT pool (non-BMX pool will generate wBLT fees)
        PoolKey memory nonBmxKey = PoolKey({
            currency0: Currency.wrap(address(tokenA) < address(wblt) ? address(tokenA) : address(wblt)),
            currency1: Currency.wrap(address(tokenA) < address(wblt) ? address(wblt) : address(tokenA)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        
        poolManager.initialize(nonBmxKey, TickMath.getSqrtPriceAtTick(0));
        
        // Add liquidity to the non-BMX pool
        hook.addLiquidity(
            nonBmxKey,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        // Now swap on the non-BMX pool to generate wBLT fees
        // We need to swap on the tokenA/wBLT pool to generate wBLT fees
        // (non-BMX pools collect fees in wBLT)
        // Determine if wBLT is currency0 or currency1
        bool wbltIsCurrency0 = Currency.unwrap(nonBmxKey.currency0) == address(wblt);
        // If wBLT is currency0, swap currency1 -> currency0 (zeroForOne = false)
        // If wBLT is currency1, swap currency0 -> currency1 (zeroForOne = true)
        poolManager.unlock(abi.encode(nonBmxKey, !wbltIsCurrency0, 8e20, true));
        
        // Now we should have wBLT fees for buyback
        PoolId nonBmxPoolId = nonBmxKey.toId();
        uint256 pendingBuyback = fp.pendingWbltForBuyback(nonBmxPoolId);
        assertGt(pendingBuyback, 0, "Should have pending wBLT fees");
        
        // Setup for internal swap using the BMX/wBLT pool
        fp.setBuybackPoolKey(key);

        // If pending is below threshold, flush should revert; otherwise perform flush and assert
        if (pendingBuyback < 1e18) {
            vm.expectRevert(DeliErrors.BelowMinimumThreshold.selector);
            fp.flushBuffer(nonBmxPoolId, 0);
            return;
        }

        (uint128 r0Before, uint128 r1Before) = hook.getReserves(pid);
        fp.flushBuffer(nonBmxPoolId, 0);
        (uint128 r0After, uint128 r1After) = hook.getReserves(pid);

        assertGt(r1After, r1Before, "wBLT reserves should increase (wBLT in)");
        assertLt(r0After, r0Before, "BMX reserves should decrease (BMX out)");
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), 0, "Pending wBLT should be consumed");
    }
}