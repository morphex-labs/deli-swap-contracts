// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";

contract MockFeeProcessor is IFeeProcessor {
    PoolKey public lastKey;
    uint256 public lastAmount;
    uint256 public calls;
    bool public lastIsInternal;

    function collectFee(PoolKey calldata key, uint256 amount, bool isInternalSwap) external override {
        lastKey = key;
        lastAmount = amount;
        lastIsInternal = isInternalSwap;
        calls += 1;
    }
} 