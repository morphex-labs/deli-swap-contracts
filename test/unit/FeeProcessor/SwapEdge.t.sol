// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MockSwapPoolManager} from "test/mocks/MockSwapPoolManager.sol";
import {MintableERC20} from "test/unit/FeeProcessor/Admin.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ImmutableState} from "lib/uniswap-hooks/lib/v4-periphery/src/base/ImmutableState.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

contract FeeProcessor_SwapEdgeTest is Test {
    using PoolIdLibrary for PoolKey;

    MockSwapPoolManager pm;
    FeeProcessor fp;
    MockDailyEpochGauge gauge;
    MintableERC20 wblt;
    MintableERC20 bmx;

    address constant HOOK = address(uint160(0xbeef));
    address constant VOTER_DIST = address(uint160(0xcafe));

    PoolKey buybackKey;

    function setUp() public {
        pm = new MockSwapPoolManager();
        gauge = new MockDailyEpochGauge();
        IPoolManager pmI = IPoolManager(address(pm));

        wblt = new MintableERC20(); wblt.initialize("wBLT","WBLT",18);
        bmx = new MintableERC20(); bmx.initialize("BMX","BMX",18);

        fp = new FeeProcessor(pmI, HOOK, address(wblt), address(bmx), gauge, VOTER_DIST);

        // fund FeeProcessor so it can pay swap inputs (after deployment so address is correct)
        wblt.mintExternal(address(fp), 1e24);
        bmx.mintExternal(address(fp), 1e24);
        // fund mock pool manager reserves
        wblt.mintExternal(address(pm), 1e24);

        buybackKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // register pool with sqrtPrice = 1
        fp.setBuybackPoolKey(buybackKey);
        pm.setSqrtPrice(PoolId.unwrap(buybackKey.toId()), uint160(1 << 96));
    }

    // ---------------------------------------------------------------------
    // Helpers to collect fee buffers
    // ---------------------------------------------------------------------
    function _collectNonBmx(uint256 amount) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(HOOK);
        fp.collectFee(key, amount);
    }

    function _collectBmx(uint256 amount) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(HOOK);
        fp.collectFee(key, amount);
    }

    // ---------------------------------------------------------------------
    // New: flush with BOTH buffers populated
    // ---------------------------------------------------------------------

    function testFlushBothBuffers() public {
        uint256 wbltFee = 1_000 ether; // from non-BMX pool
        uint256 bmxFee  = 500 ether;   // from BMX pool

        _collectNonBmx(wbltFee);
        _collectBmx(bmxFee);

        // pool already registered in setUp

        // Capture state AFTER both collectFee calls (buy-backs already executed)
        uint256 preGauge = gauge.rewards(buybackKey.toId());

        uint256 voterPortionBmxFee = bmxFee - (bmxFee * fp.buybackBps()) / 10_000;

        // Voter wBLT should have been transferred during second collectFee already
        uint256 preBal = wblt.balanceOf(VOTER_DIST);
        assertEq(preBal, voterPortionBmxFee, "voter wBLT initial");

        // flush should not change balances now
        fp.flushBuffers();

        uint256 postGauge = gauge.rewards(buybackKey.toId());
        // Gauge unchanged during flush (no buy-back swap at this stage)
        assertEq(postGauge, preGauge, "gauge should not change on flush");

        uint256 postBal = wblt.balanceOf(VOTER_DIST);
        assertEq(postBal, preBal, "voter balance unchanged");

        // Buffers cleared
        assertEq(fp.pendingWbltForBuyback(), 0);
        assertEq(fp.pendingBmxForVoter(), 0);
        // pendingWbltForVoter should remain (3% of wbltFee) until claimVoterFees
    }

    function testFlushBothBuffersLate() public {
        // Fresh FeeProcessor without pool key set
        FeeProcessor fp2 = new FeeProcessor(IPoolManager(address(pm)), HOOK, address(wblt), address(bmx), gauge, VOTER_DIST);
        wblt.mintExternal(address(fp2), 1e24);
        bmx.mintExternal(address(fp2), 1e24);

        uint256 wbltFee = 800 ether; // from non-BMX pool
        uint256 bmxFee  = 400 ether; // from BMX pool

        // collect wBLT fee (OTHER/wBLT pool)
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(0xDEAD)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(HOOK);
        fp2.collectFee(otherKey, wbltFee);

        // collect BMX fee (canonical pool)
        PoolKey memory canonKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(HOOK);
        fp2.collectFee(canonKey, bmxFee);

        // buffers should be populated, no rewards yet
        uint256 preGauge = gauge.rewards(buybackKey.toId());
        assertGt(fp2.pendingWbltForBuyback(), 0, "buyback buf empty");
        assertGt(fp2.pendingBmxForVoter(), 0, "voter bmx buf empty");

        // Register pool key then flush
        fp2.setBuybackPoolKey(buybackKey);
        pm.setSqrtPrice(PoolId.unwrap(buybackKey.toId()), uint160(1 << 96));

        uint256 voterPre = wblt.balanceOf(VOTER_DIST);

        fp2.flushBuffers();

        // buy-back executed – gauge bucket increases
        uint256 postGauge = gauge.rewards(buybackKey.toId());
        assertGt(postGauge, preGauge, "gauge unchanged");

        // voter received wBLT
        uint256 voterPost = wblt.balanceOf(VOTER_DIST);
        assertGt(voterPost, voterPre, "voter not paid");

        // buffers cleared
        assertEq(fp2.pendingWbltForBuyback(), 0, "buyback buf not cleared");
        assertEq(fp2.pendingBmxForVoter(), 0, "bmx buf not cleared");
    }

    // ---------------------------------------------------------------------
    // Slippage protection tests
    // ---------------------------------------------------------------------

    function testSlippageRevertsOnBuyback() public {
        // Set poor price before buffer collection so slippage triggers in first swap
        pm.setOutputBps(9000);
        
        // collectFee won't revert due to try-catch, but buffer should remain
        _collectNonBmx(100 ether);
        
        // Check actual buffer value first
        uint256 actualBuffer = fp.pendingWbltForBuyback();
        
        // Calculate expected buffer
        uint256 feeAmount = 100 ether;
        uint256 buybackBps = fp.buybackBps();
        uint256 expectedBuffer = (feeAmount * buybackBps) / 10_000;
        
        // Verify buffer wasn't cleared due to slippage (the internal revert was caught)
        assertEq(actualBuffer, expectedBuffer, "Buffer should remain after slippage");
        
        // Direct flushBuffers() call would still revert on slippage
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffers();
    }

    function testSlippageRevertsOnVoterFlush() public {
        pm.setOutputBps(9000);
        
        // collectFee won't revert due to try-catch, but voter buffer should remain
        _collectBmx(100 ether);
        
        // Check actual values first
        uint256 actualVoterBuffer = fp.pendingBmxForVoter();
        uint256 actualGaugeRewards = gauge.rewards(buybackKey.toId());
        
        // Calculate expected values
        uint256 feeAmount = 100 ether;
        uint256 buybackBps = fp.buybackBps();
        uint256 expectedGauge = (feeAmount * buybackBps) / 10_000;
        uint256 expectedVoterBuffer = feeAmount - expectedGauge;
        
        // Verify voter buffer wasn't cleared due to slippage
        assertEq(actualVoterBuffer, expectedVoterBuffer, "Voter buffer should remain after slippage");
        
        // Gauge should still have received the buyback portion (97%)
        assertEq(actualGaugeRewards, expectedGauge, "Gauge should have buyback portion");
        
        // Direct flushBuffers() call would still revert on slippage
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffers();
    }

    // ---------------------------------------------------------------------
    // unlockCallback access-control
    // ---------------------------------------------------------------------
    function testUnlockCallbackOnlyPoolManager() public {
        vm.expectRevert(DeliErrors.NotPoolManager.selector);
        fp.unlockCallback("");
    }

    // ---------------------------------------------------------------------
    // Buyback amount when pool key is set AFTER buffer collection
    // ---------------------------------------------------------------------

    function testBuybackAmountLatePoolKey() public {
        // Deploy fresh FeeProcessor without pool key registered
        FeeProcessor fp2 = new FeeProcessor(IPoolManager(address(pm)), HOOK, address(wblt), address(bmx), gauge, VOTER_DIST);

        // fund with tokens for swap settlement
        wblt.mintExternal(address(fp2), 1e21);
        bmx.mintExternal(address(fp2), 1e21);

        uint256 wbltFee = 500 ether;

        // collect fee from non-BMX pool (wBLT incoming)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0xAAAA)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(HOOK);
        fp2.collectFee(key, wbltFee);

        // No rewards yet
        uint256 pre = gauge.rewards(buybackKey.toId());

        // Register pool key now
        fp2.setBuybackPoolKey(buybackKey);
        pm.setSqrtPrice(PoolId.unwrap(buybackKey.toId()), uint160(1 << 96));

        // Flush to execute buyback
        fp2.flushBuffers();

        uint256 expected = (wbltFee * fp2.buybackBps()) / 10_000;
        uint256 post = gauge.rewards(buybackKey.toId());
        assertEq(post - pre, expected, "buyback amount mismatch");

        // buffer cleared
        assertEq(fp2.pendingWbltForBuyback(), 0);
    }

    function testReentryAfterSwapFailure() public {
        // Configure mock PM to revert during swap so unlockCallback catch path executes
        pm.setRevertOnSwap(true);

        uint256 wbltFee = 100 ether;

        // First fee triggers swap attempt that will fail and leave buffer intact
        vm.prank(HOOK);
        fp.collectFee(PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        }), wbltFee);

        // After swap failure the buffer is restored
        uint256 expectedFirst = (wbltFee * fp.buybackBps()) / 10_000;
        assertEq(fp.pendingWbltForBuyback(), expectedFirst, "buffer missing after failure");

        // Allow swaps again
        pm.setRevertOnSwap(false);

        // Second fee should succeed (no revert) and buffer now > initial
        uint256 secondFee = 80 ether;
        vm.prank(HOOK);
        fp.collectFee(PoolKey({
            currency0: Currency.wrap(address(0xAAAA)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        }), secondFee);

        // Second collect triggers a successful swap that clears the buffer again
        assertEq(fp.pendingWbltForBuyback(), 0, "buffer should be zero after successful swap");
    }

    function testInternalFeeNoRecursion() public {
        // Test that collecting internal fees doesn't trigger flushBuffers
        uint256 bmxFee = 100 ether;
        
        // Collect some regular fees first to populate buffers
        _collectNonBmx(200 ether);
        _collectBmx(150 ether);
        
        uint256 preBuyback = fp.pendingWbltForBuyback();
        uint256 preBmxVoter = fp.pendingBmxForVoter();
        uint256 preGauge = gauge.rewards(buybackKey.toId());
        
        // Collect internal fee
        vm.prank(HOOK);
        fp.collectInternalFee(bmxFee);
        
        // Buffers should remain unchanged (no flush triggered)
        assertEq(fp.pendingWbltForBuyback(), preBuyback, "buyback buffer changed");
        assertEq(fp.pendingBmxForVoter(), preBmxVoter + (bmxFee * 300 / 10_000), "BMX voter buffer incorrect");
        
        // Gauge should increase by 97% of internal fee
        uint256 expectedGaugeIncrease = (bmxFee * fp.buybackBps()) / 10_000;
        assertEq(gauge.rewards(buybackKey.toId()), preGauge + expectedGaugeIncrease, "gauge increase incorrect");
    }
} 