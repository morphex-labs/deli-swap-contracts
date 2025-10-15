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
        bytes memory ctorArgs = abi.encode(address(pm), address(fp), address(daily), address(inc), address(wblt), address(bmx), address(this));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);
        hook = new DeliHook{salt: salt}(IPoolManager(address(pm)), IFeeProcessor(address(fp)), IDailyEpochGauge(address(daily)), IIncentiveGauge(address(inc)), address(wblt), address(bmx), address(this));
    }

    function _callSwap(address trader, PoolKey memory key, SwapParams memory params, bytes memory data) internal {
        vm.prank(address(pm));
        hook.beforeSwap(trader, key, params, data);

        bool exactInput = params.amountSpecified < 0;
        bool specifiedIs0 = params.zeroForOne ? exactInput : !exactInput;
        bool feeMatchesSpecified = (Currency.unwrap(key.currency0) == address(wblt)) == specifiedIs0;
        uint256 s0 = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
        uint256 fee = (s0 * 3000 + (1_000_000 - 1)) / 1_000_000; // ceil(s0 * fee / 1e6)
        uint256 sprime = feeMatchesSpecified ? (exactInput ? s0 - fee : s0 + fee) : s0;

        int128 a0 = 0;
        int128 a1 = 0;
        if (specifiedIs0) {
            a0 = exactInput ? int128(int256(sprime)) : int128(-int256(sprime));
        } else {
            a1 = exactInput ? int128(int256(sprime)) : int128(-int256(sprime));
        }

        vm.prank(address(pm));
        hook.afterSwap(trader, key, params, toBalanceDelta(a0, a1), data);
    }

    function testInternalSwapFlagSkipsGaugesButCollectsFees() public {
        // Setup BMX pool for internal swaps
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

        // zeroForOne swap params; sentinel data for internal swap
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});
        bytes memory flagData = abi.encode(bytes4(0xDE1ABEEF));

        _callSwap(address(fp), key, sp, flagData);

        // 1. Internal path should route through collectFee with internal flag
        assertEq(fp.calls(), 1, "collectFee should be called once");
        assertTrue(fp.lastIsInternal(), "internal flag should be set");
        
        // 2. Daily gauge is poked even on internal swaps in the new model
        assertEq(daily.pokeCalls(), 1, "daily gauge should be poked");
        
        // 3. IncentiveGauge poked
        assertEq(inc.pokeCount(), 1, "incentive gauge should be poked");
    }

    function testNormalSwapStillUpdatesGauges() public {
        // Non-BMX pool to ensure normal swaps still work
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Normal swap without internal flag
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});
        
        _callSwap(address(0xCAFE), key, sp, "");

        // Should update gauges and collect regular fees
        assertEq(fp.calls(), 1, "regular fee should be collected");
        assertEq(fp.lastIsInternal(), false, "internal flag should not be set");
        assertEq(daily.pokeCalls(), 1, "daily gauge should be poked");
        assertEq(inc.pokeCount(), 1, "incentive gauge should be poked");
    }
} 