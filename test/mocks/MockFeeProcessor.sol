// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";

contract MockFeeProcessor is IFeeProcessor {
    PoolKey public lastKey;
    uint256 public lastAmount;
    uint256 public calls;

    function collectFee(PoolKey calldata key, uint256 amount) external override {
        lastKey = key;
        lastAmount = amount;
        calls += 1;
    }
} 