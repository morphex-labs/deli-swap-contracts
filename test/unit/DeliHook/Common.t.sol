// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {DeliHook} from "src/DeliHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

contract DeliHook_CommonTest is Test {
    DeliHook hook;
    address constant WBLT = address(0x1111);
    address constant BMX  = address(0x2222);
    MockHookPoolManager pm;
    MockDailyEpochGauge daily;
    MockIncentiveGauge inc;

    function setUp() public {
        pm = new MockHookPoolManager();
        daily = new MockDailyEpochGauge();
        inc = new MockIncentiveGauge();
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(pm)),
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(daily)),
            IIncentiveGauge(address(inc)),
            WBLT,
            BMX,
            address(this)  // owner
        );
        
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);
        hook = new DeliHook{salt: salt}(IPoolManager(address(pm)), IFeeProcessor(address(0)), IDailyEpochGauge(address(daily)), IIncentiveGauge(address(inc)), WBLT, BMX, address(this));

        hook.setFeeProcessor(address(0xBEEF));
        hook.setDailyEpochGauge(address(daily));
        hook.setIncentiveGauge(address(inc));
    }

    function _makePoolKey(address c0, address c1) internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function testBeforeInitializeRevertsIfNoWBLT() public {
        PoolKey memory key = _makePoolKey(address(0xAAA), address(0xBBB)); // no wBLT
        vm.expectRevert(DeliErrors.WbltMissing.selector);
        vm.prank(address(pm));
        hook.beforeInitialize(address(this), key, 0);
    }

    function testBeforeInitializeSucceedsWhenWBLTIsCurrency0() public {
        PoolKey memory key = _makePoolKey(WBLT, address(0xAAA));
        // Register fee before initialization
        hook.registerPoolFee(key.currency0, key.currency1, key.tickSpacing, 3000);
        vm.prank(address(pm));
        bytes4 sel = hook.beforeInitialize(address(this), key, 0);
        assertEq(sel, hook.beforeInitialize.selector);
    }

    function testBeforeInitializeSucceedsWhenWBLTIsCurrency1() public {
        PoolKey memory key = _makePoolKey(address(0xAAA), WBLT);
        // Register fee before initialization
        hook.registerPoolFee(key.currency0, key.currency1, key.tickSpacing, 3000);
        vm.prank(address(pm));
        bytes4 sel = hook.beforeInitialize(address(this), key, 0);
        assertEq(sel, hook.beforeInitialize.selector);
    }
} 