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
        bytes memory ctorArgs = abi.encode(address(pm), address(fp), address(daily), address(inc), address(wblt), address(bmx), address(this));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);
        hook = new DeliHook{salt: salt}(IPoolManager(address(pm)), IFeeProcessor(address(fp)), IDailyEpochGauge(address(daily)), IIncentiveGauge(address(inc)), address(wblt), address(bmx), address(this));
    }

    uint24 constant FEE_PIPS = 3000;

    function _callSwap(address trader, PoolKey memory key, SwapParams memory params, bytes memory data) internal {
        vm.prank(address(pm));
        hook.beforeSwap(trader, key, params, data);

        bool exactInput = params.amountSpecified < 0;
        bool specifiedIs0 = params.zeroForOne ? exactInput : !exactInput;
        uint256 s0 = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);

        uint256 sprime;
        if (exactInput && ((Currency.unwrap(key.currency0) == address(wblt)) == specifiedIs0)) {
            unchecked { sprime = s0 - (s0 * FEE_PIPS) / (1_000_000 + FEE_PIPS); }
        } else {
            sprime = s0;
        }

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

    function testFeeForwarded_WbltPool() public {
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
        
        // zeroForOne true (OTHER -> wBLT), exactInput 1e18
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});

        _callSwap(address(0xAAAA), key, sp, "");

        assertEq(fp.calls(), 1, "fee not forwarded");
        // With mock returning 3000 (0.3%) fee
        uint256 expected = 3000000000000000; // 0.003 ETH (0.3% of 1e18)
        assertEq(fp.lastAmount(), expected);
        // fee currency should be wBLT
        
        // no further asserts
        // gauge side-effects (keeperless: only poke is required)
        assertEq(daily.pokeCalls(), 1);
        assertEq(inc.pokeCount(), 1);
    }

    function testFeeForwarded_BmxPool() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        // zeroForOne false (wBLT -> BMX) exactInput 2e18
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:-2e18, sqrtPriceLimitX96:0});
        _callSwap(address(0xBBBB), key, sp, "");

        // exact input, fee currency == specified? specifiedIs0 for zeroForOne=false & exactInput=false => specifiedIs0=false
        // fee currency is token1=wBLT => feeMatchesSpecified=false, so fee measured from actual traded S' = S0 (=2e18)
        // exact input and fee currency == specified → expect ceil(S0 * fee / (1e6 + fee))
        uint256 denom = 1_000_000 + 3000;
        uint256 num = uint256(2e18) * 3000;
        uint256 expected = (num + denom - 1) / denom;
        assertEq(fp.lastAmount(), expected);
    }

    function testInternalSwapFlagOnBmxPool() public {
        // BMX pool is required for internal swaps
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        bmx.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        bmx.approve(address(hook), type(uint256).max);
        
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});
        bytes memory flagData = abi.encode(bytes4(0xDE1ABEEF));
        _callSwap(address(fp), key, sp, flagData);
        // unified path: collectFee called once, internal flag set
        assertEq(fp.calls(), 1, "collectFee should be called once");
        assertTrue(fp.lastIsInternal(), "internal flag not set");
        uint256 expectedFee = (1e18 * 3000) / 1_000_000;
        assertEq(fp.lastAmount(), expectedFee, "incorrect internal fee amount");
    }

    function testWbltInputSwapFee() public {
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
        
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:-1e18, sqrtPriceLimitX96:0});

        _callSwap(TRADER, key, sp, "");
        (, address tkTo, uint256 tkAmt) = pm.lastTake();
        assertEq(tkTo, address(fp));
        // exact input, specifiedIs0 = params.zeroForOne ? exactInput : !exactInput = false
        // fee currency is token1 (wBLT), mismatch => fee on actual S' = S0
        // exact input and fee currency == specified → expect ceil(S0 * fee / (1e6 + fee))
        uint256 denom2 = 1_000_000 + 3000;
        uint256 num2 = uint256(1e18) * 3000;
        uint256 expected = (num2 + denom2 - 1) / denom2;
        assertEq(tkAmt, expected);
    }

    function testExactOutputNoPullFromSender() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        wblt.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        wblt.approve(address(hook), type(uint256).max);

        // Exact output swap: wBLT -> OTHER (positive amount)
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:1e18, sqrtPriceLimitX96:0});

        _callSwap(TRADER, key, sp, "");
        (, address tkTo, uint256 tkAmt) = pm.lastTake();
        assertEq(tkTo, address(fp));
        // For exact output, fee is calculated on the unspecified (input) amount
        // With mock returning 3000 (0.3%) fee
        uint256 expected = 3000000000000000; // 0.003 ETH (0.3% of 1e18)
        assertEq(tkAmt, expected);
    }
} 