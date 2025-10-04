// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

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
        // grossOut = ceil(netOut / (1 - f)), fee = grossOut - netOut
        uint256 grossOut = (amountOut * 1_000_000 + (1_000_000 - feePips - 1)) / (1_000_000 - feePips);
        uint256 expectedFee = grossOut - amountOut;
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


