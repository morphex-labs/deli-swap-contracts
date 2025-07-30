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

    function testBuybackSwapExecutes() public {
        uint256 inAmt = 1000 ether;
        _collectNonBmx(inAmt);
        // no pool registered yet; gauge should be zero, buffer non-zero
        assertEq(gauge.rewards(buybackKey.toId()), 0);
        assertGt(fp.pendingWbltForBuyback(), 0);

        _registerPool();
        uint256 preGauge = gauge.rewards(buybackKey.toId());
        fp.flushBuffers();
        uint256 postGauge = gauge.rewards(buybackKey.toId());
        assertEq(postGauge - preGauge, inAmt * fp.buybackBps() / 10000, "BMX rewards incorrect");
        assertEq(fp.pendingWbltForBuyback(), 0);
    }

    function testVoterSwapExecutes() public {
        uint256 feeAmt = 1000 ether;
        _collectBmx(feeAmt);
        _registerPool();

        uint256 voterPortion = feeAmt - (feeAmt * fp.buybackBps() / 10000);
        bytes memory transferCall = abi.encodeWithSelector(wblt.transfer.selector, VOTER_DIST, voterPortion);
        vm.expectCall(address(wblt), transferCall);
        fp.flushBuffers();
        assertEq(fp.pendingBmxForVoter(), 0);
    }

    function testSwapFailedEmitsAndResets() public {
        uint256 amt = 1000 ether;
        _collectNonBmx(amt);
        _registerPool();
        pm.setRevertOnSwap(true);
        // flush should NOT revert even though swap fails internally
        fp.flushBuffers();
        // Buffer should be restored after failure (no loss)
        uint256 expectedBuf = amt * fp.buybackBps() / 10000;
        assertEq(fp.pendingWbltForBuyback(), expectedBuf);
    }
} 