// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";

contract MockFeeProcessor is IFeeProcessor {
    PoolKey public lastKey;
    uint256 public lastAmount;
    uint256 public calls;
    uint256 public internalFeeCalls;
    uint256 public lastInternalFeeAmount;

    function collectFee(PoolKey calldata key, uint256 amount) external override {
        lastKey = key;
        lastAmount = amount;
        calls += 1;
    }

    function collectInternalFee(uint256 bmxAmount) external override {
        lastInternalFeeAmount = bmxAmount;
        internalFeeCalls += 1;
    }
} 