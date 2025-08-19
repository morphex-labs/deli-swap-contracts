// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";

contract DeliHookConstantProduct_LiquidityTest is DeliHookConstantProduct_TestBase {
    function test_poolInitialization() public view {
        assertTrue(hook.poolInitialized(id1));
        assertTrue(hook.poolInitialized(id2));
        assertTrue(hook.poolInitialized(id3));

        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        assertEq(r0, 0);
        assertEq(r1, 0);
        assertEq(hook.getTotalSupply(id1), 0);
    }
    function test_firstLiquidityAddition() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20 ether;
        uint256 expectedShares = sqrt(amount0 * amount1) - hook.MINIMUM_LIQUIDITY();

        vm.expectEmit(true, true, true, true);
        emit Mint(id1, address(this), amount0, amount1);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0,
            amount1Min: amount1,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        assertEq(hook.balanceOf(id1, address(this)), expectedShares);
        assertEq(hook.getTotalSupply(id1), expectedShares + hook.MINIMUM_LIQUIDITY());
        assertEq(hook.balanceOf(id1, address(0)), hook.MINIMUM_LIQUIDITY());
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, amount0);
        assertEq(reserve1, amount1);
    }

    function test_subsequentLiquidityAddition_optimalRatio() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 balanceBefore = hook.balanceOf(id1, address(this));
        uint256 totalSupplyBefore = hook.getTotalSupply(id1);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 5 ether,
            amount1Desired: 10 ether,
            amount0Min: 5 ether,
            amount1Min: 10 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 expectedNewShares = min((5 ether * totalSupplyBefore) / 10 ether, (10 ether * totalSupplyBefore) / 20 ether);
        assertEq(hook.balanceOf(id1, address(this)), balanceBefore + expectedNewShares);
        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        assertEq(r0, 15 ether);
        assertEq(r1, 30 ether);
    }

    function test_liquidityAddition_nonOptimalRatio() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 10 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        assertEq(r0, 15 ether);
        assertEq(r1, 30 ether);
    }

    function test_liquidityRemoval_partial() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 sharesBefore = hook.balanceOf(id1, address(this));
        uint256 wBLTBefore = wBLT.balanceOf(address(this));
        uint256 token2Before = token2.balanceOf(address(this));

        uint256 sharesToBurn = sharesBefore / 2;
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: sharesToBurn,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        assertEq(hook.balanceOf(id1, address(this)), sharesBefore - sharesToBurn);
        assertApproxEqAbs(wBLT.balanceOf(address(this)) - wBLTBefore, 5 ether, 1000);
        assertApproxEqAbs(token2.balanceOf(address(this)) - token2Before, 10 ether, 1000);

        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        assertEq(r0, 5000000000000000354);
        assertEq(r1, 10000000000000000708);
    }

    function test_liquidityRemoval_full() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 shares = hook.balanceOf(id1, address(this));
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: shares - 1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        assertEq(hook.balanceOf(id1, address(this)), 1);
        assertTrue(hook.getTotalSupply(id1) >= hook.MINIMUM_LIQUIDITY());

        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        assertTrue(r0 > 0 && r0 < 1000);
        assertTrue(r1 > 0 && r1 < 2000);
    }

    function test_liquidityAddition_slippageProtection() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        vm.expectRevert();
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 10 ether,
            amount1Min: 10 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function test_liquidityRemoval_slippageProtection() public {
        // Add liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 100 ether,
            amount1Desired: 100 ether,
            amount0Min: 100 ether,
            amount1Min: 100 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 shares = hook.balanceOf(id1, address(this));

        // Too high minimums should revert
        vm.expectRevert(DeliErrors.InsufficientOutput.selector);
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: shares,
            amount0Min: 101 ether,
            amount1Min: 101 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function test_liquidityAddition_multipleUsers() public {
        // User 1 adds initial liquidity
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 user1Shares = hook.balanceOf(id1, address(this));

        // User 2 adds liquidity
        address user2 = address(0x2);
        deal(Currency.unwrap(wBLT), user2, 1000 ether);
        deal(Currency.unwrap(token2), user2, 1000 ether);

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(wBLT)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token2)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 50 ether,
            amount1Desired: 100 ether,
            amount0Min: 50 ether,
            amount1Min: 100 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
        vm.stopPrank();

        uint256 user2Shares = hook.balanceOf(id1, user2);
        assertApproxEqAbs(user2Shares, user1Shares / 2, 1000);
        assertEq(hook.getTotalSupply(id1), user1Shares + user2Shares + hook.MINIMUM_LIQUIDITY());
    }

    function test_multiPool_independence() public {
        addLiquidityToPool1(100 ether, 200 ether);
        addLiquidityToPool2(300 ether, 150 ether);

        (uint128 r0_1, uint128 r1_1) = hook.getReserves(id1);
        (uint128 r0_2, uint128 r1_2) = hook.getReserves(id2);
        assertEq(r0_1, 100 ether);
        assertEq(r1_1, 200 ether);
        assertEq(r0_2, 300 ether);
        assertEq(r1_2, 150 ether);

        swapInPool1(10 ether, true);
        (r0_2, r1_2) = hook.getReserves(id2);
        assertEq(r0_2, 300 ether);
        assertEq(r1_2, 150 ether);
    }

    function test_liquidityAddition_deadline() public {
        vm.expectRevert(MultiPoolCustomCurve.ExpiredPastDeadline.selector);
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp - 1,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }
}


