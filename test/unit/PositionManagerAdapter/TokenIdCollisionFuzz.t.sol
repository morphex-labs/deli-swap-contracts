// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title TokenIdCollisionFuzzTest
 * @notice Fuzz tests to verify tokenId collision prevention between V2 and V4 position handlers
 * @dev Tests various edge cases and random inputs to ensure:
 *      - V4 handler only accepts tokenIds without bit 255 set
 *      - V2 handler only accepts tokenIds with bit 255 set
 *      - No tokenId is ever handled by both handlers
 *      - The adapter correctly routes tokenIds to the appropriate handler
 */

import {Test} from "forge-std/Test.sol";
import {PositionManagerAdapter} from "../../../src/PositionManagerAdapter.sol";
import {V2PositionHandler} from "../../../src/handlers/V2PositionHandler.sol";
import {V4PositionHandler} from "../../../src/handlers/V4PositionHandler.sol";
import {IPositionHandler} from "../../../src/interfaces/IPositionHandler.sol";
import {MockPositionManager} from "../../mocks/MockPositionManager.sol";
import {MockPoolManager} from "../../mocks/MockPoolManager.sol";
import {MockV2Hook} from "../../mocks/MockV2Hook.sol";
import {MockDailyEpochGauge} from "../../mocks/MockDailyEpochGauge.sol";
import {MockIncentiveGauge} from "../../mocks/MockIncentiveGauge.sol";
import {DeliErrors} from "../../../src/libraries/DeliErrors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract TokenIdCollisionFuzzTest is Test {
    using PoolIdLibrary for PoolKey;
    
    PositionManagerAdapter adapter;
    V2PositionHandler v2Handler;
    V4PositionHandler v4Handler;
    MockPositionManager mockPositionManager;
    MockPoolManager mockPoolManager;
    MockV2Hook mockV2Hook;
    MockDailyEpochGauge mockDailyGauge;
    MockIncentiveGauge mockIncentiveGauge;
    
    // Constants for bit manipulation
    uint256 constant V2_TOKEN_PREFIX = 1 << 255;
    uint256 constant BIT_255_MASK = 1 << 255;
    
    function setUp() public {
        // Deploy mocks
        mockPositionManager = new MockPositionManager();
        mockPoolManager = new MockPoolManager();
        mockV2Hook = new MockV2Hook();
        mockDailyGauge = new MockDailyEpochGauge();
        mockIncentiveGauge = new MockIncentiveGauge();
        
        // Deploy handlers
        v2Handler = new V2PositionHandler(address(mockV2Hook));
        v4Handler = new V4PositionHandler(address(mockPositionManager));
        
        // Deploy adapter
        adapter = new PositionManagerAdapter(address(mockDailyGauge), address(mockIncentiveGauge), address(mockPositionManager), address(mockPoolManager));
        
        // Set up v2Handler
        v2Handler.setPositionManagerAdapter(address(adapter));
        
        // Add both handlers
        adapter.addHandler(address(v4Handler));
        adapter.addHandler(address(v2Handler));
        
        // Authorize callers
        adapter.setAuthorizedCaller(address(v2Handler), true);
    }
    
    /// @notice Fuzz test: V4 handler should only handle tokenIds without bit 255 set
    function testFuzz_V4HandlerOnlyHandlesLowTokenIds(uint256 tokenId) public view {
        bool hasBit255 = (tokenId & BIT_255_MASK) != 0;
        bool v4Handles = v4Handler.handlesTokenId(tokenId);
        
        if (hasBit255) {
            // V4 should never handle tokenIds with bit 255 set
            assertFalse(v4Handles, "V4 handler should not handle tokenIds with bit 255 set");
        }
        // Note: We can't assert the inverse (that V4 handles all tokenIds without bit 255)
        // because V4 only handles tokenIds that actually exist as minted NFTs
    }
    
    /// @notice Fuzz test: V2 handler should only handle tokenIds with bit 255 set
    function testFuzz_V2HandlerOnlyHandlesHighTokenIds(uint256 tokenId) public view {
        bool hasBit255 = (tokenId & BIT_255_MASK) != 0;
        bool v2Handles = v2Handler.handlesTokenId(tokenId);
        
        if (!hasBit255) {
            // V2 should never handle tokenIds without bit 255 set
            assertFalse(v2Handles, "V2 handler should not handle tokenIds without bit 255 set");
        }
        // Note: V2 only handles tokenIds that exist in its mapping, so we can't assert
        // that it handles ALL tokenIds with bit 255 set
    }
    
    /// @notice Fuzz test: No tokenId should be handled by both handlers
    function testFuzz_NoTokenIdHandledByBoth(uint256 tokenId) public {
        // The critical invariant we're testing: handlers have mutually exclusive tokenId ranges
        bool hasBit255 = (tokenId & BIT_255_MASK) != 0;
        
        if (!hasBit255) {
            // For V4 range (bit 255 = 0), only test with reasonable tokenIds
            // Bound to a reasonable range to avoid gas issues
            tokenId = bound(tokenId, 0, 10000);
            
            // Only mint if tokenId is non-zero and reasonable
            if (tokenId > 0 && tokenId < 100) {
                // Mint NFTs up to this tokenId
                while (mockPositionManager.nextTokenId() <= tokenId) {
                    mockPositionManager.mint(address(this));
                }
            }
        }
        
        bool v4Handles = v4Handler.handlesTokenId(tokenId);
        bool v2Handles = v2Handler.handlesTokenId(tokenId);
        
        // The critical invariant: no tokenId is handled by both
        assertFalse(v4Handles && v2Handles, "TokenId should not be handled by both handlers");
        
        // Additional checks based on bit 255
        if (hasBit255) {
            // TokenIds with bit 255 set should never be handled by V4
            assertFalse(v4Handles, "V4 should not handle tokenIds with bit 255 set");
        } else {
            // TokenIds without bit 255 set should never be handled by V2
            assertFalse(v2Handles, "V2 should not handle tokenIds without bit 255 set");
        }
    }
    
    /// @notice Fuzz test: getHandler should work correctly for any valid tokenId
    function testFuzz_GetHandlerConsistency(uint256 seed) public {
        // Generate different types of tokenIds based on seed
        uint256 tokenIdType = seed % 3;
        uint256 tokenId;
        
        if (tokenIdType == 0) {
            // Test with V4 tokenId
            tokenId = bound(seed, 1, 10000);
            // Mint the NFT
            while (mockPositionManager.nextTokenId() <= tokenId) {
                mockPositionManager.mint(address(this));
            }
            
            IPositionHandler handler = adapter.getHandler(tokenId);
            assertEq(address(handler), address(v4Handler), "Should return V4 handler for V4 tokenId");
            
        } else if (tokenIdType == 1) {
            // Test with V2 tokenId
            PoolKey memory mockPoolKey = PoolKey({
                currency0: Currency.wrap(address(uint160(seed % 1000000))),
                currency1: Currency.wrap(address(uint160((seed >> 8) % 1000000) + 1000000)),
                fee: uint24(bound(seed >> 16, 100, 10000)),
                tickSpacing: 1,
                hooks: IHooks(address(mockV2Hook))
            });
            
            address user = address(uint160(bound(seed >> 32, 1, type(uint160).max)));
            
            // Seed slot0 then call handler as hook
            vm.prank(address(mockV2Hook));
            mockPoolManager.setPoolSlot0(bytes32(PoolId.unwrap(mockPoolKey.toId())), TickMath.getSqrtPriceAtTick(0), 0);
            vm.prank(address(mockV2Hook));
            v2Handler.notifyAddLiquidity(mockPoolKey, user, 1000);
            tokenId = v2Handler.v2TokenIds(mockPoolKey.toId(), user);
            
            IPositionHandler handler = adapter.getHandler(tokenId);
            assertEq(address(handler), address(v2Handler), "Should return V2 handler for V2 tokenId");
            
        } else {
            // Test with non-existent tokenId
            tokenId = V2_TOKEN_PREFIX | (seed % 1000000000);
            vm.expectRevert(DeliErrors.HandlerNotFound.selector);
            adapter.getHandler(tokenId);
        }
    }
    
    /// @notice Fuzz test: V2 position creation always produces valid high tokenIds
    function testFuzz_V2PositionCreationAlwaysHighTokenIds(
        address user,
        uint128 liquidity,
        uint24 fee,
        address currency0,
        address currency1
    ) public {
        // Bound inputs to reasonable values
        vm.assume(user != address(0));
        vm.assume(liquidity > 0);
        fee = uint24(bound(fee, 100, 10000));
        vm.assume(currency0 != address(0) && currency1 != address(0));
        vm.assume(currency0 != currency1);
        
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: 1,
            hooks: IHooks(address(mockV2Hook))
        });
        
        // Seed slot0 then call handler as hook
        vm.prank(address(mockV2Hook));
        mockPoolManager.setPoolSlot0(bytes32(PoolId.unwrap(poolKey.toId())), TickMath.getSqrtPriceAtTick(0), 0);
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(poolKey, user, liquidity);
        uint256 tokenId = v2Handler.v2TokenIds(poolKey.toId(), user);
        
        // Verify the tokenId has bit 255 set
        assertTrue((tokenId & BIT_255_MASK) != 0, "V2 tokenId should have bit 255 set");
        
        // Verify V2 handler handles it
        assertTrue(v2Handler.handlesTokenId(tokenId), "V2 handler should handle its own tokenId");
        
        // Verify V4 handler doesn't handle it
        assertFalse(v4Handler.handlesTokenId(tokenId), "V4 handler should not handle V2 tokenId");
    }
}