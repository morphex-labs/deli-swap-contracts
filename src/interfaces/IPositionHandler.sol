// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

/**
 * @title IPositionHandler
 * @notice Interface for modular position handlers in the PositionManagerAdapter system
 * @dev Each handler manages a specific type of position (V4 NFT, V2 liquidity, etc.)
 */
interface IPositionHandler {
    /// @notice Check if this handler manages a specific tokenId
    /// @param tokenId The position token ID to check
    /// @return True if this handler manages the tokenId
    function handlesTokenId(uint256 tokenId) external view returns (bool);

    /// @notice Get pool, position info, and current liquidity in a single call
    /// @param tokenId The position token ID
    /// @return key The pool key
    /// @return info The position info (packed with tick ranges)
    /// @return liquidity The current liquidity amount
    function getPoolPositionAndLiquidity(uint256 tokenId)
        external
        view
        returns (PoolKey memory key, PositionInfo info, uint128 liquidity);
    
    /// @notice Get the owner of a position
    /// @param tokenId The position token ID
    /// @return The owner address
    function ownerOf(uint256 tokenId) external view returns (address);
    
    /// @notice Get a unique identifier for this handler
    /// @return A unique identifier string
    function handlerType() external pure returns (string memory);
}