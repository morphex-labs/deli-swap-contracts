// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title FeeProcessorBuffersInvariant
/// @notice Fuzzes FeeProcessor.collectFee and asserts that the internal
///         accounting buffers match the cumulative fees received.
contract FeeProcessorBuffersInvariant is Test {
    /*//////////////////////////////////////////////////////////////
                                    TOKENS
    //////////////////////////////////////////////////////////////*/

    address constant BMX = address(0xB0B);
    address constant WBLT_ADDR = address(0xBEEF);
    address constant OTHER = address(0xCAFE);

    Currency constant WBLT = Currency.wrap(WBLT_ADDR);

    /*//////////////////////////////////////////////////////////////
                                   CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockDailyEpochGauge gauge;
    FeeProcessor fp;

    /*//////////////////////////////////////////////////////////////
                                  STATE TRACK
    //////////////////////////////////////////////////////////////*/

    uint256 internal totalBmxFees;   // fees sent via BMX pool
    uint256 internal totalWbltFees;  // fees sent via OTHER/wBLT pool

    PoolKey internal bmxPoolKey;
    PoolKey internal otherPoolKey;
    PoolId internal bmxPid;

    function setUp() public {
        gauge = new MockDailyEpochGauge();
        fp = new FeeProcessor(
            IPoolManager(address(0x1)), // poolManager unused for collectFee
            address(this),              // deliHook (sender)
            WBLT_ADDR,
            BMX,
            IDailyEpochGauge(address(gauge)),
            address(0xDEAD)
        );

        // craft PoolKeys
        bmxPoolKey = PoolKey({
            currency0: Currency.wrap(BMX),
            currency1: WBLT,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        otherPoolKey = PoolKey({
            currency0: Currency.wrap(OTHER),
            currency1: WBLT,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bmxPid = bmxPoolKey.toId();

        // whitelist this test as authorised hook sender
        vm.prank(address(this));
        // no different requirement – collectFee only has onlyHook modifier inside FeeProcessor which checks sender == deliHook
        // deliHook set as address(this) in constructor above so ok.

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ ACTION
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(bool useBmxPool, uint256 amount) external {
        uint256 amt = bound(amount, 1, 1e24);
        if (useBmxPool) {
            fp.collectFee(bmxPoolKey, amt);
            totalBmxFees += amt;
        } else {
            fp.collectFee(otherPoolKey, amt);
            totalWbltFees += amt;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_bmxAccounting() public {
        uint256 gaugeRewards = gauge.rewards(bmxPid);
        uint256 pendingBmxVoter = fp.pendingBmxForVoter();
        // buyback buffer never holds BMX (only wBLT)
        assertEq(gaugeRewards + pendingBmxVoter, totalBmxFees, "BMX fee mismatch");
    }

    function invariant_wbltAccounting() public {
        uint256 pendingBuy = fp.pendingWbltForBuyback();
        uint256 pendingVoter = fp.pendingWbltForVoter();
        assertEq(pendingBuy + pendingVoter, totalWbltFees, "wBLT fee mismatch");
    }
} 