// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "src/DeliHook.sol";
import "src/FeeProcessor.sol";
import "src/DailyEpochGauge.sol";
import "src/PositionManagerAdapter.sol";
import "src/handlers/V4PositionHandler.sol";
import "src/IncentiveGauge.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";

contract Token is ERC20 { constructor(string memory s) ERC20(s,s) { _mint(msg.sender,1e24);} }

contract GaugeStream_IT is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // core contracts
    DeliHook hook;
    FeeProcessor fp;
    DailyEpochGauge gauge;
    IncentiveGauge inc;
    PositionManagerAdapter adapter;
    V4PositionHandler v4Handler;

    // tokens
    Token wblt;
    Token bmx;

    // helpers
    PoolKey key;
    PoolId pid;

    uint256 wideTokenId;

    function setUp() public {
        // 1. Deploy Uniswap artefacts
        deployArtifacts();

        // 2. Deploy tokens via helper (MockERC20)
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = Token(address(bmxToken));
        wblt = Token(address(wbltToken));

        // approvals
        wblt.approve(address(poolManager), type(uint256).max);
        bmx.approve(address(poolManager), type(uint256).max);

        // 3. Precompute hook address
        bytes memory ctorArgs = abi.encode(poolManager, IFeeProcessor(address(0)), IDailyEpochGauge(address(0)), IIncentiveGauge(address(0)), address(wblt), address(bmx), address(this));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address expectedHook, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);

        // 4. Deploy mock incentive gauge first
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), expectedHook);

        // 5. Deploy DailyEpochGauge and FeeProcessor
        gauge = new DailyEpochGauge(
            address(0),
            poolManager,
            IPositionManagerAdapter(address(0)),
            expectedHook,
            IERC20(address(bmx)),
            address(inc)
        );
        fp = new FeeProcessor(poolManager, expectedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), address(0xDEAD));

        // Deploy PositionManagerAdapter and V4PositionHandler
        adapter = new PositionManagerAdapter(address(gauge), address(inc));
        v4Handler = new V4PositionHandler(address(positionManager));
        
        // Register V4 handler and wire up the adapter
        adapter.addHandler(address(v4Handler));
        adapter.setAuthorizedCaller(address(positionManager), true);
        adapter.setPositionManager(address(positionManager));
        
        // Update gauges to use the adapter
        gauge.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));

        // 6. Deploy hook
        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)), // placeholder to preserve precomputed address
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );

        // Wire up actual contract references post-deployment
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        // Configure dummy incentive gauge so hook beforeInitialize passes.
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // 7. Initialise pool
        key = PoolKey({currency0: Currency.wrap(address(bmx)), currency1: Currency.wrap(address(wblt)), fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))});
        pid = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // 8. Add liquidity via EasyPosm and subscribe to PositionManagerAdapter
        (wideTokenId,) = EasyPosm.mint(positionManager, key, -60000, 60000, 1e21, type(uint256).max, type(uint256).max, address(this), block.timestamp + 1 hours, bytes(""));
        positionManager.subscribe(wideTokenId, address(adapter), bytes(""));

        // 9. Fund gauge with BMX tokens used for streaming
        uint256 bucket = 1000 ether;
        bmx.transfer(address(gauge), bucket);
        // Simulate fee processor adding rewards to bucket
        vm.prank(address(fp));
        gauge.addRewards(pid, bucket);
    }

    function testStreamingAndClaim() public {
        // Day 0: bucket filled, streamRate = 0
        gauge.rollIfNeeded(pid);

        // Move two days forward to activate stream
        (, uint64 end0,,,) = gauge.epochInfo(pid);
        vm.warp(end0 + 2 days);
        gauge.rollIfNeeded(pid); // streamRate now bucket/86400

        uint256 rate = gauge.streamRate(pid);
        assertGt(rate, 0, "stream not active");

        // Advance another 12 hours and poke pool so accumulator updates
        vm.warp(block.timestamp + 12 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // Prepare claim
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 preBal = bmx.balanceOf(address(this));
        gauge.claimAllForOwner(arr, address(this));
        uint256 claimed = bmx.balanceOf(address(this)) - preBal;

        // Expect claimed roughly = rate * 12h (tolerance 1e16)
        uint256 expected = rate * 12 hours;
        assertApproxEqAbs(claimed, expected, 1e16);
    }

    /// @notice Verifies correct streamRate pipeline and accrual over multiple epoch rolls.
    function testMultiDayStreaming() public {
        // Initialise Day 0 epoch (bucket filled, streamRate = 0)
        gauge.rollIfNeeded(pid);

        (, uint64 day0End,,, ) = gauge.epochInfo(pid);

        // ---------------------------------------------------------------------
        // Day 1: streamRate should still be 0, nextStreamRate should be set
        // ---------------------------------------------------------------------
        vm.warp(uint256(day0End) + 1); // jump just into Day1
        gauge.rollIfNeeded(pid);

        (,, uint128 srDay1, uint128 nextSrDay1, uint128 queuedSrDay1) = gauge.epochInfo(pid);
        assertEq(srDay1, 0, "Day1 streamRate should be zero");
        assertEq(nextSrDay1, 0, "nextStreamRate should still be zero on Day1");
        assertGt(queuedSrDay1, 0, "queuedStreamRate not populated");

        // Expected per-second rate is bucket/86400 captured in queuedSrDay1.
        uint256 expectedRate = uint256(queuedSrDay1);

        // ---------------------------------------------------------------------
        // Day 2: streamRate should equal previous nextStreamRate
        // ---------------------------------------------------------------------
        vm.warp(uint256(day0End) + 1 days + 1);
        gauge.rollIfNeeded(pid);

        (,, uint128 srDay2, uint128 nextSrDay2,) = gauge.epochInfo(pid);
        // Day2 still no streaming; nextStreamRate should now equal previous queued rate
        assertEq(srDay2, 0, "Day2 streamRate should still be zero");
        assertApproxEqAbs(nextSrDay2, expectedRate, 1, "Day2 nextStreamRate mismatch");

        // ---------------------------------------------------------------------
        // Day 3: after another roll streaming becomes active
        // ---------------------------------------------------------------------
        vm.warp(uint256(day0End) + 2 days);
        gauge.rollIfNeeded(pid);

        uint256 srDay3 = gauge.streamRate(pid);
        assertApproxEqAbs(srDay3, expectedRate, 1, "Day3 streamRate mismatch");

        // Advance 6 hours into Day3 for accrual
        uint256 dt = 6 hours;
        vm.warp(block.timestamp + dt);
        vm.prank(address(hook));
        gauge.pokePool(key);

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 balBefore = bmx.balanceOf(address(this));
        gauge.claimAllForOwner(arr, address(this));
        uint256 claimed = bmx.balanceOf(address(this)) - balBefore;

        uint256 expected = srDay3 * dt;
        assertApproxEqAbs(claimed, expected, 1e16, "multi-day claim mismatch");

        return;
    }

    /// @notice Ensures liquidity that is entirely out-of-range earns zero rewards.
    function testOutOfRangeNoRewards() public {
        // Mint a position well above the current price so it is out-of-range.
        // Choose ticks well above current price (tick 0) and multiples of 60
        int24 tickLower = 3600; // divisible by 60
        int24 tickUpper = 4200; // divisible by 60 and > tickLower
        uint256 liq = 1e21;

        uint256 tokenIdOut;
        (tokenIdOut,) = EasyPosm.mint(
            positionManager,
            key,
            tickLower,
            tickUpper,
            liq,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );

        // Subscribe to the gauge so accounting starts.
        positionManager.subscribe(tokenIdOut, address(adapter), bytes(""));

        // Fast-forward to when streaming is active (reuse Day3 logic).
        gauge.rollIfNeeded(pid);
        (, uint64 day0End,,, ) = gauge.epochInfo(pid);
        // Roll Day1, Day2, Day3
        vm.warp(uint256(day0End) + 2 days);
        gauge.rollIfNeeded(pid); // Day2 roll (still no stream)
        vm.warp(block.timestamp + 1 days);
        gauge.rollIfNeeded(pid); // Day3 roll – stream active

        // Advance 4 hours into Day3 and poke accumulator
        vm.warp(block.timestamp + 4 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // Compute posKey for out-of-range position
        bytes32 posKey = keccak256(
            abi.encode(address(this), tickLower, tickUpper, bytes32(tokenIdOut), pid)
        );

        uint256 pending = gauge.pendingRewards(posKey, uint128(liq), pid);
        assertEq(pending, 0, "out-of-range position accrued rewards");
    }

    /// @notice Narrower range position should accrue more rewards than wider range for same notional.
    function testNarrowEarnsMore() public {
        // 1. Mint two positions with the SAME token budget but different ranges.
        // Wide position already minted in setUp (ticks ±60000).

        // Narrow: ±600 ticks around spot.
        int24 tickLower = -600;
        int24 tickUpper = 600;

        // Token budget (same for both mints): 1e21 of each token.
        uint128 budget0 = 1e21;
        uint128 budget1 = 1e21;

        uint256 tokenIdNarrow;
        (tokenIdNarrow,) = EasyPosm.mint(
            positionManager,
            key,
            tickLower,
            tickUpper,
            1e22, // large liquidity target within safe range
            budget0,
            budget1,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenIdNarrow, address(adapter), bytes(""));

        // 2. Advance until streamRate becomes non-zero
        gauge.rollIfNeeded(pid);
        while (gauge.streamRate(pid) == 0) {
            vm.warp(block.timestamp + 1 days);
            gauge.rollIfNeeded(pid);
        }

        // 3. Move 3 hours into the active streaming day and poke accumulator
        vm.warp(block.timestamp + 3 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // 4. Fetch pending rewards for both positions
        uint128 liqWide = positionManager.getPositionLiquidity(wideTokenId);
        uint128 liqNarrow = positionManager.getPositionLiquidity(tokenIdNarrow);

        bytes32 posWide = keccak256(
            abi.encode(address(this), int24(-60000), int24(60000), bytes32(wideTokenId), pid)
        );
        bytes32 posNarrow = keccak256(
            abi.encode(address(this), tickLower, tickUpper, bytes32(tokenIdNarrow), pid)
        );

        uint256 pendingWide = gauge.pendingRewards(posWide, liqWide, pid);
        uint256 pendingNarrow = gauge.pendingRewards(posNarrow, liqNarrow, pid);

        // Sanity: confirm narrow position minted MORE liquidity units with same budget
        assertGt(liqNarrow, liqWide, "narrow position did not mint more liquidity units");
        // Higher liquidity should translate to higher pending rewards
        assertGt(pendingNarrow, pendingWide, "narrow range did not earn more");
    }
} 