// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/libraries/RangePool.sol";
import "src/libraries/RangePosition.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

/// @title RangePositionLibraryTest
/// @notice Unit tests for RangePosition State accrue & claim against RangePool accumulator.
contract RangePositionLibraryTest is Test {
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;

    RangePool.State internal pool;
    RangePosition.State internal pos;

    uint128 internal constant LIQ = 500_000 ether;
    int24 internal constant TICK_SPACING = 60;
    address internal constant TOK = address(0xBEEF);

    function setUp() public {
        vm.warp(1_700_000_000);
        pool.initialize(0);
        // Add liquidity so pool has base to distribute rewards
        RangePool.ModifyLiquidityParams memory p = RangePool.ModifyLiquidityParams({
            tickLower: -TICK_SPACING,
            tickUpper: TICK_SPACING,
            liquidityDelta: int128(int256(uint256(LIQ))),
            tickSpacing: TICK_SPACING
        });
        address[] memory toks = new address[](1); toks[0] = TOK;
        pool.modifyPositionLiquidity(p, toks);
    }

    function _advance(uint256 secondsForward, uint256 streamRate) internal {
        vm.warp(block.timestamp + secondsForward);
        address[] memory toks = new address[](1); toks[0] = TOK;
        uint256[] memory rates = new uint256[](1); rates[0] = streamRate;
        pool.sync(toks, rates, TICK_SPACING, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccrueAndClaim() public {
        uint256 streamRate = 2e18; // 2 tokens/sec
        _advance(50, streamRate); // accrue some rewards first

        // Accrue pending rewards for position
        uint256 beforeCum = pool.cumulativeRplX128(TOK);
        pos.accrue(LIQ, beforeCum);

        // expected rewards: streamRate * dt = 100 tokens ; proportion = LIQ/LIQ so same
        uint256 expected = streamRate * 50;
        uint256 tolerance = 2; // wei tolerance
        uint256 accrued = pos.rewardsAccrued;
        assertLe(expected - accrued, tolerance);

        // Claim resets counter
        uint256 claimed = pos.claim();
        assertEq(pos.rewardsAccrued, 0);
        assertEq(claimed, accrued);
    }

    function testAccrueZeroLiquidityOnlySnapshots() public {
        _advance(10, 1e18);
        uint256 before = pos.rewardsAccrued;
        pos.accrue(0, pool.cumulativeRplX128(TOK));
        assertEq(pos.rewardsAccrued, before);
        // snapshot updated – accrue after more time with liquidity
        uint256 snap = pool.cumulativeRplX128(TOK);
        _advance(5, 1e18);
        pos.accrue(LIQ, pool.cumulativeRplX128(TOK));
        uint256 expected = (pool.cumulativeRplX128(TOK) - snap) * LIQ / FixedPoint128.Q128;
        assertEq(pos.rewardsAccrued, expected + before);
    }

    function testAccrueNoDelta() public {
        _advance(20, 1e18);
        pos.accrue(LIQ, pool.cumulativeRplX128(TOK));
        uint256 first = pos.rewardsAccrued;
        // call again without time progression
        pos.accrue(LIQ, pool.cumulativeRplX128(TOK));
        assertEq(pos.rewardsAccrued, first);
    }

    // double initSnapshot idempotency
    function testDoubleInitSnapshot() public {
        uint256 snap = 10 * FixedPoint128.Q128;
        pos.initSnapshot(snap);
        pos.initSnapshot(snap); // second call should not alter state improperly
        assertEq(pos.rewardsPerLiquidityLastX128, snap);
        assertEq(pos.rewardsAccrued, 0);
    }

    // accrue, claim partial, accrue again pro-rata
    function testAccrueClaimAccrue() public {
        uint256 streamRate = 1e18;
        _advance(60, streamRate); // 1 min accrual
        pos.accrue(LIQ, pool.cumulativeRplX128(TOK));
        uint256 firstAcc = pos.rewardsAccrued;
        uint256 half = firstAcc / 2;
        // manually reduce accrued to simulate partial payout
        pos.rewardsAccrued = half;
        // claim should transfer half and zero counter
        uint256 claimed = pos.claim();
        assertEq(claimed, half);
        assertEq(pos.rewardsAccrued, 0);
        // advance more time and accrue again – should add on top
        _advance(30, streamRate);
        pos.accrue(LIQ, pool.cumulativeRplX128(TOK));
        assertGt(pos.rewardsAccrued, 0);
    }

    // fuzz: claim resets counter exactly
    function testFuzz_ClaimResets(uint256 accrued) public {
        accrued = accrued % 1e30; // bound
        pos.rewardsAccrued = accrued;
        uint256 claimed = pos.claim();
        assertEq(claimed, accrued);
        assertEq(pos.rewardsAccrued, 0);
    }
} 