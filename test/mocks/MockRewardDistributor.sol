// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRewardDistributor} from "src/interfaces/IRewardDistributor.sol";

/// @notice Minimal mock implementing setTokensPerInterval and tracking last value.
contract MockRewardDistributor is IRewardDistributor {
    uint256 public lastTokensPerInterval;

    function setTokensPerInterval(uint256 _t) external override {
        lastTokensPerInterval = _t;
    }
} 