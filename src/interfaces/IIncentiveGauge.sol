// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title IIncentiveGauge
interface IIncentiveGauge {
    function initPool(PoolKey memory key, int24 initialTick) external;
    function poolTokensOf(PoolId pid) external view returns (IERC20[] memory);
    function claim(uint256 tokenId, IERC20 token, address to) external returns (uint256);
    function claimAllForOwner(PoolId[] calldata pids, address owner) external;
    function pokePool(PoolKey calldata key) external;
    
    // Subscription callbacks (from ISubscriber interface)
    function notifySubscribe(uint256 tokenId, bytes memory data) external;
    function notifyUnsubscribe(uint256 tokenId) external;
    function notifyBurn(uint256 tokenId, address ownerAddr, PositionInfo info, uint256 liquidity, BalanceDelta feesAccrued) external;
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) external;
}
