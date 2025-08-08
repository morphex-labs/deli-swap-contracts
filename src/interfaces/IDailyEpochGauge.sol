// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title IDailyEpochGauge
interface IDailyEpochGauge {
    function addRewards(PoolId poolId, uint256 amount) external;
    function initPool(PoolId pid, int24 initialTick) external;
    function pokePool(PoolKey calldata key) external;
    function claim(uint256 tokenId, address to) external returns (uint256);
    function claimAllForOwner(PoolId[] calldata pids, address owner) external returns (uint256);
    
    // Subscription callbacks (from ISubscriber interface)
    function notifySubscribe(uint256 tokenId, bytes memory data) external;
    function notifyUnsubscribe(uint256 tokenId) external;
    function notifyBurn(uint256 tokenId, address ownerAddr, PositionInfo info, uint256 liquidity, BalanceDelta feesAccrued) external;
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) external;
}
