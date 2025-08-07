// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPositionHandler} from "./interfaces/IPositionHandler.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";
import {IPoolKeys} from "./interfaces/IPoolKeys.sol";
import {IV2PositionHandler} from "./interfaces/IV2PositionHandler.sol";

/**
 * @title PositionManagerAdapter
 * @notice Modular adapter that routes position management calls to appropriate handlers
 * @dev Implements ISubscriber to receive notifications and forwards them to gauges
 */
contract PositionManagerAdapter is ISubscriber, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    // V4 PositionManager address for poolKeys lookup
    address public immutable positionManager;

    // Array of registered position handlers
    IPositionHandler[] public handlers;

    // Handler index by type for efficient lookups
    mapping(string => uint256) public handlerIndex;

    // Gauges that receive notifications
    ISubscriber public dailyEpochGauge;
    ISubscriber public incentiveGauge;

    // Who can call subscriber methods (Hook or Handler)
    mapping(address => bool) public isAuthorizedCaller;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event HandlerAdded(address indexed handler, string handlerType);
    event HandlerRemoved(address indexed handler, string handlerType);
    event GaugesUpdated(address dailyGauge, address incentiveGauge);
    event CallerAuthorized(address indexed caller, bool authorized);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _dailyEpochGauge, address _incentiveGauge, address _positionManager) Ownable(msg.sender) {
        if (_dailyEpochGauge == address(0) || _incentiveGauge == address(0) || _positionManager == address(0)) {
            revert DeliErrors.ZeroAddress();
        }

        dailyEpochGauge = ISubscriber(_dailyEpochGauge);
        incentiveGauge = ISubscriber(_incentiveGauge);
        positionManager = _positionManager;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Only allow calls from PositionManager, handlers, or hooks
    modifier onlyAuthorizedCaller() {
        if (
            !(msg.sender == positionManager)
            && !isAuthorizedCaller[msg.sender]
        ) {
            revert DeliErrors.NotAuthorized();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a new position handler
    /// @param handler The handler contract address
    function addHandler(address handler) external onlyOwner {
        if (handler == address(0)) revert DeliErrors.ZeroAddress();

        IPositionHandler posHandler = IPositionHandler(handler);
        string memory handlerType = posHandler.handlerType();

        // Check if handler type already exists
        if (
            handlerIndex[handlerType] != 0
                || (handlers.length > 0 && keccak256(bytes(handlers[0].handlerType())) == keccak256(bytes(handlerType)))
        ) {
            revert DeliErrors.HandlerAlreadyExists();
        }

        handlers.push(posHandler);
        handlerIndex[handlerType] = handlers.length; // 1-indexed

        emit HandlerAdded(handler, handlerType);
    }

    /// @notice Remove a position handler
    /// @param handlerType The type identifier of the handler to remove
    function removeHandler(string calldata handlerType) external onlyOwner {
        uint256 index = handlerIndex[handlerType];
        if (index == 0) revert DeliErrors.HandlerNotFound();

        uint256 arrayIndex = index - 1; // Convert to 0-indexed
        address handlerAddress = address(handlers[arrayIndex]);

        // Move last element to the removed position and pop
        uint256 lastIndex = handlers.length - 1;
        if (arrayIndex != lastIndex) {
            handlers[arrayIndex] = handlers[lastIndex];
            // Update the moved handler's index
            string memory movedType = handlers[arrayIndex].handlerType();
            handlerIndex[movedType] = index;
        }

        handlers.pop();
        delete handlerIndex[handlerType];

        emit HandlerRemoved(handlerAddress, handlerType);
    }

    /// @notice Update gauge addresses
    function setGauges(address _dailyGauge, address _incentiveGauge) external onlyOwner {
        if (_dailyGauge == address(0) || _incentiveGauge == address(0)) {
            revert DeliErrors.ZeroAddress();
        }
        dailyEpochGauge = ISubscriber(_dailyGauge);
        incentiveGauge = ISubscriber(_incentiveGauge);
        emit GaugesUpdated(_dailyGauge, _incentiveGauge);
    }

    /// @notice Authorize or revoke a caller (PositionManager or hooks)
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        isAuthorizedCaller[caller] = authorized;
        emit CallerAuthorized(caller, authorized);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION QUERY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Find which handler manages a tokenId
    /// @param tokenId The position token ID
    /// @return The handler that manages this tokenId
    function getHandler(uint256 tokenId) public view returns (IPositionHandler) {
        uint256 length = handlers.length;
        for (uint256 i = 0; i < length; i++) {
            if (handlers[i].handlesTokenId(tokenId)) {
                return handlers[i];
            }
        }
        revert DeliErrors.HandlerNotFound();
    }

    /// @notice Get pool and position info for a tokenId
    /// @dev Routes to the appropriate handler
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory key, PositionInfo info) {
        IPositionHandler handler = getHandler(tokenId);
        return handler.getPoolAndPositionInfo(tokenId);
    }

    /// @notice Get the current liquidity of a position
    /// @dev Routes to the appropriate handler
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        IPositionHandler handler = getHandler(tokenId);
        return handler.getPositionLiquidity(tokenId);
    }

    /// @notice Get the owner of a position
    /// @dev Routes to the appropriate handler
    function ownerOf(uint256 tokenId) external view returns (address) {
        IPositionHandler handler = getHandler(tokenId);
        return handler.ownerOf(tokenId);
    }

    /// @notice Get PoolKey from PositionInfo for burned tokens
    /// @dev First tries V4 PositionManager, then falls back to V2 pools
    function getPoolKeyFromPositionInfo(PositionInfo info) external view returns (PoolKey memory) {
        bytes25 truncatedPoolId = PositionInfoLibrary.poolId(info);
        return _getPoolKeyFromTruncatedId(truncatedPoolId);
    }

    /// @notice Get PoolKey from a PoolId
    /// @dev First tries V4 PositionManager, then falls back to V2 pools
    function getPoolKeyFromPoolId(PoolId poolId) external view returns (PoolKey memory) {
        bytes25 truncatedPoolId = bytes25(PoolId.unwrap(poolId));
        return _getPoolKeyFromTruncatedId(truncatedPoolId);
    }

    /// @dev Internal helper to get PoolKey from truncated poolId with V2 fallback
    function _getPoolKeyFromTruncatedId(bytes25 truncatedPoolId) internal view returns (PoolKey memory) {
        if (positionManager == address(0)) revert DeliErrors.ZeroAddress();
        
        // First try to get from V4 PositionManager
        PoolKey memory poolKey = IPoolKeys(positionManager).poolKeys(truncatedPoolId);
        
        // If not found (tickSpacing = 0), check V2 pools
        if (poolKey.tickSpacing == 0) {
            // Try each handler to see if it's a V2 pool
            uint256 length = handlers.length;
            for (uint256 i = 0; i < length; i++) {
                // Check if this is the V2 handler
                if (keccak256(bytes(handlers[i].handlerType())) == keccak256(bytes("V2_CONSTANT_PRODUCT"))) {
                    // Cast to IV2PositionHandler and get poolKey using truncated poolId
                    IV2PositionHandler v2Handler = IV2PositionHandler(address(handlers[i]));
                    poolKey = v2Handler.getPoolKeyByTruncatedId(truncatedPoolId);
                    if (poolKey.tickSpacing != 0) {
                        return poolKey;
                    }
                }
            }
            
            // If still not found, revert
            revert DeliErrors.PoolNotFound();
        }
        
        return poolKey;
    }

    /*//////////////////////////////////////////////////////////////
                      SUBSCRIBER INTERFACE (ISubscriber)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISubscriber
    function notifySubscribe(uint256 tokenId, bytes memory data) external override onlyAuthorizedCaller {
        // Forward to both gauges
        dailyEpochGauge.notifySubscribe(tokenId, data);
        incentiveGauge.notifySubscribe(tokenId, data);
    }

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external override onlyAuthorizedCaller {
        // Forward to both gauges
        dailyEpochGauge.notifyUnsubscribe(tokenId);
        incentiveGauge.notifyUnsubscribe(tokenId);
    }

    /// @inheritdoc ISubscriber
    function notifyBurn(
        uint256 tokenId,
        address ownerAddr,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) external override onlyAuthorizedCaller {
        // Forward to both gauges
        dailyEpochGauge.notifyBurn(tokenId, ownerAddr, info, liquidity, feesAccrued);
        incentiveGauge.notifyBurn(tokenId, ownerAddr, info, liquidity, feesAccrued);
    }

    /// @inheritdoc ISubscriber
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued)
        external
        override
        onlyAuthorizedCaller
    {
        // Forward to both gauges
        dailyEpochGauge.notifyModifyLiquidity(tokenId, liquidityChange, feesAccrued);
        incentiveGauge.notifyModifyLiquidity(tokenId, liquidityChange, feesAccrued);
    }
}
