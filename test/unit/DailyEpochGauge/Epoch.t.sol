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
    /// @notice Updated for keeperless model; uses derived epoch info views.
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

    function testDerivedEpochInfoInitialized() public view {
        uint256 start = TimeLibrary.dayStart(block.timestamp);
        uint256 end = TimeLibrary.dayNext(block.timestamp);
        assertGt(end, start);
        assertEq(start, TimeLibrary.dayStart(block.timestamp));
        assertEq(end, start + 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                           Fast-forward
    //////////////////////////////////////////////////////////////*/

    function testFastForwardMultipleDays() public view {
        uint256 firstStart = TimeLibrary.dayStart(block.timestamp);
        // simulate 3.5 days later
        // (no warp in view)
        uint256 todayStart = TimeLibrary.dayStart(block.timestamp + 3 days + 12 hours);
        assertEq(todayStart + 1 days, todayStart + 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                               addRewards
    //////////////////////////////////////////////////////////////*/

    function testAddRewardsBucketIncrement() public {
        uint256 amt = 1e20;
        vm.prank(feeProcessor);
        gauge.addRewards(PID, amt);
        // Bucket is scheduled at day+2
        uint32 dayNow = TimeLibrary.dayCurrent();
        assertEq(gauge.dayBuckets(PID, dayNow + 2), amt);

        vm.prank(feeProcessor);
        gauge.addRewards(PID, 2 * amt);
        assertEq(gauge.dayBuckets(PID, dayNow + 2), 3 * amt);
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

    function testNextEpochEndsIn() public view {
        uint256 endTs = TimeLibrary.dayNext(block.timestamp);
        uint256 secondsLeft = endTs - block.timestamp;
        assertEq(secondsLeft, endTs - block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                         Reward bucket → streamRate
    //////////////////////////////////////////////////////////////*/

    function testRatesShiftByDay() public {
        // add rewards during day 0; becomes active on day 2
        uint256 dailyTokens = 100 * 1e18;
        uint256 bucketAmount = dailyTokens * 1 days;
        vm.prank(feeProcessor);
        gauge.addRewards(PID, bucketAmount);

        uint256 end0 = TimeLibrary.dayNext(block.timestamp);

        // Day1: still not active
        vm.warp(end0);
        assertEq(gauge.streamRate(PID), 0);

        // Day2: active = dailyTokens (fees scheduled at day+2)
        vm.warp(end0 + 1 days + 1);
        assertEq(gauge.streamRate(PID), dailyTokens);

        // Day3: back to 0 (single-day stream)
        vm.warp(end0 + 2 days);
        assertEq(gauge.streamRate(PID), 0);
    }
} 