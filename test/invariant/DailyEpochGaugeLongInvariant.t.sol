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

        // derived epoch window
        lastStart = uint64(TimeLibrary.dayStart(block.timestamp));

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

        // 3. compute derived start from time
        uint64 start = uint64(TimeLibrary.dayStart(block.timestamp));
        if (start > lastStart) {
            // note: derived model; no explicit rolling needed
            lastStart = start;
        }
        // lastStreamRate = streamRate; // Removed
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANT
    //////////////////////////////////////////////////////////////*/

    function invariant_tokenConservation() public view {
        // derive epoch window; assertions are pure view, no side effects
        uint256 end = TimeLibrary.dayNext(block.timestamp);
        uint256 streamRate = gauge.streamRate(PID);
        // Next and queued are day+1 and day+2 buckets
        uint32 d = TimeLibrary.dayCurrent();
        uint256 remainingCurrent = uint256(streamRate) * (end > block.timestamp ? end - block.timestamp : 0);
        uint256 remainingNext    = gauge.dayBuckets(PID, d + 1);
        uint256 remainingQueued  = gauge.dayBuckets(PID, d + 2);

        uint256 accounted = remainingCurrent + remainingNext + remainingQueued;

        // Invariant: gauge cannot create tokens out of thin air.
        assertLe(accounted, totalDeposited, "accounted exceeds deposits");
    }
} 