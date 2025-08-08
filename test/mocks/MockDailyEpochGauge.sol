// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Minimal gauge stub that records rewards added per poolId; other functions are no-ops.
contract MockDailyEpochGauge is IDailyEpochGauge {
    mapping(PoolId => uint256) public rewards;

    uint256 public rollCalls; // kept for backward compat assertions in some tests
    uint256 public pokeCalls;

    // ---------------------------------------------------------------------
    // FeeProcessor integration
    // ---------------------------------------------------------------------
    function addRewards(PoolId poolId, uint256 amount) external override {
        rewards[poolId] += amount;
    }

    // ---------------------------------------------------------------------
    // Unused interface functions – empty implementations
    // ---------------------------------------------------------------------

    function rollIfNeeded(PoolId /* poolId */ ) external { rollCalls += 1; }

    function pokePool(PoolKey calldata /* key */ ) external override { pokeCalls += 1; }

    function updatePosition(
        PoolKey calldata /* key */ ,
        address /* owner */ ,
        int24 /* tickLower */ ,
        int24 /* tickUpper */ ,
        bytes32 /* salt */ ,
        uint128 /* liquidity */
    ) external {
        // no-op
    }

    function checkpointPosition(address /* owner */ , bytes32 /* positionKey */ ) external {
        // no-op
    }

    function claim(uint256 /* tokenId */ , address /* to */ ) external override returns (uint256) {
        return 0;
    }

    function claimAllForOwner(PoolId[] calldata /* pids */ , address /* owner */ )
        external
        override
        returns (uint256)
    {
        return 0;
    }

    function initPool(PoolId pid, int24 initialTick) external override {
        // No-op
    }
    
    // Subscription callbacks (from ISubscriber interface)
    function notifySubscribe(uint256, bytes memory) external override {}
    function notifyUnsubscribe(uint256) external override {}
    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external override {}
    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external override {}
} 