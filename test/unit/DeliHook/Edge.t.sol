// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {DeliHook} from "src/DeliHook.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MintableERC20} from "test/mocks/MintableERC20.sol";

import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";
import {MockFeeProcessor} from "test/mocks/MockFeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeliHook_EdgeTest is Test {
    using PoolIdLibrary for PoolKey;

    MockHookPoolManager pm;
    MockFeeProcessor fp;
    MockDailyEpochGauge daily;
    MockIncentiveGauge inc;
    DeliHook hook;

    MintableERC20 wblt;
    MintableERC20 bmx;
    address constant OTHER = address(0x123);

    function setUp() public {
        pm = new MockHookPoolManager();
        fp = new MockFeeProcessor();
        daily = new MockDailyEpochGauge();
        inc = new MockIncentiveGauge();

        wblt = new MintableERC20(); wblt.initialize("wBLT","WBLT",18);
        bmx = new MintableERC20(); bmx.initialize("BMX","BMX",18);

        bytes memory ctorArgs = abi.encode(address(pm), address(fp), address(daily), address(inc), address(wblt), address(bmx), address(this));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);
        hook = new DeliHook{salt: salt}(IPoolManager(address(pm)), IFeeProcessor(address(fp)), IDailyEpochGauge(address(daily)), IIncentiveGauge(address(inc)), address(wblt), address(bmx), address(this));
    }

    // helper to execute swap path fully
    function _callSwap(address trader, PoolKey memory key, SwapParams memory params, bytes memory data) internal {
        vm.prank(address(pm));
        hook.beforeSwap(trader, key, params, data);
        vm.prank(address(pm));
        hook.afterSwap(trader, key, params, toBalanceDelta(0,0), data);
    }

    // ---------------------------------------------------------------------
    // 1. Exact OUTPUT swaps should still forward fee
    // ---------------------------------------------------------------------
    function testExactOutput_WbltPool_ForwardsFee() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        
        // Provide wBLT to PoolManager for fee collection
        wblt.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        wblt.approve(address(hook), type(uint256).max);
        
        // exact output (positive) 1e18 of token1 (wBLT)
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:1e18, sqrtPriceLimitX96:0});
        _callSwap(address(0xAAA), key, sp, "");

        uint256 expected = 1e18 * 3000 / 1_000_000;
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
    }

    function testExactOutput_BmxPool_ForwardsFee() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        
        // Provide BMX to PoolManager for fee collection  
        bmx.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        bmx.approve(address(hook), type(uint256).max);
        
        // exact output (positive) 2e18 of token0 (BMX)
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:2e18, sqrtPriceLimitX96:0});
        _callSwap(address(0xBBB), key, sp, "");

        uint256 expected = 2e18 * 3000 / 1_000_000;
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
    }

    // ---------------------------------------------------------------------
    // 2. Dust trades (fee rounds to zero) should not forward fee nor call settle
    // ---------------------------------------------------------------------
    function testDustTrade_NoFee_NoSettle() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        // exact input 100 wei (fee calc => 0)
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-100, sqrtPriceLimitX96:0});
        _callSwap(address(0xCCC), key, sp, "");

        assertEq(fp.calls(), 0);
        assertEq(pm.settleCalls(), 0);
    }

    // ---------------------------------------------------------------------
    // 3. BMX pool should not use pullFromSender logic (always uses take)
    // ---------------------------------------------------------------------
    function testPullFromSender_BmxPool_SettleCalled() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        // Direction BMX -> wBLT (zeroForOne true), exact input 1e18
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});

        // Provide BMX to PoolManager and approve hook
        bmx.mintExternal(address(pm), 5e18);
        vm.prank(address(pm));
        IERC20(address(bmx)).approve(address(hook), type(uint256).max);

        _callSwap(address(0xDDD), key, sp, "");

        uint256 expected = 1e18 * 3000 / 1_000_000;
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
        // No settle should be called because fee token is BMX and already in PoolManager
        assertEq(pm.settleCalls(), 0);
    }
} 