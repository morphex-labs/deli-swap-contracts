// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal adapter exposing positionManager() used by tests so the gauge can look up PoolKey.
contract MockAdapterForKeys {
    address public pm;
    constructor(address _pm) { pm = _pm; }
    function positionManager() external view returns (address) { return pm; }
}


