// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IIncentiveGauge
interface IIncentiveGauge {
    function poolTokensOf(PoolId pid) external view returns (IERC20[] memory);
    function claim(IERC20 token, bytes32 positionKey, address to) external returns (uint256);
    function claimAllForOwner(PoolId[] calldata pids, address owner) external;
    function pokePool(PoolKey calldata key) external;
}
