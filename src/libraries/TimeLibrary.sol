// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title TimeLibrary
 * @notice Collection of helpers for working with 24-hour UTC-aligned epochs.
 */
library TimeLibrary {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant WEEK = 7 days;

    /// @dev Returns the start of the current UTC day for `timestamp`.
    function dayStart(uint256 timestamp) internal pure returns (uint256) {
        return timestamp - (timestamp % DAY);
    }

    /// @dev Returns the start of the next UTC day following `timestamp`.
    function dayNext(uint256 timestamp) internal pure returns (uint256) {
        return timestamp - (timestamp % DAY) + DAY;
    }
}
