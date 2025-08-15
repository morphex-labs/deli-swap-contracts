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
        fp.collectFee(key, amount, false);
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
        fp.collectFee(key, amount, false);
    }

    // ---------------------------------------------------------------------
    // New: flush with BOTH buffers populated
    // ---------------------------------------------------------------------

    function testFlushBothBuffers() public {
        uint256 wbltFee = 1_000 ether; // from non-BMX pool
        uint256 bmxFee  = 500 ether;   // from BMX pool

        // Define pool IDs
        PoolKey memory nonBmxKey = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId nonBmxPoolId = nonBmxKey.toId();

        // Capture gauge state BEFORE any fees are collected
        uint256 initialGauge = gauge.rewards(nonBmxPoolId);

        _collectNonBmx(wbltFee);
        _collectBmx(bmxFee);

        // pool already registered in setUp
        
        // After both collectFee calls, the non-BMX pool's buffer should have been auto-flushed
        uint256 postCollectGauge = gauge.rewards(nonBmxPoolId);
        
        // The gauge should have increased from the auto-flush during collectFee
        uint256 expectedBuyback = (wbltFee * fp.buybackBps()) / 10_000;
        assertGt(postCollectGauge, initialGauge, "gauge should increase from auto-flush");
        assertEq(postCollectGauge, initialGauge + expectedBuyback, "gauge should increase by buyback amount");

        // Voter wBLT remains buffered; includes voter share from BOTH collections
        uint256 voterPortionBmxFee = bmxFee - (bmxFee * fp.buybackBps()) / 10_000;
        uint256 voterPortionWbltFee = wbltFee - (wbltFee * fp.buybackBps()) / 10_000;
        assertEq(fp.pendingWbltForVoter(), voterPortionBmxFee + voterPortionWbltFee, "voter wBLT should be buffered from both fees");

        // Manual flush should be a no-op since buffer was already auto-flushed
        fp.flushBuffer(nonBmxPoolId);

        uint256 finalGauge = gauge.rewards(nonBmxPoolId);
        // Gauge should not change from manual flush (already flushed)
        assertEq(finalGauge, postCollectGauge, "gauge should not change from redundant flush");

        // Buffers cleared
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), 0);
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
        fp2.collectFee(otherKey, wbltFee, false);

        // collect BMX fee (canonical pool)
        PoolKey memory canonKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(HOOK);
        fp2.collectFee(canonKey, bmxFee, false);

        // buffers should be populated, no rewards yet
        PoolId otherPoolId = otherKey.toId();
        uint256 preGauge = gauge.rewards(otherPoolId);
        assertGt(fp2.pendingWbltForBuyback(otherPoolId), 0, "buyback buf empty");
        assertGt(fp2.pendingWbltForVoter(), 0, "voter wblt buf empty");

        // Register pool key then flush
        fp2.setBuybackPoolKey(buybackKey);
        pm.setSqrtPrice(PoolId.unwrap(buybackKey.toId()), uint160(1 << 96));

        fp2.flushBuffer(otherPoolId);

        // buy-back executed – gauge bucket increases for the source pool
        uint256 postGauge = gauge.rewards(otherPoolId);
        assertGt(postGauge, preGauge, "gauge unchanged");

        // voter buffer increased; no auto-transfer
        assertGt(fp2.pendingWbltForVoter(), 0, "voter not paid");

        // buffers cleared
        assertEq(fp2.pendingWbltForBuyback(otherPoolId), 0, "buyback buf not cleared");
    }

    // ---------------------------------------------------------------------
    // Slippage protection tests
    // ---------------------------------------------------------------------

    function testSlippageRevertsOnBuyback() public {
        // Set poor price before buffer collection so slippage triggers in first swap
        pm.setOutputBps(9000);
        
        // collectFee won't revert due to try-catch, but buffer should remain
        _collectNonBmx(100 ether);
        
        // Define pool ID
        PoolKey memory nonBmxKey = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId nonBmxPoolId = nonBmxKey.toId();
        
        // Check actual buffer value first
        uint256 actualBuffer = fp.pendingWbltForBuyback(nonBmxPoolId);
        
        // Calculate expected buffer
        uint256 feeAmount = 100 ether;
        uint256 buybackBps = fp.buybackBps();
        uint256 expectedBuffer = (feeAmount * buybackBps) / 10_000;
        
        // Verify buffer wasn't cleared due to slippage (the internal revert was caught)
        assertEq(actualBuffer, expectedBuffer, "Buffer should remain after slippage");
        
        // Direct flushBuffer() call would still revert on slippage
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffer(nonBmxPoolId);
    }

    function testSlippageRevertsOnVoterFlush() public {
        pm.setOutputBps(9000);
        
        // collectFee won't revert due to try-catch, but voter buffer should remain
        _collectBmx(100 ether);
        
        // Check actual values first
        uint256 actualVoterBuffer = fp.pendingWbltForVoter();
        uint256 actualGaugeRewards = gauge.rewards(buybackKey.toId());
        
        // Calculate expected values
        uint256 feeAmount = 100 ether;
        uint256 buybackBps = fp.buybackBps();
        uint256 expectedGauge = (feeAmount * buybackBps) / 10_000;
        uint256 expectedVoterBuffer = feeAmount - expectedGauge;
        
        // Verify voter buffer wasn't cleared due to slippage
        assertEq(actualVoterBuffer, expectedVoterBuffer, "Voter buffer should remain after slippage");
        
        // Auto-flush during collectFee reverts due to slippage and is swallowed; gauge remains unchanged
        assertEq(actualGaugeRewards, 0, "Gauge should have no buyback portion before successful flush");
        
        // Direct flushBuffer() call would still revert on slippage for voter flush
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffer(buybackKey.toId());
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
        fp2.collectFee(key, wbltFee, false);

        // No rewards yet
        PoolId poolId = key.toId();
        uint256 pre = gauge.rewards(poolId);

        // Register pool key now
        fp2.setBuybackPoolKey(buybackKey);
        pm.setSqrtPrice(PoolId.unwrap(buybackKey.toId()), uint160(1 << 96));

        // Flush to execute buyback
        fp2.flushBuffer(poolId);

        uint256 expected = (wbltFee * fp2.buybackBps()) / 10_000;
        uint256 post = gauge.rewards(poolId);
        assertEq(post - pre, expected, "buyback amount mismatch");

        // buffer cleared
        assertEq(fp2.pendingWbltForBuyback(poolId), 0);
    }

    function testReentryAfterSwapFailure() public {
        // Configure mock PM to revert during swap so unlockCallback catch path executes
        pm.setRevertOnSwap(true);

        uint256 wbltFee = 100 ether;

        // First fee triggers swap attempt that will fail and leave buffer intact
        PoolKey memory firstKey = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId firstPoolId = firstKey.toId();
        
        vm.prank(HOOK);
        fp.collectFee(firstKey, wbltFee, false);

        // After swap failure the buffer is restored
        uint256 expectedFirst = (wbltFee * fp.buybackBps()) / 10_000;
        assertEq(fp.pendingWbltForBuyback(firstPoolId), expectedFirst, "buffer missing after failure");

        // Allow swaps again
        pm.setRevertOnSwap(false);

        // Second fee should succeed (no revert) and buffer now > initial
        uint256 secondFee = 80 ether;
        PoolKey memory secondKey = PoolKey({
            currency0: Currency.wrap(address(0xAAAA)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId secondPoolId = secondKey.toId();
        
        vm.prank(HOOK);
        fp.collectFee(secondKey, secondFee, false);

        // Second pool's buffer should be zero after successful swap
        assertEq(fp.pendingWbltForBuyback(secondPoolId), 0, "buffer should be zero after successful swap");
        // First pool's buffer should still be there (failed swap wasn't retried)
        assertEq(fp.pendingWbltForBuyback(firstPoolId), expectedFirst, "first pool buffer should remain");
    }

    function testInternalFeeNoRecursion() public {
        // Test that collecting internal fees doesn't trigger flushBuffers
        uint256 bmxFee = 100 ether;
        
        // Collect some regular fees first to populate buffers
        _collectNonBmx(200 ether);
        _collectBmx(150 ether);
        
        // Define the non-BMX pool ID
        PoolKey memory nonBmxKey = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId nonBmxPoolId = nonBmxKey.toId();
        
        uint256 preBuyback = fp.pendingWbltForBuyback(nonBmxPoolId);
        uint256 preVoter = fp.pendingWbltForVoter();
        uint256 preGauge = gauge.rewards(buybackKey.toId());
        
        // Collect internal fee
        vm.prank(HOOK);
        fp.collectFee(buybackKey, bmxFee, true);
        
        // Buffers should remain unchanged (no flush triggered)
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), preBuyback, "buyback buffer changed");
        assertEq(fp.pendingWbltForVoter(), preVoter + (bmxFee * 300 / 10_000), "voter buffer incorrect");
        
        // Internal fee collection should NOT trigger a flush; gauge stays the same
        assertEq(gauge.rewards(buybackKey.toId()), preGauge, "gauge should not change on internal fee");
    }
} 