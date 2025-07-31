// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/DailyEpochGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TimeLibrary} from "src/libraries/TimeLibrary.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

// Simple ERC20 mock
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") { _mint(msg.sender, 1e24); }
}

/// @title DailyEpochGauge_EpochTest
/// @notice Focuses on `rollIfNeeded` initialisation & fast-forward behaviour.
contract DailyEpochGauge_EpochTest is Test {
    DailyEpochGauge gauge;
    MockToken bmx;

    // dummy addresses for deps
    address feeProcessor = address(0xA1);
    address poolManager   = address(0xA2);
    address posManager    = address(0xA3);
    address hook          = address(0xA4);

    PoolId internal constant PID = PoolId.wrap(bytes25(uint200(1)));

    function setUp() public {
        bmx = new MockToken();
        gauge = new DailyEpochGauge(
            feeProcessor,
            IPoolManager(poolManager),
            IPositionManagerAdapter(posManager),
            hook,
            IERC20(address(bmx)),
            address(0) // no incentive gauge
        );

        // start time deterministic: 2024-01-01 00:00:00 UTC (approx)
        vm.warp(1704067200);
    }

    /*//////////////////////////////////////////////////////////////
                     First-time initialisation
    //////////////////////////////////////////////////////////////*/

    function testInitialRollInitialisesEpoch() public {
        gauge.rollIfNeeded(PID);
        (uint64 start,uint64 end,,,) = gauge.epochInfo(PID);
        assertGt(end, start);
        assertEq(start, TimeLibrary.dayStart(block.timestamp));
        assertEq(end, start + 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                           Fast-forward
    //////////////////////////////////////////////////////////////*/

    function testFastForwardMultipleDays() public {
        // Day 0 initialise
        gauge.rollIfNeeded(PID);
        (,uint64 firstEnd,,,) = gauge.epochInfo(PID);

        // simulate 3.5 days later
        vm.warp(firstEnd + 3 days + 12 hours);
        gauge.rollIfNeeded(PID);

        (,uint64 newEnd,,,) = gauge.epochInfo(PID);
        // newEnd should be start-of-current-day + 1 day
        uint256 todayStart = TimeLibrary.dayStart(block.timestamp);
        assertEq(newEnd, todayStart + 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                               addRewards
    //////////////////////////////////////////////////////////////*/

    function testAddRewardsBucketIncrement() public {
        uint256 amt = 1e20;
        vm.prank(feeProcessor);
        gauge.addRewards(PID, amt);
        assertEq(gauge.collectBucket(PID), amt);

        // second call accumulates
        vm.prank(feeProcessor);
        gauge.addRewards(PID, 2 * amt);
        assertEq(gauge.collectBucket(PID), 3 * amt);
    }

    function testAddRewardsAccessControl() public {
        vm.expectRevert(DeliErrors.NotFeeProcessor.selector);
        gauge.addRewards(PID, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                         streamRate & nextEpochEndsIn
    //////////////////////////////////////////////////////////////*/

    function testStreamRateZeroBeforeRewards() public {
        assertEq(gauge.streamRate(PID), 0);
    }

    function testNextEpochEndsIn() public {
        gauge.rollIfNeeded(PID);
        (,uint64 endTs,,,) = gauge.epochInfo(PID);
        uint256 secondsLeft = gauge.nextEpochEndsIn(PID);
        assertEq(secondsLeft, endTs - block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                         Reward bucket → streamRate
    //////////////////////////////////////////////////////////////*/

    function testRollUpdatesStreamRate() public {
        // initialise day 0
        gauge.rollIfNeeded(PID);

        // add rewards during day 0
        uint256 dailyTokens = 100 * 1e18; // 100 tokens per sec expected (after div)
        uint256 bucketAmount = dailyTokens * 1 days; // 100 * 86_400
        vm.prank(feeProcessor);
        gauge.addRewards(PID, bucketAmount);

        // warp to end of Day0 and roll to Day1
        (,uint64 end0,,,) = gauge.epochInfo(PID);
        vm.warp(end0);
        gauge.rollIfNeeded(PID);

        // After first roll streamRate still 0; nextStreamRate still 0; queued filled
        (,, uint128 srDay1,uint128 nextDay1,uint128 queued1) = gauge.epochInfo(PID);
        assertEq(srDay1, 0);
        assertEq(nextDay1, 0);
        assertEq(queued1, dailyTokens);

        // warp to end of Day1 and roll to Day2
        vm.warp(end0 + 1 days);
        gauge.rollIfNeeded(PID);

        // After second roll streamRate still 0; nextStreamRate == dailyTokens
        (,, uint128 srDay2,uint128 nextDay2,uint128 queued2) = gauge.epochInfo(PID);
        queued2; // silence unused
        assertEq(srDay2, 0);
        assertEq(nextDay2, dailyTokens);

        // warp to end of Day2 and roll to Day3
        vm.warp(end0 + 2 days);
        gauge.rollIfNeeded(PID);

        (,, uint128 srDay3,,) = gauge.epochInfo(PID);
        assertEq(srDay3, dailyTokens);
        assertEq(gauge.collectBucket(PID), 0);
    }
} 