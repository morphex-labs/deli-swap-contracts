// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IV2PositionHandler {
    function notifyAddLiquidity(PoolKey calldata poolKey, address owner, uint128 liquidityDelta) external;
    function notifyRemoveLiquidity(PoolKey calldata poolKey, address owner, uint128 liquidityDelta) external;
    function getPoolKeyByTruncatedId(bytes25 truncatedPoolId) external view returns (PoolKey memory);
}