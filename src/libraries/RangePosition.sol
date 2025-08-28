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
    ///         Uses stored owner and index (idx+1; 0 means absent) for O(1) removals.
    function addPosition(
        mapping(PoolId => mapping(address => bytes32[])) storage ownerPositions,
        mapping(bytes32 => uint128) storage liqCache,
        mapping(bytes32 => address) storage positionOwner,
        mapping(bytes32 => uint256) storage positionIndex,
        PoolId pid,
        address owner,
        bytes32 posKey,
        uint128 liquidity
    ) internal {
        if (liqCache[posKey] == 0) {
            bytes32[] storage arr = ownerPositions[pid][owner];
            arr.push(posKey);
            positionOwner[posKey] = owner;
            positionIndex[posKey] = arr.length; // store idx+1
        }
        liqCache[posKey] = liquidity;
    }

    /// @notice Remove a positionKey from owner index and delete its liquidity cache.
    ///         O(1) swap-pop removal using stored owner and index; requires presence.
    function removePosition(
        mapping(PoolId => mapping(address => bytes32[])) storage ownerPositions,
        mapping(bytes32 => uint128) storage liqCache,
        mapping(bytes32 => address) storage positionOwner,
        mapping(bytes32 => uint256) storage positionIndex,
        PoolId pid,
        bytes32 posKey
    ) internal {
        delete liqCache[posKey];
        address storedOwner = positionOwner[posKey];
        bytes32[] storage arr = ownerPositions[pid][storedOwner];
        uint256 idx = positionIndex[posKey] - 1;
        uint256 lastIndex = arr.length - 1;

        if (idx != lastIndex) {
            bytes32 lastKey = arr[lastIndex];
            arr[idx] = lastKey;
            positionIndex[lastKey] = idx + 1;
        }
        arr.pop();
        delete positionIndex[posKey];
        delete positionOwner[posKey];
    }
}
