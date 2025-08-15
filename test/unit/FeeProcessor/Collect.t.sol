// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FeeProcessor} from "src/FeeProcessor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockSwapPoolManager} from "test/mocks/MockSwapPoolManager.sol";

/// @notice FeeProcessor unit tests focusing on fee collection & state accounting
contract FeeProcessor_CollectTest is Test {
    using PoolIdLibrary for PoolKey;

    FeeProcessor fp;
    MockDailyEpochGauge gauge;

    address constant HOOK = address(uint160(0xbeef));
    address constant VOTER = address(uint160(0xcafe));

    // ERC20 token contracts
    MockERC20 bmxToken;
    MockERC20 wbltToken;
    MockERC20 otherToken;

    // Mock pool manager to prevent automatic buffer flushes
    MockSwapPoolManager mockPM;

    // Pool keys and IDs
    PoolKey bmxPoolKey;
    PoolId bmxPid;

    function setUp() public {
        // Deploy mock tokens
        bmxToken = new MockERC20("BMX", "BMX", 18);
        wbltToken = new MockERC20("WBLT", "WBLT", 18);
        otherToken = new MockERC20("OTHER", "OTHER", 18);
        
        // Deploy mock pool manager (with _isUnlocked = false by default)
        mockPM = new MockSwapPoolManager();
        
        gauge = new MockDailyEpochGauge();
        fp = new FeeProcessor(
            IPoolManager(address(mockPM)),
            HOOK,
            address(wbltToken),
            address(bmxToken),
            IDailyEpochGauge(gauge)
        );

        // Initialize bmxPoolKey
        bmxPoolKey = _makePoolKey(address(bmxToken), address(wbltToken));
        bmxPid = bmxPoolKey.toId();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _makePoolKey(address c0, address c1) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3_000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    function testCollectFeeWithNonHookReverts() public {
        PoolKey memory key = _makePoolKey(address(bmxToken), address(wbltToken));
        vm.expectRevert(DeliErrors.NotHook.selector);
        fp.collectFee(key, 1000, false);
    }

    function testCollectFeeBmxPoolSplit() public {
        PoolKey memory key = _makePoolKey(address(bmxToken), address(wbltToken)); // currency0 is BMX ⇒ BMX pool
        uint256 amount = 1_000 ether;

        // Set buyback pool key
        fp.setBuybackPoolKey(key);
        
        // Set the mock to prevent auto-flush by making swap revert
        mockPM.setRevertOnSwap(true);

        // act as hook
        vm.prank(HOOK);
        fp.collectFee(key, amount, false);

        uint256 buybackPortion = (amount * fp.buybackBps()) / 10_000; // 97%
        uint256 voterPortion = amount - buybackPortion; // 3%

        // With swap revert enabled, auto-flush fails; gauge unchanged
        assertEq(gauge.rewards(key.toId()), 0, "Gauge should not change on failed auto-flush");

        // Buffers updated
        assertEq(fp.pendingWbltForBuyback(key.toId()), buybackPortion, "pendingWbltForBuyback incorrect");
        assertEq(fp.pendingWbltForVoter(), voterPortion, "pendingWbltForVoter incorrect");
    }

    function testCollectFeeWbltPoolSplit() public {
        PoolKey memory key = _makePoolKey(address(otherToken), address(wbltToken)); // token1 is wBLT, token0 is other ⇒ non-BMX pool
        uint256 amount = 2_000 ether;

        vm.prank(HOOK);
        fp.collectFee(key, amount, false);

        uint256 buybackPortion = (amount * fp.buybackBps()) / 10_000;
        uint256 voterPortion = amount - buybackPortion;

        // No gauge addRewards expected
        assertEq(gauge.rewards(key.toId()), 0, "Gauge should not receive rewards for wBLT pool");

        // Internal counters
        assertEq(fp.pendingWbltForBuyback(key.toId()), buybackPortion, "pendingWbltForBuyback incorrect");
        assertEq(fp.pendingWbltForVoter(), voterPortion, "pendingWbltForVoter incorrect");
    }

    function testSetBuybackPoolKey() public {
        PoolKey memory key = _makePoolKey(address(bmxToken), address(wbltToken));

        fp.setBuybackPoolKey(key);
        assertTrue(fp.buybackPoolSet(), "buybackPoolSet not true");
    }

    function testSetBuybackPoolKeyWrongOrderReverts() public {
        PoolKey memory badKey = _makePoolKey(address(otherToken), address(wbltToken)); // currency0 != BMX
        vm.expectRevert(DeliErrors.InvalidPoolKey.selector);
        fp.setBuybackPoolKey(badKey);
    }
} 