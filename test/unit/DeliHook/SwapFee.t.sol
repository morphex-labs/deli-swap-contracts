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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeliHook_SwapFeeTest is Test {
    using PoolIdLibrary for PoolKey;

    MockHookPoolManager pm;
    MockFeeProcessor fp;
    MockDailyEpochGauge daily;
    MockIncentiveGauge inc;
    DeliHook hook;

    MintableERC20 wblt;
    MintableERC20 bmx;
    address constant OTHER = address(0x123);
    address constant TRADER = address(0xBEEF);

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
        (address addr, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);
        hook = new DeliHook{salt: salt}(IPoolManager(address(pm)), IFeeProcessor(address(fp)), IDailyEpochGauge(address(daily)), IIncentiveGauge(address(inc)), address(wblt), address(bmx));
    }

    function _callSwap(address trader, PoolKey memory key, SwapParams memory params, bytes memory data) internal {
        vm.prank(address(pm));
        hook.beforeSwap(trader, key, params, data);
        vm.prank(address(pm));
        hook.afterSwap(trader, key, params, toBalanceDelta(0,0), data);
    }

    function testFeeForwarded_WbltPool() public {
        // pool with wBLT as currency1, other as currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        // zeroForOne true (OTHER -> wBLT), exactInput 1e18
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});

        _callSwap(address(0xAAAA), key, sp, "");

        assertEq(fp.calls(), 1, "fee not forwarded");
        uint256 expected = 1e18 * 3000 / 1_000_000;
        assertEq(fp.lastAmount(), expected);
        // fee currency should be wBLT
        // no further asserts
        // gauge side-effects
        assertEq(daily.rollCalls(), 1);
        assertEq(daily.pokeCalls(), 1);
        assertEq(inc.pokeCount(), 1);
    }

    function testFeeForwarded_BmxPool() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        // zeroForOne false (wBLT -> BMX) exactInput 2e18
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:-2e18, sqrtPriceLimitX96:0});
        _callSwap(address(0xBBBB), key, sp, "");

        uint256 expected = 2e18 * 3000 / 1_000_000;
        assertEq(fp.lastAmount(), expected);
        // fee token BMX
        // no further asserts on key
    }

    function testInternalSwapFlagBypass() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});
        bytes memory flagData = abi.encode(bytes4(0xDE1ABEEF));
        _callSwap(address(0xAAAA), key, sp, flagData);
        // ensure no fee forwarded
        assertEq(fp.calls(), 0);
    }

    function testPullFromSenderBranch() public {
        // Regular pool but swap direction wBLT -> OTHER so fee pulled from trader
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        // Mint wBLT to TRADER so hook can pull fee using transferFrom
        wblt.mintExternal(TRADER, 5e18);

        // Grant allowance from TRADER to DeliHook
        vm.prank(TRADER);
        IERC20(address(wblt)).approve(address(hook), type(uint256).max);

        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:-1e18, sqrtPriceLimitX96:0});

        _callSwap(TRADER, key, sp, "");

        // PM should have been synced and take called
        assertEq(Currency.unwrap(pm.lastSyncCurrency()), address(wblt));
        (, address tkTo, uint256 tkAmt) = pm.lastTake();
        assertEq(tkTo, address(fp));
        uint256 expected = 1e18 * 3000 / 1_000_000;
        assertEq(tkAmt, expected);
    }
} 