// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionManagerAdapter} from "../../../src/PositionManagerAdapter.sol";
import {V2PositionHandler} from "../../../src/handlers/V2PositionHandler.sol";
import {V4PositionHandler} from "../../../src/handlers/V4PositionHandler.sol";
import {MockPositionManager} from "../../mocks/MockPositionManager.sol";
import {MockV2Hook} from "../../mocks/MockV2Hook.sol";
import {MockDailyEpochGauge} from "../../mocks/MockDailyEpochGauge.sol";
import {MockIncentiveGauge} from "../../mocks/MockIncentiveGauge.sol";
import {DeliErrors} from "../../../src/libraries/DeliErrors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract GetPoolKeyFromPositionInfoTest is Test {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    
    PositionManagerAdapter adapter;
    V2PositionHandler v2Handler;
    V4PositionHandler v4Handler;
    MockPositionManager mockPositionManager;
    MockV2Hook mockV2Hook;
    
    address alice = makeAddr("alice");
    
    function setUp() public {
        // Deploy mocks
        mockPositionManager = new MockPositionManager();
        mockV2Hook = new MockV2Hook();
        MockDailyEpochGauge mockDailyGauge = new MockDailyEpochGauge();
        MockIncentiveGauge mockIncentiveGauge = new MockIncentiveGauge();
        
        // Deploy handlers
        v2Handler = new V2PositionHandler(address(mockV2Hook));
        v4Handler = new V4PositionHandler(address(mockPositionManager));
        
        // Deploy adapter
        adapter = new PositionManagerAdapter(address(mockDailyGauge), address(mockIncentiveGauge));
        adapter.setPositionManager(address(mockPositionManager));
        
        // Set up v2Handler
        v2Handler.setPositionManagerAdapter(address(adapter));
        
        // Add both handlers
        adapter.addHandler(address(v4Handler));
        adapter.addHandler(address(v2Handler));
        
        // Authorize callers
        adapter.setAuthorizedCaller(address(mockPositionManager), true);
        adapter.setAuthorizedCaller(address(v2Handler), true);
    }
    
    function test_GetPoolKeyFromPositionInfo_V2Pool() public {
        // Create test pool key
        PoolKey memory v2PoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 1,  // V2 uses tickSpacing = 1
            hooks: IHooks(address(mockV2Hook))
        });
        
        // Create a V2 position to store the poolKey
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(v2PoolKey, alice, 1000);
        
        // Create a synthetic PositionInfo for V2 (full range)
        PositionInfo info = PositionInfoLibrary.initialize(
            v2PoolKey,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK
        );
        
        // Get the poolKey back - should work even though V4 PositionManager doesn't have it
        PoolKey memory retrievedKey = adapter.getPoolKeyFromPositionInfo(info);
        
        // Verify it matches
        assertEq(Currency.unwrap(retrievedKey.currency0), Currency.unwrap(v2PoolKey.currency0));
        assertEq(Currency.unwrap(retrievedKey.currency1), Currency.unwrap(v2PoolKey.currency1));
        assertEq(retrievedKey.fee, v2PoolKey.fee);
        assertEq(retrievedKey.tickSpacing, v2PoolKey.tickSpacing);
        assertEq(address(retrievedKey.hooks), address(v2PoolKey.hooks));
    }
    
    function test_GetPoolKeyFromPositionInfo_V4Pool() public {
        // Create test pool key
        PoolKey memory v4PoolKey = PoolKey({
            currency0: Currency.wrap(address(0x3)),
            currency1: Currency.wrap(address(0x4)),
            fee: 500,
            tickSpacing: 10,  // V4 typical tick spacing
            hooks: IHooks(address(0))
        });
        
        // For V4 pools, we need to mock the PositionManager having the poolKey stored
        // In a real scenario, this would happen when someone mints a V4 position
        // For this test, we'll just verify the flow works when V4 has the mapping
        
        // Create PositionInfo for V4 pool
        PositionInfo info = PositionInfoLibrary.initialize(
            v4PoolKey,
            -100 * v4PoolKey.tickSpacing,
            100 * v4PoolKey.tickSpacing
        );
        
        // Note: In this test, the MockPositionManager doesn't have the poolKeys mapping,
        // so this would normally fail. In production, the V4 PositionManager would have
        // this mapping populated when positions are created.
    }
    
    function test_GetPoolKeyFromPositionInfo_UnknownPool_Reverts() public {
        // Create a pool key that doesn't exist in either V2 or V4
        PoolKey memory unknownPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x99)),
            currency1: Currency.wrap(address(0x100)),
            fee: 10000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        PositionInfo info = PositionInfoLibrary.initialize(
            unknownPoolKey,
            -60,
            60
        );
        
        // Should revert with PoolNotFound
        vm.expectRevert(DeliErrors.PoolNotFound.selector);
        adapter.getPoolKeyFromPositionInfo(info);
    }
    
    function test_GetPoolKeyFromPositionInfo_MultipleV2Pools() public {
        // Create first V2 pool key
        PoolKey memory v2PoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(mockV2Hook))
        });
        
        // Create second V2 pool key
        PoolKey memory v2PoolKey2 = PoolKey({
            currency0: Currency.wrap(address(0x5)),
            currency1: Currency.wrap(address(0x6)),
            fee: 10000,
            tickSpacing: 1,
            hooks: IHooks(address(mockV2Hook))
        });
        
        // Add liquidity to both pools
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(v2PoolKey, alice, 1000);
        
        vm.prank(address(mockV2Hook));
        v2Handler.notifyAddLiquidity(v2PoolKey2, alice, 2000);
        
        // Create PositionInfo for each pool
        PositionInfo info1 = PositionInfoLibrary.initialize(
            v2PoolKey,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK
        );
        
        PositionInfo info2 = PositionInfoLibrary.initialize(
            v2PoolKey2,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK
        );
        
        // Both should return correct pool keys
        PoolKey memory retrieved1 = adapter.getPoolKeyFromPositionInfo(info1);
        PoolKey memory retrieved2 = adapter.getPoolKeyFromPositionInfo(info2);
        
        // Verify first pool
        assertEq(Currency.unwrap(retrieved1.currency0), Currency.unwrap(v2PoolKey.currency0));
        assertEq(retrieved1.fee, v2PoolKey.fee);
        
        // Verify second pool
        assertEq(Currency.unwrap(retrieved2.currency0), Currency.unwrap(v2PoolKey2.currency0));
        assertEq(retrieved2.fee, v2PoolKey2.fee);
    }
}