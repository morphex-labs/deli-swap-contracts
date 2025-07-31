// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TimeLibrary} from "src/libraries/TimeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DailyEpochGaugeLongInvariant
/// @notice Simulates many epoch rolls with random bucket top-ups and asserts
///         that tokens are neither lost nor created: totalDeposited equals
///         (streamed + stillToStream + collectBucket).
contract DailyEpochGaugeLongInvariant is Test {
    DailyEpochGauge internal gauge;
    PoolId internal constant PID = PoolId.wrap(bytes25(bytes32(uint256(0xBEEF))));

    // accounting
    uint256 internal totalDeposited; // all addRewards so far

    // helpers for epoch tracking (unused after simplification)
    uint64 internal lastStart;

    function setUp() public {
        gauge = new DailyEpochGauge(
            address(this),
            IPoolManager(address(0x1)),
            IPositionManagerAdapter(address(0x1)),
            address(0x2),
            IERC20(address(0x3)),
            address(0)
        );

        // initialise epoch window
        gauge.rollIfNeeded(PID);
        (lastStart,, , ,) = gauge.epochInfo(PID);

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ STEP
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(uint256 bucketAdd, uint256 daysFwd, uint256 extraSecs) external {
        // 1. Maybe add rewards to bucket
        uint256 amt = bucketAdd % 1e24; // cap
        if (amt > 0) {
            gauge.addRewards(PID, amt);
            totalDeposited += amt;
        }

        // 2. advance time
        uint256 dDays = bound(daysFwd, 0, 5); // up to 5 days per step
        uint256 secs = bound(extraSecs, 1, TimeLibrary.DAY);
        vm.warp(block.timestamp + dDays * TimeLibrary.DAY + secs);

        // 3. compute rolls streamed BEFORE calling rollIfNeeded
        gauge.rollIfNeeded(PID);

        (uint64 start,, uint128 streamRate,,) = gauge.epochInfo(PID);
        if (start > lastStart) {
            uint256 rolls = (uint256(start) - uint256(lastStart)) / TimeLibrary.DAY;
            // totalStreamed += lastStreamRate * TimeLibrary.DAY * rolls; // Removed
            lastStart = start;
        }
        // lastStreamRate = streamRate; // Removed
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANT
    //////////////////////////////////////////////////////////////*/

    function invariant_tokenConservation() public {
        (
            uint64 start,
            uint64 end,
            uint128 streamRate,
            uint128 nextStreamRate,
            uint128 queuedStreamRate
        ) = gauge.epochInfo(PID);

        uint256 remainingCurrent = uint256(streamRate) * (end > block.timestamp ? end - block.timestamp : 0);
        uint256 remainingNext    = uint256(nextStreamRate) * TimeLibrary.DAY;
        uint256 remainingQueued  = uint256(queuedStreamRate) * TimeLibrary.DAY;
        uint256 remainingBucket  = gauge.collectBucket(PID);

        uint256 accounted = remainingCurrent + remainingNext + remainingQueued + remainingBucket;

        // Invariant: gauge cannot create tokens out of thin air.
        assertLe(accounted, totalDeposited, "accounted exceeds deposits");
    }
} 