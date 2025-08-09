// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolKeys} from "src/interfaces/IPoolKeys.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal adapter exposing getPoolKeyFromPoolId used by IncentiveGauge.initPool in tests.
contract MockAdapterForKeys {
    address public pm;
    constructor(address _pm) { pm = _pm; }
    function positionManager() external view returns (address) { return pm; }
    function getPoolKeyFromPoolId(PoolId pid) external view returns (PoolKey memory k) {
        // Use provided PoolKeys provider to return a PoolKey; tests only need tickSpacing
        return IPoolKeys(pm).poolKeys(bytes25(PoolId.unwrap(pid)));
    }
}


