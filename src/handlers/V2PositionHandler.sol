// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionHandler} from "../interfaces/IPositionHandler.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {IPositionManagerAdapter} from "../interfaces/IPositionManagerAdapter.sol";
import {DeliErrors} from "../libraries/DeliErrors.sol";

/**
 * @title V2PositionHandler
 * @notice Handler for V2 constant product liquidity positions
 * @dev Manages synthetic tokenIds for V2 positions and implements IPositionHandler
 */
contract V2PositionHandler is IPositionHandler, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    // The V2 hook that can call this handler
    address public immutable v2Hook;

    // The PositionManagerAdapter to notify
    IPositionManagerAdapter public positionManagerAdapter;

    // Map V2 liquidity providers to synthetic tokenIds
    // poolId => owner => tokenId
    mapping(PoolId => mapping(address => uint256)) public v2TokenIds;

    // Track synthetic PositionInfo for each tokenId
    mapping(uint256 => SyntheticPosition) internal syntheticPositions;

    // Track owner of each synthetic tokenId
    mapping(uint256 => address) internal tokenOwners;

    // Track which pools use V2
    mapping(PoolId => bool) public isV2Pool;
    
    // Track PoolKey for each V2 pool to support getPoolKeyFromPositionInfo
    // Uses truncated poolId (bytes25) as key to match PositionInfo storage
    mapping(bytes25 => PoolKey) public poolKeysByTruncatedId;

    // Type prefix for V2 tokenIds (bit 255 set to 1)
    // This ensures V2 tokenIds never collide with V4 PositionManager tokenIds
    // V2 tokenIds will be in range [2^255, 2^256-1] while V4 uses [1, 2^255-1]
    uint256 private constant V2_TOKEN_PREFIX = 1 << 255;

    // Counter for synthetic tokenIds (without prefix)
    uint256 private baseTokenId = 1;

    struct SyntheticPosition {
        PoolKey poolKey;
        uint128 liquidity;
        bool exists;
    }

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event V2PositionCreated(PoolId indexed poolId, address indexed owner, uint256 tokenId);
    event V2PositionModified(PoolId indexed poolId, address indexed owner, uint256 tokenId, int256 liquidityDelta);
    event V2PositionRemoved(PoolId indexed poolId, address indexed owner, uint256 tokenId);
    event PositionManagerAdapterUpdated(address newAdapter);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _v2Hook) Ownable(msg.sender) {
        if (_v2Hook == address(0)) revert DeliErrors.ZeroAddress();
        v2Hook = _v2Hook;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyV2Hook() {
        if (msg.sender != v2Hook) revert DeliErrors.NotHook();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the PositionManagerAdapter address
    function setPositionManagerAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert DeliErrors.ZeroAddress();
        positionManagerAdapter = IPositionManagerAdapter(_adapter);
        emit PositionManagerAdapterUpdated(_adapter);
    }

    /// @notice Mark a pool as using V2
    function setV2Pool(PoolId poolId, bool isV2) external onlyOwner {
        isV2Pool[poolId] = isV2;
    }

    /*//////////////////////////////////////////////////////////////
                           HOOK INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by DeliHookConstantProduct when liquidity is added
    function notifyAddLiquidity(PoolKey calldata poolKey, address owner, uint128 liquidityDelta) external onlyV2Hook {
        PoolId poolId = poolKey.toId();
        isV2Pool[poolId] = true;
        
        // Store poolKey for this pool if not already stored
        // Use truncated poolId to match PositionInfo storage format
        bytes25 truncatedPoolId = bytes25(PoolId.unwrap(poolId));
        if (poolKeysByTruncatedId[truncatedPoolId].tickSpacing == 0) {
            poolKeysByTruncatedId[truncatedPoolId] = poolKey;
        }

        uint256 tokenId = v2TokenIds[poolId][owner];

        if (tokenId == 0) {
            // First time - create new position
            tokenId = _createPosition(poolKey, poolId, owner, liquidityDelta);
        } else {
            // Existing position - modify liquidity
            _modifyPosition(poolKey, poolId, owner, tokenId, int256(uint256(liquidityDelta)));
        }
    }

    /// @notice Called by DeliHookConstantProduct when liquidity is removed
    function notifyRemoveLiquidity(PoolKey calldata poolKey, address owner, uint128 liquidityDelta)
        external
        onlyV2Hook
    {
        PoolId poolId = poolKey.toId();
        uint256 tokenId = v2TokenIds[poolId][owner];

        if (tokenId == 0) revert DeliErrors.PositionNotFound();

        SyntheticPosition storage pos = syntheticPositions[tokenId];

        if (liquidityDelta >= pos.liquidity) {
            // Removing all liquidity - burn position
            _burnPosition(poolKey, poolId, owner, tokenId, pos.liquidity);
        } else {
            // Partial removal - modify liquidity
            _modifyPosition(poolKey, poolId, owner, tokenId, -int256(uint256(liquidityDelta)));
        }
    }

    /*//////////////////////////////////////////////////////////////
                      IPOSITIONHANDLER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPositionHandler
    function handlesTokenId(uint256 tokenId) external view override returns (bool) {
        // Check: V2 tokenIds always have bit 255 set
        if ((tokenId & V2_TOKEN_PREFIX) == 0) return false;

        // Then check if this tokenId exists in our synthetic positions
        return syntheticPositions[tokenId].exists;
    }

    /// @inheritdoc IPositionHandler
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        override
        returns (PoolKey memory key, PositionInfo info)
    {
        SyntheticPosition storage pos = syntheticPositions[tokenId];
        if (!pos.exists) revert DeliErrors.PositionNotFound();

        key = pos.poolKey;
        info = _createPositionInfo(key);
    }

    /// @inheritdoc IPositionHandler
    function getPositionLiquidity(uint256 tokenId) external view override returns (uint128) {
        return syntheticPositions[tokenId].liquidity;
    }

    /// @inheritdoc IPositionHandler
    function ownerOf(uint256 tokenId) external view override returns (address) {
        address owner = tokenOwners[tokenId];
        if (owner == address(0)) revert DeliErrors.PositionNotFound();
        return owner;
    }

    /// @inheritdoc IPositionHandler
    function handlerType() external pure override returns (string memory) {
        return "V2_CONSTANT_PRODUCT";
    }
    
    /// @notice Get the PoolKey for a given truncated poolId
    /// @dev Returns the stored PoolKey as a proper memory struct
    /// @param truncatedPoolId The truncated poolId (bytes25) from PositionInfo
    function getPoolKeyByTruncatedId(bytes25 truncatedPoolId) external view returns (PoolKey memory) {
        return poolKeysByTruncatedId[truncatedPoolId];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Create a new synthetic position
    function _createPosition(PoolKey calldata poolKey, PoolId poolId, address owner, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        // Generate tokenId with V2 prefix (bit 255 set)
        tokenId = V2_TOKEN_PREFIX | baseTokenId++;

        // Store mappings
        v2TokenIds[poolId][owner] = tokenId;
        tokenOwners[tokenId] = owner;
        syntheticPositions[tokenId] = SyntheticPosition({poolKey: poolKey, liquidity: liquidity, exists: true});

        // Notify PositionManagerAdapter if set
        if (address(positionManagerAdapter) != address(0)) {
            positionManagerAdapter.notifySubscribe(tokenId, "");
        }

        emit V2PositionCreated(poolId, owner, tokenId);
    }

    /// @dev Modify an existing position's liquidity
    function _modifyPosition(PoolKey calldata, PoolId poolId, address owner, uint256 tokenId, int256 liquidityDelta)
        internal
    {
        SyntheticPosition storage pos = syntheticPositions[tokenId];
        if (!pos.exists) revert DeliErrors.PositionNotFound();

        // Update stored liquidity
        if (liquidityDelta < 0) {
            uint256 decrease = uint256(-liquidityDelta);
            if (decrease > pos.liquidity) revert DeliErrors.InsufficientLiquidity();
            pos.liquidity -= uint128(decrease);
        } else {
            pos.liquidity += uint128(uint256(liquidityDelta));
        }

        // Notify PositionManagerAdapter if set
        if (address(positionManagerAdapter) != address(0)) {
            BalanceDelta delta = BalanceDelta.wrap(0); // No fees for V2
            positionManagerAdapter.notifyModifyLiquidity(tokenId, liquidityDelta, delta);
        }

        emit V2PositionModified(poolId, owner, tokenId, liquidityDelta);
    }

    /// @dev Remove a position completely
    function _burnPosition(PoolKey calldata poolKey, PoolId poolId, address owner, uint256 tokenId, uint128 liquidity)
        internal
    {
        // Create synthetic PositionInfo for the burn notification
        PositionInfo info = _createPositionInfo(poolKey);

        // Notify PositionManagerAdapter if set
        if (address(positionManagerAdapter) != address(0)) {
            BalanceDelta delta = BalanceDelta.wrap(0); // No fees for V2
            positionManagerAdapter.notifyBurn(tokenId, owner, info, uint256(liquidity), delta);
        }

        // Clean up storage
        delete v2TokenIds[poolId][owner];
        delete tokenOwners[tokenId];
        delete syntheticPositions[tokenId];

        emit V2PositionRemoved(poolId, owner, tokenId);
    }

    /// @dev Create a synthetic PositionInfo struct for V2 positions
    function _createPositionInfo(PoolKey memory poolKey) internal pure returns (PositionInfo info) {
        info = PositionInfoLibrary.initialize(poolKey, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }
}
