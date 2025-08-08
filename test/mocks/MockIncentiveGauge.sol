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
    function initPool(PoolId /* pid */, int24 /* initialTick */) external override {}

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
    
    // Subscription callbacks (from ISubscriber interface)
    function notifySubscribe(uint256, bytes memory) external override {}
    function notifyUnsubscribe(uint256) external override {}
    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external override {}
    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external override {}
} 