// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract MockIncentiveGauge is IIncentiveGauge {
    bool public called;
    uint256 public pokeCount;

    function pokePool(PoolKey calldata) external override {
        pokeCount += 1;
    }

    // hook-based pool initialization (no-op in mock)
    function initPool(PoolKey memory key, int24 initialTick) external override {}

    // View helper
    function poolTokensOf(PoolId) external pure returns (IERC20[] memory arr) {
        arr = new IERC20[](0);
    }

    function claim(uint256, IERC20, address) external pure returns (uint256) { return 0; }
    function claimAllForOwner(PoolId[] calldata, address) external {
        called = true;
    }

    // updatePosition noop
    function updatePosition(
        PoolKey calldata,
        address,
        int24,
        int24,
        bytes32,
        uint128
    ) external {}
    
    // Context-based subscription callbacks (no-ops in mock)
    function notifySubscribeWithContext(
        uint256,
        bytes32,
        bytes32,
        int24,
        int24,
        int24,
        uint128,
        address
    ) external override {}

    function notifyUnsubscribeWithContext(
        uint256,
        bytes32,
        bytes32,
        int24,
        int24,
        uint128
    ) external override {}

    function notifyBurnWithContext(
        uint256,
        bytes32,
        bytes32,
        address,
        int24,
        int24,
        int24,
        uint128
    ) external override {}

    function notifyModifyLiquidityWithContext(
        uint256,
        bytes32,
        bytes32,
        int24,
        int24,
        int24,
        int256,
        uint128
    ) external override {}
} 