// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title RangePosition
 * @notice Library for per-position reward accrual and helper utilities used by
 *         both DailyEpochGauge and IncentiveGauge. Handles snapshotting of the
 *         cumulative rewards-per-liquidity inside a position’s tick range and
 *         maintains per-owner position indices.
 */
library RangePosition {
    struct State {
        // snapshot of rewardsPerLiquidityInsideX128 when we last checkpointed
        uint256 rewardsPerLiquidityLastX128;
        // rewards accrued but not yet claimed
        uint256 rewardsAccrued;
    }

    /// @notice Update accrued rewards based on latest global accumulator.
    function accrue(State storage self, uint128 positionLiquidity, uint256 rewardsPerLiquidityInsideX128)
        internal
        returns (uint256 rewards)
    {
        unchecked {
            uint256 delta = rewardsPerLiquidityInsideX128 - self.rewardsPerLiquidityLastX128;

            rewards = FullMath.mulDiv(delta, positionLiquidity, FixedPoint128.Q128);

            self.rewardsAccrued += rewards;
            self.rewardsPerLiquidityLastX128 = rewardsPerLiquidityInsideX128;
        }
    }

    /// @notice Claim any accrued rewards, resetting the counter.
    function claim(State storage self) internal returns (uint256 amount) {
        amount = self.rewardsAccrued;
        self.rewardsAccrued = 0;
    }

    /// @notice Initialise snapshot for a brand-new position key.
    function initSnapshot(State storage self, uint256 rewardsPerLiquidityInsideX128) internal {
        self.rewardsPerLiquidityLastX128 = rewardsPerLiquidityInsideX128;
        self.rewardsAccrued = 0;
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER <-> POSITION INDEX
    //////////////////////////////////////////////////////////////*/

    // Utility helpers to manage (poolId -> owner -> positionKeys[]) mappings that
    // both gauges need. Keeping them here avoids code duplication.

    /// @notice Add a new positionKey to the owner index if it isn’t tracked yet and cache its liquidity.
    function addPosition(
        mapping(PoolId => mapping(address => bytes32[])) storage ownerPositions,
        mapping(bytes32 => uint128) storage liqCache,
        PoolId pid,
        address owner,
        bytes32 posKey,
        uint128 liquidity
    ) internal {
        if (liqCache[posKey] == 0) {
            ownerPositions[pid][owner].push(posKey);
        }
        liqCache[posKey] = liquidity;
    }

    /// @notice Remove a positionKey from owner index and delete its liquidity cache.
    function removePosition(
        mapping(PoolId => mapping(address => bytes32[])) storage ownerPositions,
        mapping(bytes32 => uint128) storage liqCache,
        PoolId pid,
        address owner,
        bytes32 posKey
    ) internal {
        delete liqCache[posKey];
        bytes32[] storage arr = ownerPositions[pid][owner];
        uint256 len = arr.length;
        for (uint256 i; i < len; ++i) {
            if (arr[i] == posKey) {
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
    }
}
