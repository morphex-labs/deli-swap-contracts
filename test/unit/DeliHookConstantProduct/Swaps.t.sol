// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";

contract DeliHookConstantProduct_SwapsTest is DeliHookConstantProduct_TestBase {
    function test_swap_zeroAmountIn_reverts() public {
        addLiquidityToPool1(100 ether, 100 ether);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_swap_insufficientLiquidity() public {
        addLiquidityToPool1(10 ether, 10 ether);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: int256(11 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_swap_exactOutput_insufficientInput() public {
        addLiquidityToPool1(10 ether, 10 ether);
        uint256 expectedInput = calculateExactOutputSwap(5 ether, 10 ether, 10 ether, 3000);
        address poorUser = address(0x3);
        deal(Currency.unwrap(wBLT), poorUser, expectedInput - 1);
        vm.startPrank(poorUser);
        ERC20(Currency.unwrap(wBLT)).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: int256(5 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }
    function test_swap_exactInput_zeroForOne() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountIn = 10 ether;
        uint256 expectedAmountOut = calculateExactInputSwap(amountIn, 100 ether, 200 ether, 3000);

        uint256 token1Before = token2.balanceOf(address(this));
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(key1, SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}), settings, "");
        assertEq(token2.balanceOf(address(this)) - token1Before, expectedAmountOut);

        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, 110 ether - 0.03 ether);
        assertEq(reserve1, 200 ether - expectedAmountOut);
    }

    function test_swap_exactInput_oneForZero() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountIn = 20 ether;
        uint256 expectedAmountOut = calculateExactInputSwap(amountIn, 200 ether, 100 ether, 3000);
        uint256 wBLTBefore = wBLT.balanceOf(address(this));
        swapRouter.swap(key1, SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertEq(wBLT.balanceOf(address(this)) - wBLTBefore, expectedAmountOut);
    }

    function test_swap_exactOutput_zeroForOne() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountOut = 20 ether;
        uint256 expectedAmountIn = calculateExactOutputSwap(amountOut, 100 ether, 200 ether, 3000);
        uint256 wBLTBefore = wBLT.balanceOf(address(this));
        uint256 token2Before = token2.balanceOf(address(this));

        swapRouter.swap(key1, SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        assertEq(wBLTBefore - wBLT.balanceOf(address(this)), expectedAmountIn);
        assertEq(token2.balanceOf(address(this)) - token2Before, amountOut);
    }

    function test_swap_differentFees() public {
        addLiquidityToPool1(100 ether, 100 ether);
        addLiquidityToPool2(100 ether, 100 ether);
        addLiquidityToPool3(100 ether, 100 ether);

        uint256 amountIn = 10 ether;
        uint256 expectedOut1 = calculateExactInputSwap(amountIn, 100 ether, 100 ether, 3000);
        uint256 expectedOut2 = calculateExactInputSwap(amountIn, 100 ether, 100 ether, 10000);
        uint256 expectedOut3 = calculateExactInputSwap(amountIn, 100 ether, 100 ether, 1000);
        assertTrue(expectedOut3 > expectedOut1);
        assertTrue(expectedOut1 > expectedOut2);

        uint256 token1Before = token2.balanceOf(address(this));
        swapInPool1(amountIn, true);
        uint256 actualOut1 = token2.balanceOf(address(this)) - token1Before;

        uint256 token3Before = token3.balanceOf(address(this));
        swapInPool2(amountIn, true);
        uint256 actualOut2 = token3.balanceOf(address(this)) - token3Before;

        uint256 bmxBefore = MockERC20(Currency.unwrap(bmx)).balanceOf(address(this));
        swapInPool3(amountIn, true);
        uint256 actualOut3 = MockERC20(Currency.unwrap(bmx)).balanceOf(address(this)) - bmxBefore;

        assertTrue(actualOut3 > actualOut1);
        assertTrue(actualOut1 > actualOut2);
    }

    function test_swap_largeSwap_priceImpact() public {
        addLiquidityToPool1(100 ether, 100 ether);
        (uint128 r0Init, uint128 r1Init) = hook.getReserves(id1);
        uint256 kBefore = uint256(r0Init) * uint256(r1Init);

        uint256 largeAmountIn = 50 ether;
        uint256 expectedOut = calculateExactInputSwap(largeAmountIn, r0Init, r1Init, 3000);
        swapInPool1(largeAmountIn, true);
        assertTrue(expectedOut < largeAmountIn);
        assertTrue(expectedOut > largeAmountIn * 30 / 100);

        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        uint256 kAfter = uint256(reserve0) * uint256(reserve1);
        assertTrue(kAfter >= kBefore * 999 / 1000);
        assertTrue(kAfter <= kBefore * 1001 / 1000);
    }

    function test_swap_multipleSwapsInSameBlock() public {
        addLiquidityToPool1(1000 ether, 1000 ether);
        swapInPool1(10 ether, true);
        swapInPool1(20 ether, false);
        swapInPool1(5 ether, true);

        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        uint256 k = uint256(reserve0) * uint256(reserve1);
        uint256 kInitial = 1000 ether * 1000 ether;
        uint256 tolerance = kInitial / 1000; // 0.1%
        assertApproxEqAbs(k, kInitial, tolerance, "K should remain within 0.1% of initial");
    }

    function test_swap_afterFeesAccumulated() public {
        addLiquidityToPool1(100 ether, 100 ether);
        for (uint i = 0; i < 10; i++) {
            swapInPool1(1 ether, true);
            swapInPool1(1 ether, false);
        }
        uint256 sharesBefore = hook.balanceOf(id1, address(this));
        (uint128 reserve0Before, uint128 reserve1Before) = hook.getReserves(id1);
        uint256 amount0 = 100 ether;
        uint256 amount1 = (amount0 * reserve1Before) / reserve0Before;
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1 + 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
        uint256 sharesAfter = hook.balanceOf(id1, address(this));
        uint256 newShares = sharesAfter - sharesBefore;
        assertTrue(newShares > sharesBefore);
    }
}


