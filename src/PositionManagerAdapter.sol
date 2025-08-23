// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EfficientHashLib} from "lib/solady/src/utils/EfficientHashLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionHandler} from "./interfaces/IPositionHandler.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";
import {IPoolKeys} from "./interfaces/IPoolKeys.sol";
import {IDailyEpochGauge} from "./interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "./interfaces/IIncentiveGauge.sol";
import {IV2PositionHandler} from "./interfaces/IV2PositionHandler.sol";

/**
 * @title PositionManagerAdapter
 * @notice Modular adapter that routes position management calls to appropriate handlers
 * @dev Implements ISubscriber to receive notifications and forwards them to gauges
 */
contract PositionManagerAdapter is ISubscriber, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Context for notify functions
    struct NotifyContext {
        PoolId pid;
        bytes32 pidRaw;
        bytes32 posKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int24 currentTick;
        address owner;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // V4 PositionManager address for poolKeys lookup
    address public immutable POSITION_MANAGER;
    // Uniswap V4 PoolManager for slot0/tick lookups
    IPoolManager public immutable POOL_MANAGER;

    // Array of registered position handlers
    IPositionHandler[] public handlers;

    // Handler index by type for efficient lookups
    mapping(string => uint256) public handlerIndex;

    // Gauges that receive notifications (context-based)
    IDailyEpochGauge public dailyEpochGauge;
    IIncentiveGauge public incentiveGauge;

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

    constructor(address _dailyEpochGauge, address _incentiveGauge, address _positionManager, address _poolManager)
        Ownable(msg.sender)
    {
        if (
            _dailyEpochGauge == address(0) || _incentiveGauge == address(0) || _positionManager == address(0)
                || _poolManager == address(0)
        ) {
            revert DeliErrors.ZeroAddress();
        }

        dailyEpochGauge = IDailyEpochGauge(_dailyEpochGauge);
        incentiveGauge = IIncentiveGauge(_incentiveGauge);
        POSITION_MANAGER = _positionManager;
        POOL_MANAGER = IPoolManager(_poolManager);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Only allow calls from PositionManager, handlers, or hooks
    modifier onlyAuthorizedCaller() {
        if (!(msg.sender == POSITION_MANAGER) && !isAuthorizedCaller[msg.sender]) {
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

        // Check if handler type already exists (1-based index mapping)
        if (handlerIndex[handlerType] != 0) revert DeliErrors.HandlerAlreadyExists();

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
        dailyEpochGauge = IDailyEpochGauge(_dailyGauge);
        incentiveGauge = IIncentiveGauge(_incentiveGauge);
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
        (key, info,) = handler.getPoolPositionAndLiquidity(tokenId);
    }

    /// @notice Get the current liquidity of a position
    /// @dev Routes to the appropriate handler
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        IPositionHandler handler = getHandler(tokenId);
        (,, liquidity) = handler.getPoolPositionAndLiquidity(tokenId);
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

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Build context from tokenId
    function _buildContextFromToken(uint256 tokenId, bool includeOwner)
        internal
        view
        returns (NotifyContext memory ctx)
    {
        IPositionHandler handler = getHandler(tokenId);
        (PoolKey memory key, PositionInfo info, uint128 liq) = handler.getPoolPositionAndLiquidity(tokenId);
        PoolId pid = key.toId();
        bytes32 pidRaw = bytes32(PoolId.unwrap(pid));
        ctx.pid = pid;
        ctx.pidRaw = pidRaw;
        ctx.tickLower = info.tickLower();
        ctx.tickUpper = info.tickUpper();
        ctx.posKey = EfficientHashLib.hash(bytes32(tokenId), pidRaw);
        ctx.liquidity = liq;
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        ctx.currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (includeOwner) {
            ctx.owner = handler.ownerOf(tokenId);
        }
    }

    /// @dev Build context from PositionInfo
    function _buildContextFromInfo(uint256 tokenId, PositionInfo info)
        internal
        view
        returns (NotifyContext memory ctx)
    {
        PoolKey memory key = _getPoolKeyFromTruncatedId(PositionInfoLibrary.poolId(info));
        PoolId pid = key.toId();
        bytes32 pidRaw = bytes32(PoolId.unwrap(pid));
        ctx.pid = pid;
        ctx.pidRaw = pidRaw;
        ctx.tickLower = info.tickLower();
        ctx.tickUpper = info.tickUpper();
        ctx.posKey = EfficientHashLib.hash(bytes32(tokenId), pidRaw);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        ctx.currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @dev Internal helper to get PoolKey from truncated poolId with V2 fallback
    function _getPoolKeyFromTruncatedId(bytes25 truncatedPoolId) internal view returns (PoolKey memory) {
        if (POSITION_MANAGER == address(0)) revert DeliErrors.ZeroAddress();

        // First try to get from V4 PositionManager
        PoolKey memory poolKey = IPoolKeys(POSITION_MANAGER).poolKeys(truncatedPoolId);

        // If not found (tickSpacing = 0), check V2 pools
        if (poolKey.tickSpacing == 0) {
            // Try each handler to see if it's a V2 pool
            uint256 length = handlers.length;
            for (uint256 i = 0; i < length; i++) {
                // Check if this is the V2 handler
                if (
                    EfficientHashLib.hash(bytes(handlers[i].handlerType()))
                        == EfficientHashLib.hash(bytes("V2_CONSTANT_PRODUCT"))
                ) {
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
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyAuthorizedCaller {
        // Pre-fetch context once via direct handler to avoid extra external self-calls
        NotifyContext memory c = _buildContextFromToken(tokenId, true);

        dailyEpochGauge.notifySubscribeWithContext(
            tokenId, c.posKey, c.pidRaw, c.currentTick, c.tickLower, c.tickUpper, c.liquidity, c.owner
        );
        incentiveGauge.notifySubscribeWithContext(
            tokenId, c.posKey, c.pidRaw, c.currentTick, c.tickLower, c.tickUpper, c.liquidity, c.owner
        );
    }

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external override onlyAuthorizedCaller {
        // Build full context once and forward to both gauges
        NotifyContext memory c = _buildContextFromToken(tokenId, true);

        dailyEpochGauge.notifyUnsubscribeWithContext(
            c.posKey, c.pidRaw, c.currentTick, c.owner, c.tickLower, c.tickUpper, c.liquidity
        );
        incentiveGauge.notifyUnsubscribeWithContext(c.posKey, c.pidRaw, c.tickLower, c.tickUpper, c.liquidity);
    }

    /// @inheritdoc ISubscriber
    function notifyBurn(
        uint256 tokenId,
        address ownerAddr,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta /*feesAccrued*/
    ) external override onlyAuthorizedCaller {
        // Pre-fetch context once via direct handler to avoid extra external self-calls
        NotifyContext memory c = _buildContextFromInfo(tokenId, info);

        dailyEpochGauge.notifyBurnWithContext(
            c.posKey, c.pidRaw, ownerAddr, c.currentTick, c.tickLower, c.tickUpper, uint128(liquidity)
        );
        incentiveGauge.notifyBurnWithContext(
            c.posKey, c.pidRaw, ownerAddr, c.currentTick, c.tickLower, c.tickUpper, uint128(liquidity)
        );
    }

    /// @inheritdoc ISubscriber
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta /*feesAccrued*/ )
        external
        override
        onlyAuthorizedCaller
    {
        // Pre-fetch context once via direct handler to avoid extra external self-calls
        NotifyContext memory c = _buildContextFromToken(tokenId, false);

        // Note: liquidityAfter comes from PositionManager; we forward it as-is
        dailyEpochGauge.notifyModifyLiquidityWithContext(
            c.posKey, c.pidRaw, c.currentTick, c.tickLower, c.tickUpper, liquidityChange, c.liquidity
        );
        incentiveGauge.notifyModifyLiquidityWithContext(
            c.posKey, c.pidRaw, c.currentTick, c.tickLower, c.tickUpper, liquidityChange, c.liquidity
        );
    }
}
