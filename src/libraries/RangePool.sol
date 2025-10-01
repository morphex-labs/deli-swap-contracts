// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";

/**
 * @title RangePool
 * @notice Tick–aware accumulator that streams rewards to Uniswap v4 liquidity
 *         positions. The pool tracks global rewards-per-liquidity and per-tick
 *         accumulators, allowing precise in-range reward calculations.
 *         Used internally by both DailyEpochGauge and IncentiveGauge.
 */
library RangePool {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using RangePool for State;

    /*//////////////////////////////////////////////////////////////
                             DATA STRUCTS
    //////////////////////////////////////////////////////////////*/

    // per-tick data
    struct TickInfo {
        uint128 liquidityGross; // total position liquidity referencing this tick
        int128 liquidityNet; // liquidity change when crossing this tick
        mapping(address => uint256) rewardsPerLiquidityOutsideX128; // per-token outside accumulator
    }

    // global pool state tracked by the gauge
    struct State {
        // Per-token cumulative (inside). Name preserved per request.
        mapping(address => uint256) rewardsPerLiquidityCumulativeX128; // token -> cumulative
        uint128 liquidity; // active liquidity (inside current tick)
        int24 tick; // active tick (inclusive)
        uint64 lastUpdated; // timestamp of last accumulator update
        mapping(int24 => TickInfo) ticks; // tick -> info mapping
        mapping(int16 => uint256) tickBitmap; // compressed bitmap of initialized ticks
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cumulative rewards per unit liquidity that accrued **inside** the specified tick span.
    function rangeRplX128(State storage self, address token, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256)
    {
        unchecked {
            if (tickLower >= tickUpper) return 0;

            // Price below the range
            if (self.tick < tickLower) {
                // Inside growth = rewards that accumulated below tickLower only
                // = outsideLower - outsideUpper
                return self.ticks[tickLower].rewardsPerLiquidityOutsideX128[token]
                    - self.ticks[tickUpper].rewardsPerLiquidityOutsideX128[token];
            }

            // Price above the range
            if (self.tick >= tickUpper) {
                // Inside growth = rewards that accumulated above tickUpper only
                // = outsideUpper - outsideLower
                return self.ticks[tickUpper].rewardsPerLiquidityOutsideX128[token]
                    - self.ticks[tickLower].rewardsPerLiquidityOutsideX128[token];
            }

            // Price inside range
            return self.rewardsPerLiquidityCumulativeX128[token]
                - self.ticks[tickUpper].rewardsPerLiquidityOutsideX128[token]
                - self.ticks[tickLower].rewardsPerLiquidityOutsideX128[token];
        }
    }

    function cumulativeRplX128(State storage self, address token) internal view returns (uint256) {
        return self.rewardsPerLiquidityCumulativeX128[token];
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(State storage self, int24 _tick) internal {
        self.tick = _tick;
        self.lastUpdated = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          REWARD STREAM UPDATE
    //////////////////////////////////////////////////////////////*/

    function _accumulateToken(State storage self, address token, uint256 amount) private {
        if (amount == 0) return;
        if (self.liquidity == 0) return;
        unchecked {
            self.rewardsPerLiquidityCumulativeX128[token] += (amount << 128) / self.liquidity;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             LIQUIDITY OPS
    //////////////////////////////////////////////////////////////*/

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        int24 tickSpacing;
    }

    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    /// @notice Add/remove liquidity for a position and update tick bitmaps as needed.
    function modifyPositionLiquidity(State storage self, ModifyLiquidityParams memory params, address[] memory tokens)
        internal
    {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;

        ModifyLiquidityState memory state;

        if (liquidityDelta != 0) {
            (state.flippedLower, state.liquidityGrossAfterLower) = updateTick(self, tickLower, liquidityDelta, false);
            (state.flippedUpper, state.liquidityGrossAfterUpper) = updateTick(self, tickUpper, liquidityDelta, true);

            if (state.flippedLower) {
                self.tickBitmap.flipTick(tickLower, params.tickSpacing);
                if (liquidityDelta > 0) {
                    _initTickOutsideForTokens(self, tickLower, tokens);
                }
            }
            if (state.flippedUpper) {
                self.tickBitmap.flipTick(tickUpper, params.tickSpacing);
                if (liquidityDelta > 0) {
                    _initTickOutsideForTokens(self, tickUpper, tokens);
                }
            }
        }

        if (liquidityDelta < 0) {
            if (state.flippedLower) clearTick(self, tickLower);
            if (state.flippedUpper) clearTick(self, tickUpper);
        }

        if (params.tickLower <= self.tick && self.tick < params.tickUpper) {
            self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         PRICE MOVEMENT HANDLER
    //////////////////////////////////////////////////////////////*/

    /// @notice Move the pool’s notion of the active tick and update liquidity accordingly.
    function adjustToTick(State storage self, int24 tickSpacing, int24 tick, address[] memory tokens) internal {
        int24 currentTick = self.tick;
        int128 liquidityChange = 0;
        bool lte = tick <= currentTick;

        if (lte) {
            while (tick < currentTick) {
                (int24 nextTick, bool initialized) =
                    self.tickBitmap.nextInitializedTickWithinOneWord(currentTick, tickSpacing, true);

                if (nextTick <= tick) {
                    break;
                }

                if (initialized) {
                    int128 liquidityNet = _flipOutsideForTokens(self, nextTick, tokens);
                    liquidityChange -= liquidityNet;
                }
                currentTick = nextTick - 1;
            }
        } else {
            // going right
            while (currentTick < tick) {
                (int24 nextTick, bool initialized) =
                    self.tickBitmap.nextInitializedTickWithinOneWord(currentTick, tickSpacing, false);

                if (nextTick > tick) {
                    break;
                }

                if (initialized) {
                    int128 liquidityNet = _flipOutsideForTokens(self, nextTick, tokens);
                    liquidityChange += liquidityNet;
                }
                currentTick = nextTick;
            }
        }

        self.tick = tick;
        self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityChange);
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL TICK OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function updateTick(State storage self, int24 tick, int128 liquidityDelta, bool upper)
        internal
        returns (bool flipped, uint128 liquidityGrossAfter)
    {
        TickInfo storage info = self.ticks[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;
        assembly ("memory-safe") {
            sstore(info.slot, or(and(liquidityGrossAfter, 0xffffffffffffffffffffffffffffffff), shl(128, liquidityNet)))
        }
    }

    function clearTick(State storage self, int24 tick) internal {
        delete self.ticks[tick];
    }

    function _flipOutsideForTokens(State storage self, int24 tick, address[] memory tokens)
        internal
        returns (int128 liquidityNet)
    {
        unchecked {
            TickInfo storage info = self.ticks[tick];
            if (info.liquidityGross == 0) {
                return 0;
            }
            for (uint256 i; i < tokens.length; ++i) {
                address tok = tokens[i];
                uint256 outside = info.rewardsPerLiquidityOutsideX128[tok];
                info.rewardsPerLiquidityOutsideX128[tok] = self.rewardsPerLiquidityCumulativeX128[tok] - outside;
            }
            liquidityNet = info.liquidityNet;
        }
    }

    function _initTickOutsideForTokens(State storage self, int24 tick, address[] memory tokens) internal {
        if (tick <= self.tick) {
            TickInfo storage info = self.ticks[tick];
            for (uint256 i; i < tokens.length; ++i) {
                address tok = tokens[i];
                info.rewardsPerLiquidityOutsideX128[tok] = self.rewardsPerLiquidityCumulativeX128[tok];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             UTILITY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice High-level helper used by gauges: initialise (if needed), accumulate rewards and adjust to new tick.
    /// @param self        Pool state storage pointer.
    /// @param perTokenAmounts  Token amounts accrued over the window since last update (0 allowed).
    /// @param tickSpacing Pool tick spacing (passed to adjustToTick).
    /// @param activeTick  Current active tick from PoolManager.slot0.
    function sync(
        State storage self,
        address[] memory tokens,
        uint256[] memory perTokenAmounts,
        int24 tickSpacing,
        int24 activeTick
    ) internal {
        // Bootstrap state on first touch so accumulate sees dt = 0
        if (self.lastUpdated == 0) {
            self.initialize(activeTick);
            // no need to accumulate or adjust because lastUpdated = now and tick == activeTick
            return;
        }
        // If no active liquidity, do not advance lastUpdated or consume amounts.
        // Preserve the time window so amounts are processed later when liquidity exists.
        if (self.liquidity == 0) {
            // Adjust price movement if needed, but keep lastUpdated unchanged.
            if (activeTick != self.tick) {
                self.adjustToTick(tickSpacing, activeTick, tokens);
            }
            return;
        }

        // 1. Update lastUpdated and credit per-token amounts
        self.lastUpdated = uint64(block.timestamp);

        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            _accumulateToken(self, tokens[i], perTokenAmounts[i]);

            unchecked {
                ++i;
            }
        }
        // 2. If price moved out of current range adjust liquidity & tick, flipping per-token outside
        if (activeTick != self.tick) {
            self.adjustToTick(tickSpacing, activeTick, tokens);
        }
    }
}
