// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPoolKeys
/// @notice Interface exposing PositionManager.poolKeys mapping so external contracts can reverse-lookup `PoolKey` from a `PoolId`.
interface IPoolKeys {
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory);
}
