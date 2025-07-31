// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";

/// @notice Tests V2 liquidity lifecycle: mint, burn, and synthetic position handling
contract LiquidityLifecycle_V2_IT is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // contracts
    DeliHookConstantProduct hook;
    V2PositionHandler v2Handler;
    PositionManagerAdapter adapter;
    DailyEpochGauge gauge;
    IncentiveGauge inc;
    FeeProcessor fp;

    // tokens
    IERC20 wblt;
    IERC20 bmx;

    // pool
    PoolKey key;
    PoolId pid;

    // test users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployArtifacts();

        // Deploy tokens
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(bmxToken));
        wblt = IERC20(address(wbltToken));

        // Deploy hook with proper flags
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx)
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        (address predictedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DeliHookConstantProduct).creationCode, ctorArgs);

        // Deploy gauges first
        gauge = new DailyEpochGauge(
            address(0),
            poolManager,
            IPositionManagerAdapter(address(0)), // Temporary, will update
            predictedHook,
            IERC20(address(bmx)),
            address(0)
        );
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), predictedHook); // Temporary
        fp = new FeeProcessor(
            poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), address(0xDEAD)
        );

        // Now deploy adapter with correct addresses
        adapter = new PositionManagerAdapter(address(gauge), address(inc));
        
        // Update gauges with adapter
        gauge.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));

        // Deploy hook
        hook = new DeliHookConstantProduct{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx)
        );
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // Deploy V2 handler and register
        v2Handler = new V2PositionHandler(address(hook));
        adapter.addHandler(address(v2Handler));
        adapter.setAuthorizedCaller(address(hook), true);
        hook.setV2PositionHandler(address(v2Handler));

        // Initialize pool
        key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Setup test users
        deal(address(bmx), alice, 1000 ether);
        deal(address(wblt), alice, 1000 ether);
        deal(address(bmx), bob, 1000 ether);
        deal(address(wblt), bob, 1000 ether);

        vm.startPrank(alice);
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           FIRST LIQUIDITY MINT
    //////////////////////////////////////////////////////////////*/

    function testFirstMint() public {
        // Alice provides first liquidity
        vm.startPrank(alice);
        
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        vm.stopPrank();

        // Check state
        (uint128 r0, uint128 r1) = hook.getReserves(pid);
        assertEq(r0, 10 ether, "Reserve0 mismatch");
        assertEq(r1, 10 ether, "Reserve1 mismatch");

        uint256 totalSupply = hook.getTotalSupply(pid);
        uint256 aliceShares = hook.balanceOf(pid, alice);
        
        // First mint: shares = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
        uint256 expectedShares = sqrt(10 ether * 10 ether) - 1000;
        assertEq(aliceShares, expectedShares, "Alice shares mismatch");
        assertEq(totalSupply, expectedShares + 1000, "Total supply mismatch");

        // Verify MINIMUM_LIQUIDITY locked
        assertEq(hook.balanceOf(pid, address(0)), 1000, "Min liquidity not locked");
    }

    /*//////////////////////////////////////////////////////////////
                        PROPORTIONAL LIQUIDITY ADD
    //////////////////////////////////////////////////////////////*/

    function testProportionalAdd() public {
        // Alice provides initial liquidity
        vm.prank(alice);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        uint256 aliceSharesBefore = hook.balanceOf(pid, alice);
        
        // Bob adds proportional liquidity
        vm.startPrank(bob);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 50 ether,
                amount1Desired: 50 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        vm.stopPrank();

        // Check Bob got proportional shares
        uint256 bobShares = hook.balanceOf(pid, bob);
        assertApproxEqRel(bobShares, aliceSharesBefore / 2, 0.01e18, "Bob should get ~50% of Alice's shares");

        // Verify reserves updated correctly
        (uint128 r0, uint128 r1) = hook.getReserves(pid);
        assertEq(r0, 150 ether, "Reserve0 should be 150");
        assertEq(r1, 150 ether, "Reserve1 should be 150");
    }

    /*//////////////////////////////////////////////////////////////
                      NON-PROPORTIONAL LIQUIDITY ADD
    //////////////////////////////////////////////////////////////*/

    function testNonProportionalAdd() public {
        // Initial liquidity
        vm.prank(alice);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 200 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Bob tries to add with different ratio
        vm.startPrank(bob);
        
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        vm.stopPrank();

        // Bob should have added 50 BMX and 100 wBLT (maintaining pool ratio 1:2)
        uint256 bobBmx = bmx.balanceOf(bob);
        uint256 bobWblt = wblt.balanceOf(bob);
        
        assertEq(bobBmx, 950 ether, "Bob should have 950 BMX left");
        assertEq(bobWblt, 900 ether, "Bob should have 900 wBLT left");

        // Verify reserves maintain ratio
        (uint128 r0, uint128 r1) = hook.getReserves(pid);
        assertEq(r0, 150 ether, "Reserve0 should be 150");
        assertEq(r1, 300 ether, "Reserve1 should be 300");
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY REMOVAL
    //////////////////////////////////////////////////////////////*/

    function testRemoveLiquidity() public {
        // Setup: Alice adds liquidity
        vm.prank(alice);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        uint256 aliceShares = hook.balanceOf(pid, alice);
        uint256 aliceBmxBefore = bmx.balanceOf(alice);
        uint256 aliceWbltBefore = wblt.balanceOf(alice);

        // Alice removes half her liquidity
        vm.prank(alice);
        hook.removeLiquidity(
            key,
            MultiPoolCustomCurve.RemoveLiquidityParams({
                liquidity: aliceShares / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Verify Alice received tokens
        uint256 bmxReceived = bmx.balanceOf(alice) - aliceBmxBefore;
        uint256 wbltReceived = wblt.balanceOf(alice) - aliceWbltBefore;
        
        assertApproxEqAbs(bmxReceived, 50 ether, 1000, "Should receive ~50 BMX");
        assertApproxEqAbs(wbltReceived, 50 ether, 1000, "Should receive ~50 wBLT");

        // Verify shares burned
        assertEq(hook.balanceOf(pid, alice), aliceShares / 2, "Half shares should remain");

        // Verify reserves updated
        (uint128 r0, uint128 r1) = hook.getReserves(pid);
        assertApproxEqAbs(r0, 50 ether, 1000, "Reserve0 should be ~50");
        assertApproxEqAbs(r1, 50 ether, 1000, "Reserve1 should be ~50");
    }

    /*//////////////////////////////////////////////////////////////
                    V2 POSITION HANDLER INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function testV2PositionHandlerIntegration() public {
        // Alice adds liquidity - should auto-subscribe to gauges
        vm.startPrank(alice);
        
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        vm.stopPrank();

        // Check synthetic tokenId created
        uint256 tokenId = v2Handler.v2TokenIds(pid, alice);
        assertGt(tokenId, 0, "TokenId should be created");

        // Bob adds liquidity
        vm.prank(bob);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 50 ether,
                amount1Desired: 50 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Verify Bob gets different tokenId
        uint256 bobTokenId = v2Handler.v2TokenIds(pid, bob);
        assertGt(bobTokenId, 0, "Bob should have tokenId");
        assertNotEq(bobTokenId, tokenId, "Bob should have different tokenId");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function testMinimumLiquidityEnforcement() public {
        // Try to add tiny liquidity that would mint 0 shares
        vm.startPrank(alice);
        
        vm.expectRevert(stdError.arithmeticError);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        vm.stopPrank();
    }

    function testRemoveAllLiquidity() public {
        // Alice adds liquidity
        vm.prank(alice);
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        uint256 aliceShares = hook.balanceOf(pid, alice);

        // Remove all liquidity
        vm.prank(alice);
        hook.removeLiquidity(
            key,
            MultiPoolCustomCurve.RemoveLiquidityParams({
                liquidity: aliceShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Alice should have no shares
        assertEq(hook.balanceOf(pid, alice), 0, "Alice should have no shares");

        // Only MINIMUM_LIQUIDITY should remain
        assertEq(hook.getTotalSupply(pid), 1000, "Only min liquidity should remain");

        // Position should be removed from V2PositionHandler
        uint256 removedTokenId = v2Handler.v2TokenIds(pid, alice);
        // After removal, tokenId should be 0
        assertEq(removedTokenId, 0, "TokenId should be cleared after full removal");
    }

    // Helper function
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}