// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockPositionManager
 * @notice Mock implementation of V4 PositionManager for testing
 * @dev Only implements the functions needed for testing tokenId collision
 */
contract MockPositionManager is ERC721 {
    using PositionInfoLibrary for PositionInfo;
    
    uint256 public nextTokenId = 1;
    
    mapping(uint256 => PositionInfo) public positionInfo;
    mapping(bytes25 => PoolKey) public poolKeys;
    
    constructor() ERC721("Mock V4 Positions", "MOCKV4") {}
    
    /// @notice Mint a new position NFT
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }
    
    /// @notice Mock implementation of getPoolAndPositionInfo
    function getPoolAndPositionInfo(uint256 /* tokenId */) 
        external 
        pure 
        returns (PoolKey memory key, PositionInfo info) 
    {
        // Return empty/default values for mock
        return (key, info);
    }
    
    /// @notice Mock implementation of getPositionLiquidity
    function getPositionLiquidity(uint256 /* tokenId */) external pure returns (uint128) {
        // Return 0 for mock
        return 0;
    }
    
    // Other IPositionManager functions would be here in a full implementation
    // For this test, we only need the basic NFT functionality
}