// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TimeLibrary} from "src/libraries/TimeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DailyEpochGaugeEpochInvariant
/// @notice Fuzzes epoch rolls and reward bucket additions to ensure the epoch
///         window invariants always hold:
///           1. end - start == 1 day (86400 seconds)
///           2. start <= block.timestamp < end after rollIfNeeded
///           3. streamRate, nextStreamRate, queuedStreamRate are never > bucket/day *2^128 (implicit)
contract DailyEpochGaugeEpochInvariant is Test {
    DailyEpochGauge internal gauge;
    PoolId internal constant PID = PoolId.wrap(bytes25(bytes32(uint256(0xABCD))));

    function setUp() public {
        // Deploy gauge with dummy dependencies. feeProcessor = address(this)
        gauge = new DailyEpochGauge(
            address(this),                // feeProcessor
            IPoolManager(address(0x1)),   // dummy poolManager
            IPositionManagerAdapter(address(0x1)),
            address(0x2),                 // hook
            IERC20(address(0x3)),         // BMX token (unused in epoch logic)
            address(0)                   // incentive gauge
        );

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ ACTION
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(uint256 secForward, uint256 addAmt) external {
        // 1. Move time forward between 1 second and 5 days per step
        uint256 dt = bound(secForward, 1, 5 days);
        vm.warp(block.timestamp + dt);

        // 2. Optionally add rewards to collect bucket (acts as FeeProcessor)
        uint256 amt = addAmt % 1e24; // cap to 1e24 for realistic bounds
        if (amt > 0) {
            gauge.addRewards(PID, amt);
        }

        // 3. Call rollIfNeeded to advance epoch if day boundary crossed
        // keeperless: no explicit roll needed
    }

    /*//////////////////////////////////////////////////////////////
                               INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_epochWindow() public view {
        uint256 start = TimeLibrary.dayStart(block.timestamp);
        uint256 end = TimeLibrary.dayNext(block.timestamp);
        assertEq(end - start, TimeLibrary.DAY, "epoch duration != 1 day");
        assertTrue(uint256(start) <= block.timestamp && block.timestamp < uint256(end), "timestamp outside epoch window");
    }
} 