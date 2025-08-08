// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {RangePool} from "src/libraries/RangePool.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title RewardAccountingInvariant
/// @notice Fuzz + invariant test that exercises the RangePool + RangePosition
///         reward-stream accounting.  We continuously:
///           1. Fuzz `streamRate`, `activeTick`, and a liquidity delta
///           2. Call `sync` and optionally modify liquidity/claim
///           3. Check invariants:
///                – `rewardsPerLiquidityCumulativeX128` is non-decreasing
///                – Position snapshot never exceeds pool accumulator
contract RewardAccountingInvariant is Test {
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    RangePool.State internal pool;
    RangePosition.State internal pos;

    // Simple single-position parameters (±600 tick range)
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER =  600;

    uint128 internal liquidity;      // current position liquidity
    uint256 internal lastRplX128;    // previous cumulative value for monotonic check
    address internal constant TOK = address(0xBEEF);

    /*//////////////////////////////////////////////////////////////
                                   SET-UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Initialise pool at tick 0 so lastUpdated = block.timestamp
        pool.initialize(0);

        // Seed with 1e18 liquidity inside the target range
        liquidity = 1e18;
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: SafeCast.toInt128(uint256(liquidity)),
                tickSpacing: TICK_SPACING
            }),
            toks
        );

        // Set initial snapshot for our single position
        pos.initSnapshot(pool.rangeRplX128(TOK, TICK_LOWER, TICK_UPPER));
        lastRplX128 = pool.cumulativeRplX128(TOK);

        // Make every public/external function in this contract eligible for fuzzing
        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ ENTRYPOINT (to be fuzzed by Foundry)
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzzed entry.  Foundry will call this with random inputs and
    ///         interleave with invariant checks.
    function fuzz_step(
        uint256 rawStreamRate,
        int24   rawActiveTick,
        int128  rawLiquidityDelta,
        bool    doClaim
    ) external {
        // 1. Advance time by at least 1 second so `accumulate` observes dt>0
        vm.warp(block.timestamp + 1);

        // 2. Sanitize & bound inputs
        uint256 streamRate = bound(rawStreamRate, 0, 1e24);               // <= 1M tokens/s
        int24 activeTick   = int24(bound(rawActiveTick, -887260, 887260));

        // Prevent liquidity underflow – cap negative delta at `liquidity`
        int128 liqDelta = rawLiquidityDelta;
        if (liqDelta < 0 && uint128(uint256(int256(-liqDelta))) > liquidity) {
            liqDelta = -SafeCast.toInt128(uint256(liquidity));
        }

        // 3. Apply pool sync (accumulate + maybe move price)
        address[] memory toks2 = new address[](1); toks2[0] = TOK;
        uint256[] memory rates = new uint256[](1); rates[0] = streamRate;
        pool.sync(toks2, rates, TICK_SPACING, activeTick);

        // 4. Optionally modify liquidity
        if (liqDelta != 0) {
            pool.modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: liqDelta,
                    tickSpacing: TICK_SPACING
                }),
                toks2
            );
            // safe cast: result is guaranteed >= 0 after earlier bound
            int256 newLiq = int256(uint256(liquidity)) + int256(liqDelta);
            liquidity = uint128(uint256(newLiq));
        }

        // 5. Accrue rewards for our position based on current pool state
        pos.accrue(liquidity, pool.rangeRplX128(TOK, TICK_LOWER, TICK_UPPER));

        // 6. Optionally claim (resets rewardsAccrued to 0)
        if (doClaim) {
            pos.claim();
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Global accumulator should never decrease across any sequence
    ///         of operations.
    function invariant_poolAccumulatorMonotonic() public view {
        uint256 curr = pool.cumulativeRplX128(TOK);
        assertGe(curr, lastRplX128, "rewardsPerLiquidityCumulativeX128 decreased");
    }

    /// @notice Position snapshot value should never exceed pool’s in-range
    ///         cumulative rewards (cannot predict the future).
    function invariant_positionSnapshotNotAhead() public view {
        uint256 poolRpl = pool.rangeRplX128(TOK, TICK_LOWER, TICK_UPPER);
        assertLe(pos.rewardsPerLiquidityLastX128, poolRpl);
    }
} 