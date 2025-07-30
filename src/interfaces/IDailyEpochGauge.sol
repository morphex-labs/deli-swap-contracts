// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IDailyEpochGauge
interface IDailyEpochGauge {
    function addRewards(PoolId poolId, uint256 amount) external;
    function rollIfNeeded(PoolId poolId) external;
    function initPool(PoolId pid, int24 initialTick) external;
    function pokePool(PoolKey calldata key) external;
    function claim(address to, bytes32 positionKey) external returns (uint256);
    function claimAllForOwner(PoolId[] calldata pids, address owner) external returns (uint256);
}
