// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRewardDistributor
interface IRewardDistributor {
    function setTokensPerInterval(uint256) external;
}
