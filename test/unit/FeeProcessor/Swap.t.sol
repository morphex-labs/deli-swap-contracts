// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MintableERC20} from "test/unit/FeeProcessor/Admin.t.sol";
import {MockSwapPoolManager} from "test/mocks/MockSwapPoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";


contract FeeProcessor_SwapTest is Test {
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

        // deploy tokens
        wblt = new MintableERC20(); wblt.initialize("wBLT","WBLT",18);
        bmx = new MintableERC20(); bmx.initialize("BMX","BMX",18);

        // give FeeProcessor large balances
        wblt.mintExternal(address(this), 1e24);
        wblt.mintExternal(address(pm), 1e24);
        bmx.mintExternal(address(this), 1e24);

        fp = new FeeProcessor(pmI, HOOK, address(wblt), address(bmx), gauge, VOTER_DIST);

        // transfer some tokens to FeeProcessor so it can pay in settle()
        wblt.transfer(address(fp), 1e21);
        bmx.transfer(address(fp), 1e21);

        buybackKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _registerPool() internal {
        fp.setBuybackPoolKey(buybackKey);
        pm.setSqrtPrice(PoolId.unwrap(buybackKey.toId()), uint160(1 << 96));
    }

    function _collectNonBmx(uint256 amount) internal {
        // simulate fee collection in wBLT pool (OTHER_TOKEN -> wBLT) to add pendingWbltForBuyback
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x9999)),
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

    function testBuybackSwapExecutes() public {
        uint256 inAmt = 1000 ether;
        _collectNonBmx(inAmt);
        // Create the pool key that was used in _collectNonBmx
        PoolKey memory nonBmxKey = PoolKey({
            currency0: Currency.wrap(address(0x9999)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId nonBmxPoolId = nonBmxKey.toId();
        
        // no pool registered yet; gauge should be zero, buffer non-zero
        assertEq(gauge.rewards(nonBmxPoolId), 0);
        assertGt(fp.pendingWbltForBuyback(nonBmxPoolId), 0);

        _registerPool();
        uint256 preGauge = gauge.rewards(nonBmxPoolId);
        fp.flushBuffer(nonBmxPoolId);
        uint256 postGauge = gauge.rewards(nonBmxPoolId);
        assertEq(postGauge - preGauge, inAmt * fp.buybackBps() / 10000, "BMX rewards incorrect");
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), 0);
    }

    function testVoterSwapExecutes() public {
        uint256 feeAmt = 1000 ether;
        _collectBmx(feeAmt);
        _registerPool();

        uint256 voterPortion = feeAmt - (feeAmt * fp.buybackBps() / 10000);
        // For BMX pool fees, flush processes only the buyback buffer; voter share remains buffered in wBLT
        uint256 preGauge = gauge.rewards(buybackKey.toId());
        fp.flushBuffer(buybackKey.toId());
        uint256 postGauge = gauge.rewards(buybackKey.toId());
        assertEq(postGauge - preGauge, feeAmt * fp.buybackBps() / 10000, "gauge buyback from BMX fee");
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter portion buffered in wBLT");
    }

    function testSwapFailedEmitsAndResets() public {
        uint256 amt = 1000 ether;
        _collectNonBmx(amt);
        PoolKey memory nonBmxKey = PoolKey({
            currency0: Currency.wrap(address(0x9999)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId nonBmxPoolId = nonBmxKey.toId();
        
        _registerPool();
        pm.setRevertOnSwap(true);
        
        // Direct flushBuffer() call will revert since there's no try-catch wrapper
        vm.expectRevert("swap fail");
        fp.flushBuffer(nonBmxPoolId);
        
        // Buffer should remain after failed direct flush (no state change)
        uint256 expectedBuf = amt * fp.buybackBps() / 10000;
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), expectedBuf);
        
        // Now test that collectFee with try-catch silently fails and buffer accumulates
        pm.setRevertOnSwap(true); // Keep swap reverting
        _collectNonBmx(amt); // This won't revert due to try-catch, flush fails silently
        
        // The second collect added to buffer, flush failed, so buffer = first + second amount
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), expectedBuf * 2, "Buffer should have accumulated both collections");
        
        // Give FeeProcessor more wBLT and BMX tokens for the final successful flush
        wblt.transfer(address(fp), 2e21);
        bmx.transfer(address(fp), 2e21); // Need BMX for the swap output
        
        // Now allow swaps and verify the accumulated buffer can be flushed
        pm.setRevertOnSwap(false);
        fp.flushBuffer(nonBmxPoolId);
        assertEq(fp.pendingWbltForBuyback(nonBmxPoolId), 0, "Buffer should be cleared after successful flush");
    }
} 