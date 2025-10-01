// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IDailyEpochGauge
interface IDailyEpochGauge {
    function addRewards(PoolId poolId, uint256 amount) external;
    function initPool(PoolKey memory key, int24 initialTick) external;
    function pokePool(PoolKey calldata key) external;
    function claim(uint256 tokenId, address to) external returns (uint256);
    function claimAllForOwner(PoolId[] calldata pids, address owner) external returns (uint256);

    // Context-based subscription callbacks
    function notifySubscribeWithContext(
        uint256 tokenId,
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner
    ) external;

    function notifyUnsubscribeWithContext(
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external;

    function notifyBurnWithContext(
        bytes32 posKey,
        bytes32 poolIdRaw,
        address ownerAddr,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external;

    function notifyModifyLiquidityWithContext(
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityChange,
        uint128 liquidityAfter
    ) external;
}
