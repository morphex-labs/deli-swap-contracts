// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPositionHandler} from "../interfaces/IPositionHandler.sol";
import {DeliErrors} from "../libraries/DeliErrors.sol";

/**
 * @title V4PositionHandler
 * @notice Handler for standard Uniswap V4 PositionManager NFT positions
 * @dev Forwards all calls to the actual PositionManager contract
 */
contract V4PositionHandler is IPositionHandler {
    IPositionManager public immutable positionManager;

    constructor(address _positionManager) {
        if (_positionManager == address(0)) revert DeliErrors.ZeroAddress();
        positionManager = IPositionManager(_positionManager);
    }

    /// @inheritdoc IPositionHandler
    function handlesTokenId(uint256 tokenId) external view override returns (bool) {
        // Safety check: V4 tokenIds should never have bit 255 set
        // Mathematically, this check shouldn't be needed but added for robustness
        if ((tokenId & (1 << 255)) != 0) return false;

        // Check if the token exists in the PositionManager contract
        try IERC721(address(positionManager)).ownerOf(tokenId) {
            return true;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IPositionHandler
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        override
        returns (PoolKey memory key, PositionInfo info)
    {
        return positionManager.getPoolAndPositionInfo(tokenId);
    }

    /// @inheritdoc IPositionHandler
    function getPositionLiquidity(uint256 tokenId) external view override returns (uint128) {
        return positionManager.getPositionLiquidity(tokenId);
    }

    /// @inheritdoc IPositionHandler
    function ownerOf(uint256 tokenId) external view override returns (address) {
        return IERC721(address(positionManager)).ownerOf(tokenId);
    }

    /// @inheritdoc IPositionHandler
    function handlerType() external pure override returns (string memory) {
        return "V4_POSITION_MANAGER";
    }
}
