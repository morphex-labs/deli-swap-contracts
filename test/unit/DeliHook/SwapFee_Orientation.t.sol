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
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract DeliHook_SwapFee_OrientationTest is Test {
    MockHookPoolManager pm;
    MockFeeProcessor fp;
    MockDailyEpochGauge daily;
    MockIncentiveGauge inc;
    DeliHook hook;

    MintableERC20 wblt;
    MintableERC20 bmx;
    address constant OTHER = address(0xC0FFEE);

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

    uint24 constant FEE_PIPS = 3000;

    function _callSwap(address trader, PoolKey memory key, SwapParams memory params, bytes memory data) internal {
        vm.prank(address(pm));
        hook.beforeSwap(trader, key, params, data);

        bool exactInput = params.amountSpecified < 0;
        bool specifiedIs0 = params.zeroForOne ? exactInput : !exactInput;
        bool feeMatchesSpecified = (Currency.unwrap(key.currency0) == address(wblt)) == specifiedIs0;
        uint256 s0 = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
        uint256 fee = (s0 * FEE_PIPS + (1_000_000 - 1)) / 1_000_000; // ceil(s0 * fee / 1e6)
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

    // ---------------------------
    // WBLT as token0 orientation
    // ---------------------------

    function testWbltToken0_ExactInput_SpecifiedMatchesFeeCurrency() public {
        // Pool: wBLT (token0), OTHER (token1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(OTHER),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide wBLT to PoolManager for fee collection
        wblt.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        wblt.approve(address(hook), type(uint256).max);

        // zeroForOne true: wBLT -> OTHER, exact input
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});

        _callSwap(address(0xA1), key, sp, "");

        // With exact input and fee on specified, forward base fee = ceil(S0*fee/1e6)
        uint256 expected = (uint256(1e18) * FEE_PIPS + (1_000_000 - 1)) / 1_000_000;
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
    }

    function testWbltToken0_ExactOutput_SpecifiedMatchesFeeCurrency() public {
        // Pool: wBLT (token0), OTHER (token1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(OTHER),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide wBLT to PoolManager for fee collection
        wblt.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        wblt.approve(address(hook), type(uint256).max);

        // zeroForOne false: output OTHER (token1), exact output
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:2e18, sqrtPriceLimitX96:0});

        _callSwap(address(0xA2), key, sp, "");

        uint256 expected = 2e18 * 3000 / 1_000_000; // fee in wBLT units at px=1
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
    }

    // ---------------------------
    // BMX as token1 orientation
    // ---------------------------

    function testBmxToken1_ExactInput_SpecifiedDiffersFromFeeCurrency() public {
        // Pool: wBLT (token0), BMX (token1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(address(bmx)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide BMX to PoolManager for fee collection
        bmx.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        bmx.approve(address(hook), type(uint256).max);

        // zeroForOne false: wBLT -> BMX, exact input (specified token0, fee token1)
        SwapParams memory sp = SwapParams({zeroForOne:false, amountSpecified:-3e18, sqrtPriceLimitX96:0});

        _callSwap(address(0xB1), key, sp, "");

        uint256 expected = 3e18 * 3000 / 1_000_000; // fee in BMX units at px=1
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
    }

    function testBmxToken1_ExactOutput_SpecifiedMatchesFeeCurrency() public {
        // Pool: wBLT (token0), BMX (token1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(address(bmx)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide BMX to PoolManager for fee collection
        bmx.mintExternal(address(pm), 10e18);
        vm.prank(address(pm));
        bmx.approve(address(hook), type(uint256).max);

        // zeroForOne true: output BMX (token1), exact output (specified token1 == fee token1)
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:5e18, sqrtPriceLimitX96:0});

        _callSwap(address(0xB2), key, sp, "");

        uint256 expected = 5e18 * 3000 / 1_000_000; // fee in BMX units at px=1
        assertEq(fp.lastAmount(), expected);
        assertEq(fp.calls(), 1);
    }

    // ---------------------------
    // Price conversion cases (price != 1)
    // ---------------------------

    function testPriceConversion_Token0ToToken1_FeeInToken1_Price2x() public {
        // Set price: sqrtPriceX96 = 2 * Q96 => price = 4
        pm.setSqrtPriceX96(uint160((2) * (1 << 96)));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(address(bmx)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide BMX to PoolManager (fee token)
        bmx.mintExternal(address(pm), 10e24); // large buffer for take()
        vm.prank(address(pm));
        bmx.approve(address(hook), type(uint256).max);

        // token0 specified (wBLT), fee in token1 (BMX): exact input 1e18
        // Use zeroForOne=true so specified token is token0 on exact input
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:-1e18, sqrtPriceLimitX96:0});
        _callSwap(address(0xC1), key, sp, "");

        // exact input and fee on specified, price=4 converts only for cross-currency; here fee token == specified
        uint256 expected = (uint256(1e18) * FEE_PIPS + (1_000_000 - 1)) / 1_000_000;
        assertEq(fp.lastAmount(), expected);
    }

    function testPriceConversion_Token1ToToken0_FeeInToken0_Price2x() public {
        // Set price: sqrtPriceX96 = 2 * Q96 => price = 4
        pm.setSqrtPriceX96(uint160((2) * (1 << 96)));

        // Use a non-BMX pool so fee token is wBLT (token0)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(OTHER),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide wBLT to PoolManager (fee token)
        wblt.mintExternal(address(pm), 10e24);
        vm.prank(address(pm));
        wblt.approve(address(hook), type(uint256).max);

        // specified token1 (OTHER), fee token0 (wBLT): exact output 2e18 OTHER
        // zeroForOne=true makes specified token = output token (token1) for exact output
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:2e18, sqrtPriceLimitX96:0});
        _callSwap(address(0xC2), key, sp, "");

        // base fee in specified = 2e18 * 0.003 = 6e15; convert token1->token0: / price (4) ceiled => 1500000000000000
        assertEq(fp.lastAmount(), 1500000000000000);
    }

    // ---------------------------
    // Delta semantics (specified match vs mismatch)
    // ---------------------------

    function testDeltas_SpecifiedMatchesFeeCurrency_BmxPool_ExactOutput_Price2x() public {
        // Set price: sqrtPriceX96 = 2 * Q96 => price = 4
        pm.setSqrtPriceX96(uint160((2) * (1 << 96)));

        // BMX pool: wBLT (token0) / BMX (token1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(address(bmx)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide BMX to PoolManager (fee token)
        bmx.mintExternal(address(pm), 10e24);
        vm.prank(address(pm));
        bmx.approve(address(hook), type(uint256).max);

        // zeroForOne true, exact output of token1 (BMX) => specified token is token1 (fee token)
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:2e18, sqrtPriceLimitX96:0});

        vm.prank(address(pm));
        ( , BeforeSwapDelta bd, ) = hook.beforeSwap(address(0xD1), key, sp, "");
        int128 beforeSpecified = BeforeSwapDeltaLibrary.getSpecifiedDelta(bd);

        // Simulate actual traded amount in specified-token units (exact output => s' = S0)
        int128 a0 = 0;
        int128 a1 = 0;
        // specified token is token1 (OTHER) for zeroForOne=true and exact output
        a1 = int128(-int256(uint256(sp.amountSpecified))); // negative on output side

        vm.prank(address(pm));
        ( , int128 afterUnspecified ) = hook.afterSwap(address(0xD1), key, sp, toBalanceDelta(a0,a1), "");

        // With wBLT-only fee currency, fee is in token0 (wBLT), specified is token1 (BMX)
        // beforeSpecified stays 0; afterUnspecified returns fee in unspecified token (token0)
        // base fee in specified (BMX) = 2e18 * 0.003 = 6e15; convert token1->token0: / 4, ceil => 1500000000000000
        assertEq(int256(beforeSpecified), int256(0));
        assertEq(afterUnspecified, int128(uint128(1500000000000000)));
    }

    function testDeltas_SpecifiedDiffersFromFeeCurrency_WbltPool_ExactOutput_Price2x() public {
        // Set price: sqrtPriceX96 = 2 * Q96 => price = 4
        pm.setSqrtPriceX96(uint160((2) * (1 << 96)));

        // Non-BMX pool: OTHER(token1)/wBLT(token0) => fee currency is wBLT (token0)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(wblt)),
            currency1: Currency.wrap(OTHER),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Provide wBLT to PM (fee token)
        wblt.mintExternal(address(pm), 10e24);
        vm.prank(address(pm));
        wblt.approve(address(hook), type(uint256).max);

        // zeroForOne true, exact output of token1 (OTHER) => specified = token1; fee token is token0 (mismatch)
        SwapParams memory sp = SwapParams({zeroForOne:true, amountSpecified:1e18, sqrtPriceLimitX96:0});

        vm.prank(address(pm));
        ( , BeforeSwapDelta bd, ) = hook.beforeSwap(address(0xD2), key, sp, "");
        int128 beforeSpecified = BeforeSwapDeltaLibrary.getSpecifiedDelta(bd);

        // Simulate actual traded amount in specified-token units (exact output => s' = S0)
        int128 a0 = 0;
        int128 a1 = 0;
        // specified token is token1 (OTHER) for zeroForOne=true and exact output
        a1 = int128(-int256(uint256(sp.amountSpecified))); // negative on output side

        vm.prank(address(pm));
        ( , int128 afterUnspecified ) = hook.afterSwap(address(0xD2), key, sp, toBalanceDelta(a0,a1), "");

        // base fee in specified (OTHER) = 1e18 * 0.003 = 3e15; convert OTHER->wBLT: / 4, ceil => 750000000000000
        assertEq(beforeSpecified, 0);
        assertEq(afterUnspecified, int128(uint128(750000000000000)));
    }
}


