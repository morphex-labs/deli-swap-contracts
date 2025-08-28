// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/libraries/RangePool.sol";

/// @title RangePoolLibraryTest
/// @notice Unit tests for RangePool.State accumulate & liquidity accounting.
contract RangePoolLibraryTest is Test {
    using RangePool for RangePool.State;

    RangePool.State internal pool;
    address internal constant TOK = address(0xBEEF);

    uint128 internal constant LIQ = 1_000_000 ether;
    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        // deterministic timestamp
        vm.warp(1_700_000_000);
        // initialize pool with active tick = 0
        pool.initialize(0);
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    function testModifyLiquidity_Add() public {
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
        assertEq(pool.liquidity, LIQ);
        assertEq(pool.tick, 0);
    }

    function testAccumulate_Basic() public {
        // add liquidity first so accumulate can distribute rewards
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);

        // warp forward 100 seconds
        vm.warp(block.timestamp + 100);
        uint256 streamRate = 1e18; // 1 token / sec (18 decimals)

        // call sync to apply accumulation (activeTick unchanged)
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = streamRate * 100; // pre-integrated amount
        pool.sync(stoks, amts, TICK_SPACING, 0);

        uint256 expectedRewards = streamRate * 100;
        uint256 expectedRpl = (expectedRewards << 128) / LIQ;
        assertEq(pool.rewardsPerLiquidityCumulativeX128[TOK], expectedRpl);
    }

    function testRemoveLiquidityClearsActive() public {
        // add liq
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
        assertEq(pool.liquidity, LIQ);
        // remove same amount
        p.liquidityDelta = -int128(int256(uint256(LIQ)));
        pool.modifyPositionLiquidity(p, new address[](0));
        assertEq(pool.liquidity, 0);
        // accumulate with zero liquidity – should not change RPL
        vm.warp(block.timestamp + 50);
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = 1e18 * 50; // dt=50
        pool.sync(stoks, amts, TICK_SPACING, 0);
        assertEq(pool.rewardsPerLiquidityCumulativeX128[TOK], 0);
    }

    function testAccumulateGuardRails() public {
        vm.warp(block.timestamp + 30);
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = 0; // zero amount
        pool.sync(stoks, amts, TICK_SPACING, 0);
        assertEq(pool.rewardsPerLiquidityCumulativeX128[TOK], 0);
        vm.warp(block.timestamp + 40);
        amts[0] = 1e18 * 40; // dt=40
        pool.sync(stoks, amts, TICK_SPACING, 0); // liq still 0
        assertEq(pool.rewardsPerLiquidityCumulativeX128[TOK], 0);
    }

    function testAdjustToTickOnPriceMove() public {
        // add liquidity first
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
        // move tick inside range
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = 0;
        pool.sync(stoks, amts, TICK_SPACING, 90);
        assertEq(pool.tick, 90);
        // move outside upper range – liquidity should drop to zero
        pool.sync(stoks, amts, TICK_SPACING, 120);
        assertEq(pool.tick, 120);
        assertEq(pool.liquidity, 0);
    }

    // skip un-initialised tick – move 0 -> 120 where 60 is not initialised
    function testSkipUninitialisedTickLiquidityConstant() public {
        // add liquidity between -60 and +180 so tick 60 remains uninitialised
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING*3, // 180
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
        assertEq(pool.liquidity, LIQ);

        // advance price to tick 120 (inside position but across 60)
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = 0;
        pool.sync(stoks, amts, TICK_SPACING, 120);
        assertEq(pool.tick, 120);
        // liquidity should stay unchanged because tick 60 uninitialised
        assertEq(pool.liquidity, LIQ);
    }

    // round-trip crossing restores liquidity
    function testRoundTripCrossingRestoresLiquidity() public {
        // add liquidity narrow -60 to 60
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
        assertEq(pool.liquidity, LIQ);

        // move price to 120 (outside) liquidity becomes 0
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = 0;
        pool.sync(stoks, amts, TICK_SPACING, 120);
        assertEq(pool.liquidity, 0, "liquidity not dropped");

        // move back to -30 (inside range) – should restore
        pool.sync(stoks, amts, TICK_SPACING, -30);
        assertEq(pool.liquidity, LIQ, "liquidity not restored");
    }

    // accumulate with zero liquidity and huge streamRate does not overflow or change rpl
    function testAccumulateHugeRateZeroLiquidity() public {
        uint256 bigAmount = type(uint256).max / 10; // very large but within uint256
        vm.warp(block.timestamp + 100);
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = bigAmount; // pass large amount directly
        pool.sync(stoks, amts, TICK_SPACING, 0);
        assertEq(pool.rewardsPerLiquidityCumulativeX128[TOK], 0);
    }

    // fuzz: RPL monotonically increasing
    function testFuzz_RplMonotonic(uint64 dt1, uint64 dt2, uint128 rate1, uint128 rate2) public {
        vm.assume(rate1 > 0 && rate2 > 0);
        vm.assume(dt1 > 0 && dt2 > 0);
        // add liquidity once
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);

        uint256 start = block.timestamp;
        vm.warp(start + dt1);
        address[] memory stoks = new address[](1); stoks[0] = TOK;
        uint256[] memory amts = new uint256[](1); amts[0] = uint256(rate1) * dt1;
        pool.sync(stoks, amts, TICK_SPACING, 0);
        uint256 first = pool.cumulativeRplX128(TOK);
        vm.warp(start + dt1 + dt2);
        amts[0] = uint256(rate2) * dt2;
        pool.sync(stoks, amts, TICK_SPACING, 0);
        uint256 second = pool.cumulativeRplX128(TOK);
        assertGe(second, first);
    }

    function testInitOutsideOnlyOnAdd() public {
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
        // remove (no tokens array) should not write per-token outsides; just clear tick
        p.liquidityDelta = -int128(int256(uint256(LIQ)));
        pool.modifyPositionLiquidity(p, new address[](0));
        assertEq(pool.liquidity, 0);
    }
} 