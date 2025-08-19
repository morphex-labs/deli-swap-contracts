// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract DeliHookConstantProduct_InternalSwapFlagTest is DeliHookConstantProduct_TestBase {
    function test_internalSwapOnlyFeeProcessor() public {
        addLiquidityToPool3(100 ether, 100 ether);
        bytes memory hookData = abi.encode(bytes4(0xDE1ABEEF));
        uint256 regularFeeCallsBefore = feeProcessor.calls();
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(id3);

        swapRouter.swap(key3, SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(10 ether),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData);

        assertEq(feeProcessor.calls(), regularFeeCallsBefore + 1, "Regular fee should be collected");
        assertEq(feeProcessor.lastIsInternal(), false);

        uint256 outWithFeeBefore = calculateExactInputSwap(10 ether, uint256(r1Before), uint256(r0Before), 1000);
        uint256 outNoFeeBefore   = calculateExactInputSwap(10 ether, uint256(r1Before), uint256(r0Before), 0);
        uint256 expectedFeeWblt  = outNoFeeBefore > outWithFeeBefore ? outNoFeeBefore - outWithFeeBefore : 0;
        assertEq(feeProcessor.lastAmount(), expectedFeeWblt);

        assertEq(dailyEpochGauge.pokeCalls(), 1);
        assertEq(incentiveGauge.pokeCount(), 1);
    }

    function test_regularSwapStillWorksAfterInternalSwap() public {
        // Setup BMX pool
        addLiquidityToPool3(100 ether, 100 ether);

        // First perform swap with internal flag (but from swapRouter, so treated as regular)
        bytes memory hookData = abi.encode(bytes4(0xDE1ABEEF));
        swapRouter.swap(key3, SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(5 ether),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), hookData);

        // Track gauge calls and fee calls before second swap
        uint256 dailyPokesBefore = dailyEpochGauge.pokeCalls();
        uint256 incentivePokesBefore = incentiveGauge.pokeCount();
        uint256 feeCallsBefore = feeProcessor.calls();

        // Compute expected fee for the upcoming regular swap using PRE-SWAP reserves
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(id3); // r0 = wBLT (output), r1 = BMX (input)
        uint256 outWithFeeBefore = calculateExactInputSwap(10 ether, uint256(r1Before), uint256(r0Before), 1000);
        uint256 outNoFeeBefore   = calculateExactInputSwap(10 ether, uint256(r1Before), uint256(r0Before), 0);
        uint256 expectedFeeWblt  = outNoFeeBefore > outWithFeeBefore ? outNoFeeBefore - outWithFeeBefore : 0;

        // Now perform regular swap
        swapInPool3(10 ether, false);

        // Check that regular fee collection occurred
        assertEq(feeProcessor.calls(), feeCallsBefore + 1, "Regular fee should be collected");
        uint256 feeAmount = feeProcessor.lastAmount();
        assertGt(feeAmount, 0, "Fee should be collected");
        assertEq(feeAmount, expectedFeeWblt, "Fee should equal output reduction in wBLT");

        // Check gauges were poked for regular swap
        assertEq(dailyEpochGauge.pokeCalls(), dailyPokesBefore + 1, "DailyEpochGauge should be poked");
        assertEq(incentiveGauge.pokeCount(), incentivePokesBefore + 1, "IncentiveGauge should be poked");
    }
}


