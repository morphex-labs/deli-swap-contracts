// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract DeliHookConstantProduct_ViewsTest is DeliHookConstantProduct_TestBase {
    // Math-only
    function test_view_quote_math_basic() public view {
        uint256 reserveA = 100 ether;
        uint256 reserveB = 200 ether;
        uint256 amountA = 10 ether;
        uint256 expected = (amountA * reserveB) / reserveA;
        uint256 actual = hook.quote(amountA, reserveA, reserveB);
        assertEq(actual, expected, "math-only quote mismatch");
    }

    function test_view_quote_math_revertsOnZero() public {
        vm.expectRevert(); hook.quote(0, 1, 1);
        vm.expectRevert(); hook.quote(1, 0, 1);
        vm.expectRevert(); hook.quote(1, 1, 0);
    }

    function test_view_getAmountOut_math_matchesFormula() public view {
        uint256 reserveIn = 100 ether;
        uint256 reserveOut = 200 ether;
        uint24 fee = 3000;
        uint256 amountIn = 10 ether;
        uint256 viewOut = hook.getAmountOut(amountIn, reserveIn, reserveOut, fee);
        uint256 expected = calculateExactInputSwap(amountIn, reserveIn, reserveOut, fee);
        assertEq(viewOut, expected);
    }

    function test_view_getAmountOut_math_revertsOnZero() public {
        vm.expectRevert(); hook.getAmountOut(0, 1, 1, 3000);
        vm.expectRevert(); hook.getAmountOut(1, 0, 1, 3000);
        vm.expectRevert(); hook.getAmountOut(1, 1, 0, 3000);
    }

    function test_view_getAmountIn_math_matchesFormula() public view {
        uint256 reserveIn = 200 ether;
        uint256 reserveOut = 100 ether;
        uint24 fee = 3000;
        uint256 amountOut = 20 ether;
        uint256 viewIn = hook.getAmountIn(amountOut, reserveIn, reserveOut, fee);
        uint256 expected = calculateExactOutputSwap(amountOut, reserveIn, reserveOut, fee);
        assertEq(viewIn, expected);
    }

    function test_view_getAmountIn_math_revertsOnZeroAndInsufficient() public {
        vm.expectRevert(); hook.getAmountIn(0, 1, 1, 3000);
        vm.expectRevert(); hook.getAmountIn(1, 0, 1, 3000);
        vm.expectRevert(); hook.getAmountIn(1, 1, 0, 3000);
        vm.expectRevert(); hook.getAmountIn(100 ether, 200 ether, 100 ether, 3000);
    }

    // Pool-aware
    function test_view_quote_poolAware_basicBothDirs() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountIn = 10 ether;
        uint256 outA = hook.quote(key1, true, amountIn);
        uint256 outB = hook.quote(key1, false, amountIn);
        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        uint256 expectedA = (amountIn * uint256(r1)) / uint256(r0);
        uint256 expectedB = (amountIn * uint256(r0)) / uint256(r1);
        assertEq(outA, expectedA);
        assertEq(outB, expectedB);
    }

    function test_view_quote_poolAware_reverts() public {
        vm.expectRevert(); hook.quote(key1, true, 0);
        vm.expectRevert(); hook.quote(key1, true, 1);
    }

    function test_view_getAmountOut_poolAware_matchesFormula() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountIn = 5 ether;
        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        uint256 expectedA = calculateExactInputSwap(amountIn, uint256(r0), uint256(r1), 3000);
        uint256 viewA = hook.getAmountOut(key1, true, amountIn);
        assertEq(viewA, expectedA);
        uint256 expectedB = calculateExactInputSwap(amountIn, uint256(r1), uint256(r0), 3000);
        uint256 viewB = hook.getAmountOut(key1, false, amountIn);
        assertEq(viewB, expectedB);
    }

    function test_view_getAmountOut_poolAware_reverts() public {
        vm.expectRevert(); hook.getAmountOut(key1, true, 0);
        vm.expectRevert(); hook.getAmountOut(key1, true, 1);
    }

    function test_view_getAmountIn_poolAware_feeInInput_matches() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountOut = 3 ether;
        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        uint256 expected = calculateExactOutputSwap(amountOut, uint256(r0), uint256(r1), 3000);
        uint256 viewIn = hook.getAmountIn(key1, true, amountOut);
        assertEq(viewIn, expected);
    }

    function test_view_getAmountIn_poolAware_feeInOutput_matches() public {
        addLiquidityToPool3(100 ether, 100 ether);
        (uint128 r0, uint128 r1) = hook.getReserves(id3);
        uint256 amountOut = 2 ether; // wBLT
        // fee = ceil(netOut * f / (1 - f)); grossOut = netOut + fee
        uint256 fee = (amountOut * 1000 + (1_000_000 - 1000 - 1)) / (1_000_000 - 1000);
        uint256 grossOut = amountOut + fee;
        uint256 expected = calculateExactOutputSwap(grossOut, uint256(r1), uint256(r0), 0);
        uint256 viewIn = hook.getAmountIn(key3, false, amountOut);
        assertEq(viewIn, expected);
    }

    function test_view_getAmountIn_poolAware_reverts() public {
        vm.expectRevert(); hook.getAmountIn(key1, true, 0);
        vm.expectRevert(); hook.getAmountIn(key1, true, 1);
    }

    // Multi-hop
    function test_view_getAmountsOut_twoHop() public {
        addLiquidityToPool3(100 ether, 100 ether);
        addLiquidityToPool1(100 ether, 200 ether);
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = key3; route[1] = key1;
        bool[] memory dirs = new bool[](2);
        dirs[0] = false; dirs[1] = true;
        uint256 amountIn = 10 ether;
        uint256[] memory amounts = hook.getAmountsOut(amountIn, route, dirs);
        (uint128 r0a, uint128 r1a) = hook.getReserves(id3);
        uint256 out1 = calculateExactInputSwap(amountIn, uint256(r1a), uint256(r0a), 1000);
        (uint128 r0b, uint128 r1b) = hook.getReserves(id1);
        uint256 out2 = calculateExactInputSwap(out1, uint256(r0b), uint256(r1b), 3000);
        assertEq(amounts.length, 3);
        assertEq(amounts[0], amountIn);
        assertEq(amounts[1], out1);
        assertEq(amounts[2], out2);
    }

    function test_view_getAmountsOut_invalidPath() public {
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = key1;
        bool[] memory dirs = new bool[](0);
        vm.expectRevert();
        hook.getAmountsOut(1, route, dirs);
    }

    function test_view_getAmountsIn_twoHop_mixedFeeOrientation() public {
        addLiquidityToPool3(100 ether, 100 ether);
        addLiquidityToPool1(100 ether, 200 ether);
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = key3; route[1] = key1;
        bool[] memory dirs = new bool[](2);
        dirs[0] = false; dirs[1] = true;
        uint256 finalOut = 5 ether;
        uint256[] memory amounts = hook.getAmountsIn(finalOut, route, dirs);
        (uint128 r0b, uint128 r1b) = hook.getReserves(id1);
        uint256 in2 = calculateExactOutputSwap(finalOut, uint256(r0b), uint256(r1b), 3000);
        (uint128 r0a, uint128 r1a) = hook.getReserves(id3);
        uint256 fee = (in2 * 1000 + (1_000_000 - 1000 - 1)) / (1_000_000 - 1000);
        uint256 grossOut = in2 + fee;
        uint256 in1 = calculateExactOutputSwap(grossOut, uint256(r1a), uint256(r0a), 0);
        assertEq(amounts.length, 3);
        assertEq(amounts[2], finalOut);
        assertEq(amounts[1], in2);
        assertEq(amounts[0], in1);
    }

    function test_view_getAmountsIn_invalidPath() public {
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = key1; route[1] = key3;
        bool[] memory dirs = new bool[](1);
        dirs[0] = true;
        vm.expectRevert();
        hook.getAmountsIn(1, route, dirs);
    }
}


