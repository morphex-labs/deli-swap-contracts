// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/libraries/TimeLibrary.sol";

/// @title TimeLibraryTest
/// @notice Unit tests for TimeLibrary’s helpers.
contract TimeLibraryTest is Test {
    using TimeLibrary for uint256;

    uint256 internal constant DAY = 1 days;

    /*//////////////////////////////////////////////////////////////
                              dayStart
    //////////////////////////////////////////////////////////////*/

    function testDayStart_Aligned() public {
        uint256 ts = 1700000000; // some constant timestamp
        uint256 aligned = ts - (ts % DAY);
        uint256 result = TimeLibrary.dayStart(ts);
        assertEq(result, aligned);
    }

    function testDayStart_Fuzz(uint256 ts) public {
        // Bound to reasonable range to avoid overflow in later math
        ts = bound(ts, 0, 10_000 days);
        uint256 expected = ts - (ts % DAY);
        assertEq(TimeLibrary.dayStart(ts), expected);
    }

    /*//////////////////////////////////////////////////////////////
                               dayNext
    //////////////////////////////////////////////////////////////*/

    function testDayNext() public {
        uint256 ts = 1700000000;
        uint256 start = TimeLibrary.dayStart(ts);
        uint256 next = TimeLibrary.dayNext(ts);
        assertEq(next, start + DAY);
    }

    function testDayNext_Fuzz(uint256 ts) public {
        ts = bound(ts, 0, 10_000 days);
        uint256 start = TimeLibrary.dayStart(ts);
        uint256 next = TimeLibrary.dayNext(ts);
        assertEq(next, start + DAY);
        // Ensure strictly greater than input
        assertGt(next, ts);
        // And within 1 day ahead
        assertLe(next - ts, DAY);
    }
} 