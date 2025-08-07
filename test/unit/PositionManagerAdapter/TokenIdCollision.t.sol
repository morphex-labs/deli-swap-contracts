// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionManagerAdapter} from "../../../src/PositionManagerAdapter.sol";
import {V2PositionHandler} from "../../../src/handlers/V2PositionHandler.sol";
import {V4PositionHandler} from "../../../src/handlers/V4PositionHandler.sol";
import {IPositionHandler} from "../../../src/interfaces/IPositionHandler.sol";
import {MockPositionManager} from "../../mocks/MockPositionManager.sol";
import {MockV2Hook} from "../../mocks/MockV2Hook.sol";
import {MockDailyEpochGauge} from "../../mocks/MockDailyEpochGauge.sol";
import {MockIncentiveGauge} from "../../mocks/MockIncentiveGauge.sol";
import {DeliErrors} from "../../../src/libraries/DeliErrors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract TokenIdCollisionTest is Test {
    using PoolIdLibrary for PoolKey;
    
    PositionManagerAdapter adapter;
    V2PositionHandler v2Handler;
    V4PositionHandler v4Handler;
    MockPositionManager mockPositionManager;
    MockV2Hook mockV2Hook;
    MockDailyEpochGauge mockDailyGauge;
    MockIncentiveGauge mockIncentiveGauge;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    function setUp() public {
        // Deploy mocks
        mockPositionManager = new MockPositionManager();
        mockV2Hook = new MockV2Hook();
        mockDailyGauge = new MockDailyEpochGauge();
        mockIncentiveGauge = new MockIncentiveGauge();
        
        // Deploy handlers
        v2Handler = new V2PositionHandler(address(mockV2Hook));
        v4Handler = new V4PositionHandler(address(mockPositionManager));
        
        // Deploy adapter
        adapter = new PositionManagerAdapter(address(mockDailyGauge), address(mockIncentiveGauge), address(mockPositionManager));
        
        // Set up v2Handler
        v2Handler.setPositionManagerAdapter(address(adapter));
        
        // Add both handlers - this is the critical test scenario
        adapter.addHandler(address(v4Handler));
        adapter.addHandler(address(v2Handler));
        
        // Authorize the adapter
        adapter.setAuthorizedCaller(address(v2Handler), true);
    }
    
    function test_NoTokenIdCollision() public {
        // Mint V4 positions with low tokenIds (1, 2, 3, etc.)
        uint256 v4TokenId1 = mockPositionManager.mint(alice);
        uint256 v4TokenId2 = mockPositionManager.mint(alice);
        uint256 v4TokenId3 = mockPositionManager.mint(alice);
        
        assertEq(v4TokenId1, 1);
        assertEq(v4TokenId2, 2);
        assertEq(v4TokenId3, 3);
        
        // Create V2 positions - these should have high tokenIds with bit 255 set
        // First we need a mock PoolKey for V2 positions
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(mockV2Hook))
        });
        
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(mockPoolKey, alice, 1000);
        uint256 v2TokenId1 = v2Handler.v2TokenIds(mockPoolKey.toId(), alice);
        
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(mockPoolKey, bob, 2000);
        uint256 v2TokenId2 = v2Handler.v2TokenIds(mockPoolKey.toId(), bob);
        
        // Verify V2 tokenIds have bit 255 set
        assertGt(v2TokenId1, 2**255, "V2 tokenId should have bit 255 set");
        assertGt(v2TokenId2, 2**255, "V2 tokenId should have bit 255 set");
        
        // Verify no collision - each handler should only handle its own tokenIds
        assertEq(v4Handler.handlesTokenId(v4TokenId1), true, "V4 handler should handle V4 tokenId 1");
        assertEq(v4Handler.handlesTokenId(v4TokenId2), true, "V4 handler should handle V4 tokenId 2");
        assertEq(v4Handler.handlesTokenId(v2TokenId1), false, "V4 handler should NOT handle V2 tokenId");
        assertEq(v4Handler.handlesTokenId(v2TokenId2), false, "V4 handler should NOT handle V2 tokenId");
        
        assertEq(v2Handler.handlesTokenId(v2TokenId1), true, "V2 handler should handle V2 tokenId 1");
        assertEq(v2Handler.handlesTokenId(v2TokenId2), true, "V2 handler should handle V2 tokenId 2");
        assertEq(v2Handler.handlesTokenId(v4TokenId1), false, "V2 handler should NOT handle V4 tokenId");
        assertEq(v2Handler.handlesTokenId(v4TokenId2), false, "V2 handler should NOT handle V4 tokenId");
        
        // Test adapter's getHandler returns correct handler for each tokenId
        IPositionHandler handlerForV4_1 = adapter.getHandler(v4TokenId1);
        IPositionHandler handlerForV4_2 = adapter.getHandler(v4TokenId2);
        IPositionHandler handlerForV2_1 = adapter.getHandler(v2TokenId1);
        IPositionHandler handlerForV2_2 = adapter.getHandler(v2TokenId2);
        
        assertEq(address(handlerForV4_1), address(v4Handler), "Should return V4 handler for V4 tokenId");
        assertEq(address(handlerForV4_2), address(v4Handler), "Should return V4 handler for V4 tokenId");
        assertEq(address(handlerForV2_1), address(v2Handler), "Should return V2 handler for V2 tokenId");
        assertEq(address(handlerForV2_2), address(v2Handler), "Should return V2 handler for V2 tokenId");
    }
    
    function test_TokenIdBitPrefix() public {
        // Create a V2 position
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(mockV2Hook))
        });
        
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(mockPoolKey, alice, 1000);
        uint256 v2TokenId = v2Handler.v2TokenIds(mockPoolKey.toId(), alice);
        
        // Verify bit 255 is set
        uint256 bit255Mask = 1 << 255;
        assertEq(v2TokenId & bit255Mask, bit255Mask, "Bit 255 should be set for V2 tokenIds");
        
        // Extract the base tokenId (without prefix)
        uint256 baseId = v2TokenId & ~bit255Mask;
        assertEq(baseId, 1, "First V2 position should have base tokenId 1");
        
        // Create another V2 position
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(mockPoolKey, bob, 2000);
        uint256 v2TokenId2 = v2Handler.v2TokenIds(mockPoolKey.toId(), bob);
        
        uint256 baseId2 = v2TokenId2 & ~bit255Mask;
        assertEq(baseId2, 2, "Second V2 position should have base tokenId 2");
    }
    
    function test_HandlerOrderDoesNotMatter() public {
        // Remove handlers and add them in reverse order
        adapter.removeHandler("V4_POSITION_MANAGER");
        adapter.removeHandler("V2_CONSTANT_PRODUCT");
        
        // Add V2 first, then V4 (opposite of setUp)
        adapter.addHandler(address(v2Handler));
        adapter.addHandler(address(v4Handler));
        
        // Create positions
        uint256 v4TokenId = mockPositionManager.mint(alice);
        
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(mockV2Hook))
        });
        
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(mockPoolKey, alice, 1000);
        uint256 v2TokenId = v2Handler.v2TokenIds(mockPoolKey.toId(), alice);
        
        // Verify correct handler is returned regardless of order
        IPositionHandler handlerForV4 = adapter.getHandler(v4TokenId);
        IPositionHandler handlerForV2 = adapter.getHandler(v2TokenId);
        
        assertEq(address(handlerForV4), address(v4Handler), "Should return V4 handler regardless of order");
        assertEq(address(handlerForV2), address(v2Handler), "Should return V2 handler regardless of order");
    }
    
    function test_RevertOnUnknownTokenId() public {
        // Try to get handler for non-existent tokenId
        uint256 nonExistentLowId = 999;
        uint256 nonExistentHighId = (1 << 255) | 999;
        
        vm.expectRevert(DeliErrors.HandlerNotFound.selector);
        adapter.getHandler(nonExistentLowId);
        
        vm.expectRevert(DeliErrors.HandlerNotFound.selector);
        adapter.getHandler(nonExistentHighId);
    }
}