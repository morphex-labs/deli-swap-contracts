// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// no additional imports needed

contract DeliHookConstantProduct_FeesTest is DeliHookConstantProduct_TestBase {
    // wBLT -> token2, exact input: fee in wBLT (input side)
    function test_fee_wbltToToken2_exactInput() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountIn = 10 ether;
        uint256 feePips = 3000;
        uint256 expectedFee = (amountIn * feePips) / 1_000_000;
        swapRouter.swap(key1, SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertEq(feeProcessor.lastAmount(), expectedFee);
        assertEq(feeProcessor.calls(), 1);
    }

    // token2 -> wBLT, exact output: fee in wBLT (output side)
    function test_fee_token2ToWblt_exactOutput() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountOut = 15 ether;
        uint256 feePips = 3000;
        // fee = ceil(netOut * f / (1 - f)) to match hook logic
        uint256 expectedFee = (amountOut * feePips + (1_000_000 - feePips - 1)) / (1_000_000 - feePips);
        swapRouter.swap(key1, SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertEq(feeProcessor.lastAmount(), expectedFee);
        assertEq(feeProcessor.calls(), 1);
    }
    // token2 -> wBLT, exact input: fee in wBLT (output side)
    function test_fee_token2ToWblt_exactInput() public {
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountIn = 10 ether; // token2 in
        uint256 outWithFee = calculateExactInputSwap(amountIn, 200 ether, 100 ether, 3000);
        uint256 outNoFee = calculateExactInputSwap(amountIn, 200 ether, 100 ether, 0);
        uint256 expectedFee = outNoFee > outWithFee ? outNoFee - outWithFee : 0;

        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch (x->wBLT exact in)");
        assertEq(feeProcessor.calls(), 1, "collectFee not called");
    }

    // wBLT -> token2, exact output: fee in wBLT (input side)
    function test_fee_wbltToToken2_exactOutput() public {
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountOut = 20 ether; // token2 out
        uint256 inputWithFee = calculateExactOutputSwap(amountOut, 100 ether, 200 ether, 3000);
        uint256 inputNoFee = calculateExactOutputSwap(amountOut, 100 ether, 200 ether, 0);
        uint256 expectedFee = inputWithFee > inputNoFee ? inputWithFee - inputNoFee : 0;

        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch (wBLT->x exact out)");
        assertEq(feeProcessor.calls(), 1, "collectFee not called");
    }

    // Dedicated: exact output with fee-from-output, validate fee and input math on key1 (0.3%)
    function test_fee_token2ToWblt_exactOutput_feeFromOutput() public {
        // Use canonical pool key1: currency0=wBLT, currency1=token2, fee=0.3%
        addLiquidityToPool1(100 ether, 200 ether);

        // Request net output (wBLT) and verify fee = ceil(netOut * f / (1 - f))
        uint256 netOut = 30 ether; // ensure < reserve0
        uint256 feePips = 3000; // 0.3%

        // Snapshot reserves before to validate input math
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(id1);

        // Perform exact output swap: token2 -> wBLT (fee from output side)
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: int256(netOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // fee = ceil(netOut * f / (1 - f))
        uint256 expectedFee = (netOut * feePips + (1_000_000 - feePips - 1)) / (1_000_000 - feePips);
        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch vs formula");

        // Validate input equals CP amountIn computed against grossOut with zero LP fee
        uint256 grossOut = netOut + expectedFee;
        uint256 expectedIn = calculateExactOutputSwap(grossOut, uint256(r1Before), uint256(r0Before), 0);
        (uint128 r0After, uint128 r1After) = hook.getReserves(id1);
        uint256 actualIn = uint256(r1After) - uint256(r1Before);
        assertEq(actualIn, expectedIn, "amountIn mismatch vs grossOut zero-fee CP math");

        // Also verify reserve0 decreased by grossOut (net + fee)
        uint256 deltaR0 = uint256(r0Before) - uint256(r0After);
        assertEq(deltaR0, grossOut, "reserve0 delta should equal grossOut");
    }

    // Extra: token2 -> wBLT, exact input (fee orientation already covered, this keeps parity with original suite distribution)
    function test_fee_token2ToWblt_exactInput_again() public {
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 amountIn = 10 ether;
        uint256 outWithFee = calculateExactInputSwap(amountIn, 200 ether, 100 ether, 3000);
        uint256 outNoFee = calculateExactInputSwap(amountIn, 200 ether, 100 ether, 0);
        uint256 expectedFee = outNoFee > outWithFee ? outNoFee - outWithFee : 0;
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(feeProcessor.lastAmount(), expectedFee);
    }
}


