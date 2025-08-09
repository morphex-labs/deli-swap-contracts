// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Deployers} from "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {IPositionHandler} from "src/interfaces/IPositionHandler.sol";
import {FeeProcessor} from "src/FeeProcessor.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {TimeLibrary} from "src/libraries/TimeLibrary.sol";

contract Token is ERC20 {
    constructor(string memory s) ERC20(s, s) {
        _mint(msg.sender, 1e24);
    }
}

/// @title GaugeStream_V2Curve_IT
/// @notice Integration tests for DailyEpochGauge & IncentiveGauge streaming while using
///         the constant-product DeliHookConstantProduct. Tests V2 liquidity positions
///         accruing rewards through the gauge system.
contract GaugeStream_V2Curve_IT is Test, Deployers, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // contracts
    DeliHookConstantProduct hook;
    DailyEpochGauge gauge;
    IncentiveGauge inc;
    PositionManagerAdapter adapter;
    V2PositionHandler v2Handler;
    FeeProcessor fp;

    // tokens
    Token wblt;
    Token bmx;

    // helpers
    PoolKey key;
    PoolId pid;

    uint256 posA; // V2 synthetic tokenId for position A
    uint256 posB; // V2 synthetic tokenId for position B
    
    address alice = address(0xAA);
    address bob = address(0xBB);

    function setUp() public {
        // 1. core Uniswap stack
        deployArtifacts();

        // 2. tokens
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = Token(address(bmxToken));
        wblt = Token(address(wbltToken));

        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);

        // 3. pre-compute hook address for wiring gauges
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        (address predictedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DeliHookConstantProduct).creationCode, ctorArgs);

        // 4. deploy hook
        hook = new DeliHookConstantProduct{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );

        // 5. deploy gauges & fee processor, wire contracts
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), predictedHook);
        gauge = new DailyEpochGauge(
            address(0),
            poolManager,
            IPositionManagerAdapter(address(0)),
            predictedHook,
            IERC20(address(bmx)),
            address(inc)
        );
        fp = new FeeProcessor(
            poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), address(0xDEAD)
        );

        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));
        
        // Deploy PositionManagerAdapter and V2PositionHandler
        adapter = new PositionManagerAdapter(address(gauge), address(inc), address(positionManager), address(poolManager));
        v2Handler = new V2PositionHandler(address(hook));
        
        // Register V2 handler and wire up the adapter
        adapter.addHandler(address(v2Handler));
        adapter.setAuthorizedCaller(address(hook), true);
        adapter.setAuthorizedCaller(address(v2Handler), true); // V2Handler needs to call adapter
        adapter.setAuthorizedCaller(address(positionManager), true); // allow PM calls if any
        
        // Set the V2 handler in the hook
        hook.setV2PositionHandler(address(v2Handler));
        
        // Set the adapter in the V2 handler so it can auto-subscribe positions
        v2Handler.setPositionManagerAdapter(address(adapter));
        
        // Update gauges to use the adapter
        gauge.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));

        // 6. pool init & add two identical full-range LPs
        key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        
        // Verify gauge pool was initialized
        (uint256 streamRate,,) = gauge.getPoolData(pid);
        require(streamRate == 0, "Stream rate should be 0 after init");
        
        console2.log("=== Before adding positions ===");

        // Add V2 liquidity for two different users
        // First, mint tokens to alice and bob
        bmx.transfer(alice, 1e24);
        wblt.transfer(alice, 1e24);
        bmx.transfer(bob, 1e24);
        wblt.transfer(bob, 1e24);
        
        // Alice adds liquidity
        vm.startPrank(alice);
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 1e22,
                amount1Desired: 1e22,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        posA = v2Handler.v2TokenIds(pid, alice); // Get the synthetic tokenId for alice
        require(posA != 0, "Alice position not created");
        
        // Check if adapter can find the handler for this position
        IPositionHandler handler = adapter.getHandler(posA);
        require(address(handler) == address(v2Handler), "Wrong handler for posA");
        
        vm.stopPrank();
        
        // Bob adds liquidity
        vm.startPrank(bob);
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        
        hook.addLiquidity(
            key,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 1e22,
                amount1Desired: 1e22,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        posB = v2Handler.v2TokenIds(pid, bob); // Get the synthetic tokenId for bob
        require(posB != 0, "Bob position not created");
        vm.stopPrank();
        
        console2.log("=== After adding positions ===");
        // Check pool data after positions are added
        (uint256 sr2, uint256 rpl2, uint128 liq2) = gauge.getPoolData(pid);
        console2.log("After positions - streamRate:", sr2);
        console2.log("After positions - rpl:", rpl2);
        console2.log("After positions - liquidity:", liq2);

        // 7. fund gauges
        uint256 bucket = 1000 ether;
        bmx.transfer(address(gauge), bucket);
        vm.prank(address(fp));
        gauge.addRewards(pid, bucket);
    }

    /*//////////////////////////////////////////////////////////////
                       Helper to activate stream
    //////////////////////////////////////////////////////////////*/
    function _activateStream() internal {
        // Day 0 info (bucket queued, streamRate 0)
        uint256 end0 = TimeLibrary.dayNext(block.timestamp);
        // fast-forward to Day2 so streamRate becomes active
        vm.warp(uint256(end0) + 1 days + 1);
        require(gauge.streamRate(pid) > 0, "stream inactive");
        // Anchor accumulator at activation to avoid drift in expectations
        vm.prank(address(hook));
        gauge.pokePool(key);
    }

    /*//////////////////////////////////////////////////////////////
                      TESTS – Gauge streaming
    //////////////////////////////////////////////////////////////*/

    function testStreamingAndClaim() public {
        _activateStream();

        // Verify positions exist in handler
        require(v2Handler.handlesTokenId(posA), "V2Handler doesn't handle posA");
        require(v2Handler.handlesTokenId(posB), "V2Handler doesn't handle posB");
        
        // advance 12h and poke so accumulator updates
        vm.warp(block.timestamp + 12 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        uint256 rate = gauge.streamRate(pid);
        uint256 expected = rate * 12 hours / 2; // divided by 2 because alice has half the liquidity

        // Check pool data
        (uint256 currentStreamRate, uint256 rewardsPerLiquidityX128, uint128 activeLiquidity) = gauge.getPoolData(pid);
        console2.log("After poke - streamRate:", currentStreamRate);
        console2.log("After poke - rpl:", rewardsPerLiquidityX128);
        console2.log("After poke - liquidity:", activeLiquidity);
        require(currentStreamRate > 0, "No stream rate");
        require(rewardsPerLiquidityX128 > 0, "No rewards accumulated");
        require(activeLiquidity > 0, "No active liquidity");
        
        // Check if Alice has pending rewards before claiming
        uint256 pendingA = gauge.pendingRewardsByTokenId(posA);
        require(pendingA > 0, "No pending rewards for Alice");

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 pre = bmx.balanceOf(alice);
        gauge.claimAllForOwner(arr, alice);
        uint256 claimed = bmx.balanceOf(alice) - pre;

        assertApproxEqAbs(claimed, expected, 1e16);
    }

    /// @notice Verifies correct streamRate pipeline and accrual over multiple epoch rolls.
    function testMultiDayStreaming() public {
        // Day0 – epoch (bucket queued, streamRate = 0)
        uint256 day0End = TimeLibrary.dayNext(block.timestamp);

        // --------------------------------------------------
        // Day1: streamRate still 0
        // --------------------------------------------------
        vm.warp(uint256(day0End) + 1); // just into Day1

        // On Day1, stream rate still 0
        assertEq(gauge.streamRate(pid), 0, "Day1 streamRate should be zero");

        // Expected per-second rate is bucket/86400 which will activate on Day2
        uint256 expectedRate = (1000 ether) / uint256(1 days);

        // --------------------------------------------------
        // Day2: streaming becomes active
        // --------------------------------------------------
        vm.warp(uint256(day0End) + 1 days + 1);

        uint256 srDay2 = gauge.streamRate(pid);
        assertApproxEqAbs(srDay2, expectedRate, 1, "Day2 streamRate mismatch");
    }

    /*//////////////////////////////////////////////////////////////
               PARITY: identical LPs earn identical rewards
    //////////////////////////////////////////////////////////////*/
    function testIdenticalPositionsEarnEqual() public {
        _activateStream();

        // advance 6h and poke once
        vm.warp(block.timestamp + 6 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // Get liquidity from V2PositionHandler synthetic positions
        uint128 liqA = v2Handler.getPositionLiquidity(posA);
        uint128 liqB = v2Handler.getPositionLiquidity(posB);
        // Note: Alice gets slightly less liquidity due to MINIMUM_LIQUIDITY lock on first mint
        assertApproxEqAbs(liqA, liqB, 1000, "liquidity mismatch");

        uint256 pendingA = gauge.pendingRewardsByTokenId(posA);
        uint256 pendingB = gauge.pendingRewardsByTokenId(posB);
        // Rewards should be proportional to liquidity
        // Since liqA is slightly less than liqB, pendingA should be slightly less than pendingB
        assertApproxEqRel(pendingA, pendingB, 0.0001e18, "pending rewards not proportional");
    }
    
    /*//////////////////////////////////////////////////////////////
                          UNLOCK CALLBACK
    //////////////////////////////////////////////////////////////*/
    
    function unlockCallback(bytes calldata) external pure override returns (bytes memory) {
        // This test doesn't need to interact with poolManager.unlock directly
        revert("unexpected unlock");
    }
}
