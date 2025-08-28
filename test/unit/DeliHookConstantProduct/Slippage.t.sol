// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract DeliHookConstantProduct_SlippageTest is DeliHookConstantProduct_TestBase {
    function test_slippage_exactInput_zeroForOne_revertWithLimitAboveCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: sqrt0 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactInput_zeroForOne_succeedsWithMinLimit() public {
        addLiquidityToPool1(100 ether, 200 ether);
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactInput_oneForZero_revertWithLimitBelowCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: sqrt0 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactInput_oneForZero_succeedsWithMaxLimit() public {
        addLiquidityToPool1(100 ether, 200 ether);
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactOutput_zeroForOne_revertWithLimitAboveCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: int256(1 ether), sqrtPriceLimitX96: sqrt0 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactOutput_oneForZero_revertWithLimitBelowCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: int256(1 ether), sqrtPriceLimitX96: sqrt0 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_noLimit_allowsSwap() public {
        addLiquidityToPool1(100 ether, 200 ether);
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: 0}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}


