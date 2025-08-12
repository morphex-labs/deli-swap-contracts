// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {RangePool} from "src/libraries/RangePool.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title RangePoolTwoPosInvariant
/// @notice Invariant fuzz suite with two positions straddling tick 0.
///         Ensures reward accounting remains sound when liquidity moves in
///         and out on either side of the active tick.
contract RangePoolTwoPosInvariant is Test {
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;

    /*//////////////////////////////////////////////////////////////
                                  CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int24 internal constant TICK_SPACING = 60;

    int24 internal constant L1 = -1200; // pos1 lower
    int24 internal constant U1 =    0;  // pos1 upper
    int24 internal constant L2 =    0;  // pos2 lower (touches 0)
    int24 internal constant U2 =  1200; // pos2 upper

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    RangePool.State internal pool;

    struct PosState {
        RangePosition.State rp;
        uint128 liquidity;
    }

    PosState internal p1;
    PosState internal p2;

    uint256 internal lastRplX128;
    address internal constant TOK = address(0xBEEF);

    /*//////////////////////////////////////////////////////////////
                                   SET-UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // init tick 0
        pool.initialize(0);

        // seed both positions with 1e18 liquidity
        p1.liquidity = 1e18;
        p2.liquidity = 1e18;

        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: L1,
                tickUpper: U1,
                liquidityDelta: SafeCast.toInt128(uint256(p1.liquidity)),
                tickSpacing: TICK_SPACING
            }),
            toks
        );
        pool.modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: L2,
                tickUpper: U2,
                liquidityDelta: SafeCast.toInt128(uint256(p2.liquidity)),
                tickSpacing: TICK_SPACING
            }),
            toks
        );

        p1.rp.initSnapshot(pool.rangeRplX128(TOK, L1, U1));
        p2.rp.initSnapshot(pool.rangeRplX128(TOK, L2, U2));
        lastRplX128 = pool.cumulativeRplX128(TOK);

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZ ACTION
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(
        uint256 rawStreamRate,
        int24   rawActiveTick,
        int128  rawLiqDelta,
        bool    pickFirst,
        bool    doClaim
    ) external {
        vm.warp(block.timestamp + 1);

        uint256 streamRate = bound(rawStreamRate, 0, 5e23); // <=5e23
        int24 activeTick   = int24(bound(rawActiveTick, -887260, 887260));

        // pick position
        PosState storage ps = pickFirst ? p1 : p2;
        int24 tl = pickFirst ? L1 : L2;
        int24 tu = pickFirst ? U1 : U2;

        int128 liqDelta = rawLiqDelta;
        if (liqDelta < 0 && uint128(uint256(int256(-liqDelta))) > ps.liquidity) {
            liqDelta = -SafeCast.toInt128(uint256(ps.liquidity));
        }

        address[] memory toks2 = new address[](1); toks2[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = streamRate; // dt=1
        pool.sync(toks2, amts, TICK_SPACING, activeTick);

        if (liqDelta != 0) {
            pool.modifyPositionLiquidity(
                RangePool.ModifyLiquidityParams({
                    tickLower: tl,
                    tickUpper: tu,
                    liquidityDelta: liqDelta,
                    tickSpacing: TICK_SPACING
                }),
                toks2
            );
            int256 newLiq = int256(uint256(ps.liquidity)) + int256(liqDelta);
            ps.liquidity = uint128(uint256(newLiq));
        }

        // accrue both positions every step
        p1.rp.accrue(p1.liquidity, pool.rangeRplX128(TOK, L1, U1));
        p2.rp.accrue(p2.liquidity, pool.rangeRplX128(TOK, L2, U2));

        if (doClaim) {
            p1.rp.claim();
            p2.rp.claim();
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_poolMonotonic() public view {
        uint256 curr = pool.cumulativeRplX128(TOK);
        assertGe(curr, lastRplX128, "pool accumulator decreased");
    }

    function invariant_snapshotsNotAhead() public view {
        uint256 poolLeft = pool.rangeRplX128(TOK, L1, U1);
        uint256 poolRight = pool.rangeRplX128(TOK, L2, U2);
        assertLe(p1.rp.rewardsPerLiquidityLastX128, poolLeft);
        assertLe(p2.rp.rewardsPerLiquidityLastX128, poolRight);
    }
} 