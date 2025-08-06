// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "src/DeliHook.sol";
import "src/DailyEpochGauge.sol";
import "src/IncentiveGauge.sol";
import "src/PositionManagerAdapter.sol";
import "src/handlers/V4PositionHandler.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {MockFeeProcessor} from "test/mocks/MockFeeProcessor.sol";

contract IncentiveAndDaily_IT is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // contracts
    DeliHook hook;
    DailyEpochGauge daily;
    IncentiveGauge inc;
    PositionManagerAdapter adapter;
    V4PositionHandler v4Handler;

    MockFeeProcessor fp;

    // tokens
    IERC20 wblt;
    IERC20 bmx;
    IERC20 rewardTok;

    PoolKey key;
    PoolId pid;
    uint256 tokenDailyId;
    uint256 tokenIncId;

    function setUp() public {
        /***************************************************
         * 1. Core stack                                  *
         ***************************************************/
        deployArtifacts();

        /***************************************************
         * 2. Tokens                                       *
         ***************************************************/
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 _bmx, MockERC20 _wblt) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(_bmx));
        wblt = IERC20(address(_wblt));

        MockERC20 _rew = new MockERC20("REWARD", "RWT", 18);
        _rew.mint(address(this), 1e24);
        rewardTok = IERC20(address(_rew));

        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);

        /***************************************************
         * 3. Deploy hook, gauges                         *
         ***************************************************/
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx)
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);

        // IncentiveGauge needs hook reference (construct before Daily so Daily can reference it)
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), hookAddr);

        // DailyEpochGauge: set feeProcessor=this so tests can addRewards directly and reference incentive gauge
        daily = new DailyEpochGauge(address(this), poolManager, IPositionManagerAdapter(address(0)), hookAddr, bmx, address(inc));

        // Whitelist reward token
        inc.setWhitelist(rewardTok, true);

        // Deploy hook and a dummy fee processor
        fp = new MockFeeProcessor();

        // Set dummy fee processor so hook requirement passes
        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx)
        );

        // Wire up gauges to hook
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(daily));
        hook.setIncentiveGauge(address(inc));

        /***************************************************
         * 4. Pool setup & liquidity                      *
         ***************************************************/
        key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        pid = key.toId();

        // Mint two positions: one for DailyGauge, one for IncentiveGauge
        (tokenDailyId,) = EasyPosm.mint(positionManager, key, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
        (tokenIncId,)   = EasyPosm.mint(positionManager, key, -30000, 30000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));

        // Deploy PositionManagerAdapter and V4PositionHandler
        adapter = new PositionManagerAdapter(address(daily), address(inc));
        v4Handler = new V4PositionHandler(address(positionManager));
        
        // Register V4 handler and wire up the adapter
        adapter.addHandler(address(v4Handler));
        adapter.setAuthorizedCaller(address(positionManager), true);
        adapter.setPositionManager(address(positionManager));
        
        // Update gauges to use the adapter
        daily.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));

        // Subscribe positions via PositionManagerAdapter
        positionManager.subscribe(tokenDailyId, address(adapter), bytes(""));
        positionManager.subscribe(tokenIncId,   address(adapter), bytes(""));

        /***************************************************
         * 5. Create incentive stream & daily bucket       *
         ***************************************************/
        uint256 incentiveAmt = 700 ether;
        rewardTok.approve(address(inc), incentiveAmt);
        inc.createIncentive(key, rewardTok, incentiveAmt);

        uint256 dailyBucket = 1000 ether;
        bmx.transfer(address(daily), dailyBucket);
        daily.addRewards(pid, dailyBucket);
    }

    function testClaimBothRewards() public {
        // Fast-forward 3 days so both daily.streamRate and incentive stream accrue
        daily.rollIfNeeded(pid);
        vm.warp(block.timestamp + 3 days);

        // Hook-triggered pokes to update pool accumulators
        vm.prank(address(hook));
        inc.pokePool(key);
        vm.prank(address(hook));
        daily.pokePool(key);

        // ------------------------------------------------------------------
        // Capture pending amounts *before* claim for stronger invariants
        // ------------------------------------------------------------------
        uint256 pendingBmx = daily.pendingRewardsOwner(pid, address(this));
        IncentiveGauge.Pending[] memory pendings = inc.pendingRewardsOwner(pid, address(this));
        uint256 pendingRew;
        for (uint256 i; i < pendings.length; ++i) pendingRew += pendings[i].amount;

        // Claim via DailyEpochGauge which internally calls IncentiveGauge
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;

        uint256 preBmx = bmx.balanceOf(address(this));
        uint256 preRew = rewardTok.balanceOf(address(this));

        daily.claimAllForOwner(arr, address(this));

        uint256 bmxGain = bmx.balanceOf(address(this)) - preBmx;
        uint256 rewGain = rewardTok.balanceOf(address(this)) - preRew;

        assertGt(bmxGain, 0, "no BMX claimed");
        assertGt(rewGain, 0, "no incentive claimed");

        // Claimed amounts must match what was pending (no dust loss/duplication)
        assertEq(bmxGain, pendingBmx, "BMX claimed != pending");
        assertEq(rewGain, pendingRew, "incentive claimed != pending");
    }

    /*//////////////////////////////////////////////////////////////
                 Incentive stream extension behaviour
    //////////////////////////////////////////////////////////////*/

    function testExtendActiveStream() public {
        // Warp 3 days into the first 7-day stream
        vm.warp(block.timestamp + 3 days);

        // Record current incentive data
        (uint256 rateBefore, uint256 finishBefore, uint256 remainingBefore) = inc.incentiveData(pid, rewardTok);
        assertGt(rateBefore, 0, "stream not active");

        // Extend by adding more tokens than remaining (griefing protection)
        uint256 topUp = 450 ether; // More than the ~400 ether remaining
        rewardTok.approve(address(inc), topUp);
        inc.createIncentive(key, rewardTok, topUp);

        // Inspect new data
        (uint256 rateAfter, uint256 finishAfter, uint256 remainingAfter) = inc.incentiveData(pid, rewardTok);

        // New finish should be exactly 7 days from now (±1s tolerance)
        assertApproxEqAbs(finishAfter, block.timestamp + 7 days, 2, "finish not extended");

        uint256 expectedRemaining = (finishBefore - block.timestamp) * rateBefore + topUp;
        assertEq(remainingAfter, expectedRemaining, "remaining mismatch");

        // New rate should be (remainingAfter / 7 days)
        assertApproxEqAbs(rateAfter, remainingAfter / 7 days, 1, "rate mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                       Stream expiry behaviour
    //////////////////////////////////////////////////////////////*/

    function testStreamExpires() public {
        (, uint256 finish, ) = inc.incentiveData(pid, rewardTok);

        // warp past finish
        vm.warp(finish + 1);

        // poke to update pool so _updatePool runs and sets rate to 0
        vm.prank(address(hook));
        inc.pokePool(key);

        (uint256 rate,, uint256 remaining) = inc.incentiveData(pid, rewardTok);
        assertEq(rate, 0, "rate not zero after finish");
        assertEq(remaining, 0, "remaining not zero after finish");
    }

    /*//////////////////////////////////////////////////////////////
            DailyEpochGauge – multi-day epoch roll
    //////////////////////////////////////////////////////////////*/

    function testDailyMultiDayRoll() public {
        // Initialise Day0
        daily.rollIfNeeded(pid);
        (uint64 start0,, , ,) = daily.epochInfo(pid);

        // Warp forward 3 full days without any swaps / pokes
        vm.warp(uint256(start0) + 3 days + 1);

        // Single pokePool should fast-forward three _rollOnce iterations
        vm.prank(address(hook));
        daily.pokePool(key);

        // Expect epoch start advanced by exactly 3 days
        (uint64 startAfter, uint64 endAfter, uint128 streamRate, uint128 nextSr, uint128 queuedSr) = daily.epochInfo(pid);
        assertEq(startAfter, start0 + 3 days, "epoch did not fast-forward 3 days");

        // After 3 rolls streamRate should equal queuedRate = bucket / DAY
        uint256 expectedRate = uint256(1000 ether) / uint256(1 days);
        assertApproxEqAbs(uint256(streamRate), expectedRate, 1, "streamRate mismatch after multi-day roll");
    }

    /*//////////////////////////////////////////////////////////////
          Epoch roll behaviour with zero liquidity day
    //////////////////////////////////////////////////////////////*/

    function testEpochRollWithZeroLiquidity() public {
        // Day0 initialise
        daily.rollIfNeeded(pid);

        // Burn BOTH positions so activeLiquidity drops to zero
        uint128 liqDaily = positionManager.getPositionLiquidity(tokenDailyId);
        EasyPosm.decreaseLiquidity(positionManager, tokenDailyId, uint256(liqDaily), 0, 0, address(this), block.timestamp + 1 hours, bytes(""));
        EasyPosm.burn(positionManager, tokenDailyId, 0, 0, address(this), block.timestamp + 1 hours, bytes(""));

        uint128 liqInc = positionManager.getPositionLiquidity(tokenIncId);
        EasyPosm.decreaseLiquidity(positionManager, tokenIncId, uint256(liqInc), 0, 0, address(this), block.timestamp + 1 hours, bytes(""));
        EasyPosm.burn(positionManager, tokenIncId, 0, 0, address(this), block.timestamp + 1 hours, bytes(""));

        // Snapshot accumulator before zero-liquidity day rolls
        (uint256 rplBefore,, ,) = daily.poolRewards(pid);

        // Warp a full day+ & poke once
        (, uint64 end0,, ,) = daily.epochInfo(pid);
        vm.warp(uint256(end0) + 1 days + 1);
        vm.prank(address(hook));
        daily.pokePool(key);

        // Accumulator should be unchanged because activeLiquidity was zero all day
        (uint256 rplAfter,, ,) = daily.poolRewards(pid);
        assertEq(rplAfter, rplBefore, "RPL should not accrue when liquidity is zero");

        // Stream pipeline should still progress (queued -> next) even with zero liquidity
        (, , uint128 sr, uint128 nextSr, ) = daily.epochInfo(pid);
        assertEq(sr, 0, "streamRate should remain zero until next day active");
        assertGt(nextSr, 0, "nextStreamRate should be set even with zero liquidity");
    }

    /*//////////////////////////////////////////////////////////////
            Multiple concurrent incentive tokens
    //////////////////////////////////////////////////////////////*/

    function testMultiTokenIncentives() public {
        // deploy two extra reward tokens
        MockERC20 tokA = new MockERC20("TOKA","TA",18);
        MockERC20 tokB = new MockERC20("TOKB","TB",18);
        tokA.mint(address(this), 1e24);
        tokB.mint(address(this), 1e24);

        IERC20 iTokA = IERC20(address(tokA));
        IERC20 iTokB = IERC20(address(tokB));

        // whitelist tokens
        inc.setWhitelist(iTokA, true);
        inc.setWhitelist(iTokB, true);

        // create incentives
        uint256 amtA = 500 ether;
        uint256 amtB = 800 ether;
        iTokA.approve(address(inc), amtA);
        iTokB.approve(address(inc), amtB);
        inc.createIncentive(key, iTokA, amtA);
        inc.createIncentive(key, iTokB, amtB);

        // move forward 2 days and update pool accumulator once
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(hook));
        inc.pokePool(key);

        // claim all rewards
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 preA = iTokA.balanceOf(address(this));
        uint256 preB = iTokB.balanceOf(address(this));
        inc.claimAllForOwner(arr, address(this));
        uint256 gainA = iTokA.balanceOf(address(this)) - preA;
        uint256 gainB = iTokB.balanceOf(address(this)) - preB;

        assertGt(gainA, 0, "tokA not claimed");
        assertGt(gainB, 0, "tokB not claimed");
    }

    /*//////////////////////////////////////////////////////////////
            Gas sanity: 10 concurrent incentive tokens
    //////////////////////////////////////////////////////////////*/
    function testGasMultiTokenClaim() public {
        uint256 NUM = 10;
        IERC20[] memory toks = new IERC20[](NUM);
        for (uint256 i; i < NUM; ++i) {
            MockERC20 t = new MockERC20(string(abi.encodePacked("T", i)), string(abi.encodePacked("T", i)), 18);
            t.mint(address(this), 1e24);
            IERC20 it = IERC20(address(t));
            toks[i] = it;
            inc.setWhitelist(it, true);
            uint256 amt = 100 ether;
            it.approve(address(inc), amt);
            inc.createIncentive(key, it, amt);
        }

        // Advance 1 day and poke once
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(hook));
        inc.pokePool(key);

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 gasBefore = gasleft();
        inc.claimAllForOwner(arr, address(this));
        uint256 gasUsed = gasBefore - gasleft();
        // Sanity threshold: < 2.8m gas for 10 tokens claim path
        assertLt(gasUsed, 2_800_000, "claim gas too high");

        // Ensure each token paid some amount > 0
        for (uint256 i; i < NUM; ++i) {
            assertGt(toks[i].balanceOf(address(this)), 0, "no payout for token");
        }
    }

    /*//////////////////////////////////////////////////////////////
            DailyGauge bucket top-up mid-stream
    //////////////////////////////////////////////////////////////*/
    function testDailyBucketTopUpMidStream() public {
        // Ensure streaming is active
        daily.rollIfNeeded(pid);
        while (daily.streamRate(pid) == 0) {
            vm.warp(block.timestamp + 1 days);
            daily.rollIfNeeded(pid);
        }
        uint256 initialRate = daily.streamRate(pid);

        // Top-up bucket with additional 500 BMX
        uint256 topUp = 500 ether;
        bmx.transfer(address(daily), topUp);
        daily.addRewards(pid, topUp);

        // Advance 2 days from current epoch end to allow queued rate to activate
        (, uint64 endNow,, ,) = daily.epochInfo(pid);
        vm.warp(uint256(endNow) + 2 days + 1);
        daily.rollIfNeeded(pid);

        uint256 newRate = daily.streamRate(pid);
        uint256 expectedRate = topUp / uint256(1 days);
        assertApproxEqAbs(newRate, expectedRate, 1, "streamRate did not reflect queued top-up");
    }

    /*//////////////////////////////////////////////////////////////
                Claim aggregation across multiple positions
    //////////////////////////////////////////////////////////////*/

    function testClaimAcrossPositions() public {
        // First, warp past the incentive period so it expires
        vm.warp(block.timestamp + 8 days);
        
        // Update the pool to finalize the incentive
        vm.prank(address(hook));
        inc.pokePool(key);

        // Mint a *second* position for the Daily gauge within the same pool
        // ticks must align with spacing (60). Use -12000 / 12000 which are multiples of 60.
        (uint256 tokenDailyId2,) = EasyPosm.mint(
            positionManager,
            key,
            -12000,
            12000,
            1e21,
            1e24,
            1e24,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenDailyId2, address(adapter), bytes(""));

        // Add new BMX rewards since the original bucket has likely been depleted
        uint256 newBucket = 500 ether;
        bmx.transfer(address(daily), newBucket);
        daily.addRewards(pid, newBucket);

        // -------------------------------------------------------------
        // Advance enough days for rewards to move through the pipeline.
        // Day 1: bucket → queued
        // Day 2: queued → next  
        // Day 3: next → current (active streaming)
        // -------------------------------------------------------------
        daily.rollIfNeeded(pid);
        vm.warp(block.timestamp + 3 days + 1);
        daily.rollIfNeeded(pid);

        vm.prank(address(hook));
        daily.pokePool(key);

        uint256 pre = bmx.balanceOf(address(this));

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        daily.claimAllForOwner(arr, address(this));

        uint256 gain = bmx.balanceOf(address(this)) - pre;
        // Expect some positive payout that combines both positions' share
        assertGt(gain, 0, "no BMX from multiple-position claim");
    }

    /*//////////////////////////////////////////////////////////////
          Incentive created *after* a position subscribed
    //////////////////////////////////////////////////////////////*/

    function testIncentiveCreatedPostSubscribe() public {
        // Deploy fresh reward token not yet incentivised
        MockERC20 newReward = new MockERC20("NEW","NEW",18);
        newReward.mint(address(this), 1e24);

        inc.setWhitelist(IERC20(address(newReward)), true);

        // Wait two days – position already subscribed but no incentive yet
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(hook));
        inc.pokePool(key);

        // Ensure there is no pending amount for the NEW token (other tokens might already have streams)
        IncentiveGauge.Pending[] memory beforePend = inc.pendingRewardsOwner(pid, address(this));
        uint256 newPend;
        for (uint256 i; i < beforePend.length; ++i) {
            if (beforePend[i].token == IERC20(address(newReward))) {
                newPend = beforePend[i].amount;
                break;
            }
        }
        assertEq(newPend, 0, "newReward pending before stream should be zero");

        // Create new 7-day stream now
        uint256 amt = 500 ether;
        newReward.approve(address(inc), amt);
        inc.createIncentive(key, IERC20(address(newReward)), amt);

        // Move one day forward and poke so pool accrues
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(hook));
        inc.pokePool(key);

        // Claim and expect > 0
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 pre = newReward.balanceOf(address(this));
        inc.claimAllForOwner(arr, address(this));
        uint256 gain = newReward.balanceOf(address(this)) - pre;
        assertGt(gain, 0, "no reward after post-subscribe stream");
    }
} 