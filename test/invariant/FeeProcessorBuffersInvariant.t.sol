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

    uint256 internal totalBmxFees;        // raw fees sent via BMX pool (wBLT units)
    uint256 internal totalWbltFees;       // raw fees sent via OTHER/wBLT pool (wBLT units)
    uint256 internal totalInternalFees;   // raw fees from internal swaps (wBLT units)
    uint256 internal voterFromBmx;        // per-collection voter share accumulated for BMX pool (rounded per op)
    uint256 internal voterFromInternal;   // per-collection voter share accumulated for internal fees (rounded per op)

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
            IDailyEpochGauge(address(gauge))
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

        // Set buyback pool key for internal fee distribution
        fp.setBuybackPoolKey(bmxPoolKey);

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ ACTION
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(uint256 choice, uint256 amount) external {
        uint256 amt = bound(amount, 1, 1e24);
        uint256 action = choice % 3;
        if (action == 0) {
            fp.collectFee(bmxPoolKey, amt, false);
            totalBmxFees += amt;
            uint256 buybackPortion = (amt * fp.buybackBps()) / 10_000; // floor
            voterFromBmx += (amt - buybackPortion); // per-op rounding
        } else if (action == 1) {
            fp.collectFee(otherPoolKey, amt, false);
            totalWbltFees += amt;
        } else {
            // Model internal swap path
            fp.collectFee(bmxPoolKey, amt, true);
            totalInternalFees += amt;
            uint256 buybackInternal = (amt * fp.buybackBps()) / 10_000; // floor
            voterFromInternal += (amt - buybackInternal); // per-op rounding
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_wbltAccounting() public {
        // In the unified model, all fees are in wBLT.
        // The global voter buffer accumulates per-operation voter shares from ALL pools (including BMX and internal).
        // The OTHER pool's buyback buffer holds the buyback share of OTHER/wBLT fees (auto-flush is disabled here).
        uint256 pendingBuy = fp.pendingWbltForBuyback(otherPoolKey.toId());
        uint256 pendingVoter = fp.pendingWbltForVoter();
        // Expected equals: sum(OTHER fees) + sum(voter shares from BMX) + sum(voter shares from internal)
        uint256 expected = totalWbltFees + voterFromBmx + voterFromInternal;
        assertEq(pendingBuy + pendingVoter, expected, "wBLT fee mismatch");
    }
} 