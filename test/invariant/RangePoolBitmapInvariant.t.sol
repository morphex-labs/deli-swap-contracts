// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {RangePool} from "src/libraries/RangePool.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

contract RangePoolBitmapInvariant is Test {
    using RangePool for RangePool.State;

    int24 internal constant SPACING = 60;
    address internal constant TOK = address(0xBEEF);

    RangePool.State internal pool;

    int24[] internal tracked; // list of ticks we interacted with
    mapping(int24 => bool) internal already; // helper to avoid duplicates

    uint256 internal lastCumulative;

    function setUp() public {
        pool.initialize(0);
        lastCumulative = pool.cumulativeRplX128(TOK);
        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZ ACTION
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(
        int24 rawTickLower,
        int24 rawTickUpper,
        uint128 amount,
        uint256 streamRate
    ) external {
        // 1. normalise ticks to spacing and bounds
        int24 tl = int24(bound(rawTickLower, -4800, 4740));
        tl = (tl / SPACING) * SPACING; // snap to grid
        int24 tuMin = tl + SPACING;
        int24 tu = int24(bound(rawTickUpper, tuMin, 4800));
        tu = (tu / SPACING) * SPACING;

        // 2. add liquidity (always positive to avoid underflow complexity)
        int128 liqDelta = SafeCast.toInt128(uint256(amount % 1e20 + 1));

        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(
            RangePool.ModifyLiquidityParams({
                tickLower: tl,
                tickUpper: tu,
                liquidityDelta: liqDelta,
                tickSpacing: SPACING
            }),
            toks
        );

        // track ticks
        if (!already[tl]) { already[tl] = true; tracked.push(tl);} 
        if (!already[tu]) { already[tu] = true; tracked.push(tu);} 

        // 3. advance time by 1 and sync with given streamRate
        vm.warp(block.timestamp + 1);
        address[] memory toks2 = new address[](1); toks2[0] = TOK;
        uint256[] memory rates = new uint256[](1); rates[0] = streamRate % 1e23;
        pool.sync(toks2, rates, SPACING, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_poolMonotonic() public view {
        uint256 curr = pool.cumulativeRplX128(TOK);
        assertGe(curr, lastCumulative, "cumulative decreased");
    }

    function invariant_bitmapMatchesLiquidity() public view {
        uint256 len = tracked.length;
        for (uint256 i; i < len; ++i) {
            int24 tick = tracked[i];
            RangePool.TickInfo storage info = pool.ticks[tick];

            // compute word/bit
            int24 compressed = tick / SPACING;
            int16 wordPos = int16(compressed >> 8);
            uint8 bitPos = uint8(uint24(uint24(compressed) & 0xFF));
            bool bitSet = (pool.tickBitmap[wordPos] >> uint256(bitPos)) & 1 == 1;

            bool hasGross = info.liquidityGross != 0;
            assertEq(bitSet, hasGross, "bitmap mismatch");
        }
    }
} 