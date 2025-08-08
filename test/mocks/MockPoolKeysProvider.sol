// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolKeys} from "src/interfaces/IPoolKeys.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal IPoolKeys provider used by unit tests to supply tickSpacing.
contract MockPoolKeysProvider is IPoolKeys {
    function poolKeys(bytes25) external pure returns (PoolKey memory k) {
        k.tickSpacing = 60;
    }
}


