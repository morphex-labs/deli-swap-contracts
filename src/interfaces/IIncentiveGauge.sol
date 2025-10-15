// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IIncentiveGauge
interface IIncentiveGauge {
    function initPool(PoolKey memory key, int24 initialTick) external;
    function poolTokensOf(PoolId pid) external view returns (IERC20[] memory);
    function claim(uint256 tokenId, IERC20 token, address to) external returns (uint256);
    function claimAllForOwner(PoolId[] calldata pids, address owner) external;
    function pokePool(PoolKey calldata key) external;

    // Context-based subscription callbacks
    function notifySubscribeWithContext(
        uint256 tokenId,
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner
    ) external;

    function notifyUnsubscribeWithContext(
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external;

    function notifyBurnWithContext(
        bytes32 positionKey,
        bytes32 poolIdRaw,
        address ownerAddr,
        int24 currentTick,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external;

    function notifyModifyLiquidityWithContext(
        bytes32 positionKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityChange,
        uint128 liquidityAfter
    ) external;
}
