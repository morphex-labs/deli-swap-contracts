// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {DeliHook} from "src/DeliHook.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract DeliHook_InternalSwapFlagTest is Test {
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

        // deploy hook at valid address using HookMiner
        bytes memory ctorArgs = abi.encode(address(pm), address(fp), address(daily), address(inc), address(wblt), address(bmx));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);
        hook = new DeliHook{salt: salt}(IPoolManager(address(pm)), IFeeProcessor(address(fp)), IDailyEpochGauge(address(daily)), IIncentiveGauge(address(inc)), address(wblt), address(bmx));
    }

    function _callSwap(address trader, PoolKey memory key, SwapParams memory params, bytes memory data) internal {
        vm.prank(address(pm));
        hook.beforeSwap(trader, key, params, data);
        vm.prank(address(pm));
        hook.afterSwap(trader, key, params, toBalanceDelta(0,0), data);
    }

    function testInternalSwapFlagSkipsAllSideEffects() public {
        // Construct arbitrary pool where currency1 is wBLT (required)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        // zeroForOne swap params; sentinel data
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});
        bytes memory flagData = abi.encode(bytes4(0xDE1ABEEF));

        _callSwap(address(0xCAFE), key, sp, flagData);

        // 1. No fee forwarded
        assertEq(fp.calls(), 0);
        // 2. No epoch roll or pool poke
        assertEq(daily.rollCalls(), 0);
        assertEq(daily.pokeCalls(), 0);
        // 3. IncentiveGauge not poked
        assertEq(inc.pokeCount(), 0);
        // 4. PoolManager not touched (no settle calls)
        assertEq(pm.settleCalls(), 0);
    }
} 