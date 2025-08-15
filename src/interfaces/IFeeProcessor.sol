// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IFeeProcessor
interface IFeeProcessor {
    function collectFee(PoolKey calldata key, uint256 amountWBLT, bool isInternalSwap) external;
}
