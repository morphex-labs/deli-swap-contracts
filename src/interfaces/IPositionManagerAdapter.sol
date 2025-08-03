// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionHandler} from "./IPositionHandler.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";

interface IPositionManagerAdapter is ISubscriber {
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory key, PositionInfo info);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPoolKeyFromPositionInfo(PositionInfo info) external view returns (PoolKey memory);
    function getHandler(uint256 tokenId) external view returns (IPositionHandler);
    function positionManager() external view returns (address);
}