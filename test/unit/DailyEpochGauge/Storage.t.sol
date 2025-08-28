// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/DailyEpochGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";

// minimal token
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken2 is ERC20 {
    constructor() ERC20("BMX", "BMX") { _mint(msg.sender, 1e24); }
}

/// @dev Harness exposing internal storage setters
contract GaugeHarness is DailyEpochGauge {
    using RangePool for RangePool.State;
    
    constructor(address _fp, address _pm, address _posMgr, address _hook, IERC20 _bmx)
        DailyEpochGauge(_fp, IPoolManager(_pm), IPositionManagerAdapter(_posMgr), _hook, _bmx, address(0)) {}

    // direct mutate helpers --------------------------------------------------
    function setPoolRpl(PoolId pid, uint256 rpl) external {
        poolRewards[pid].rewardsPerLiquidityCumulativeX128[address(BMX)] = rpl;
    }

    function setPositionState(bytes32 key, uint256 paidRpl, uint256 accrued, uint128 liq) external {
        RangePosition.State storage ps = positionRewards[key];
        ps.rewardsPerLiquidityLastX128 = paidRpl;
        ps.rewardsAccrued = accrued;
        positionLiquidity[key] = liq;
    }

    function pushOwnerPos(PoolId pid, address owner, bytes32 key) external {
        ownerPositions[pid][owner].push(key);
    }

    // new helper to set tick range for a position key so that pending helpers behave correctly
    function setTickRange(bytes32 key, int24 lower, int24 upper) external {
        positionTicks[key] = TickRange({lower: lower, upper: upper});
    }
    
    // Test helper for unit tests using synthetic position keys
    function pendingRewards(bytes32 posKey, uint128 liquidity, PoolId pid) external view returns (uint256) {
        RangePool.State storage pool = poolRewards[pid];
        TickRange storage tr = positionTicks[posKey];
        RangePosition.State storage ps = positionRewards[posKey];
        uint256 rangeRpl = pool.rangeRplX128(address(BMX), tr.lower, tr.upper);
        uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
        return ps.rewardsAccrued + (delta * liquidity) / FixedPoint128.Q128;
    }
    
    // Test helper for claiming with synthetic position keys
    function claim(address recipient, bytes32 posKey) external returns (uint256) {
        return _claimRewards(posKey, recipient);
    }
}

contract DailyEpochGauge_StorageTest is Test {
    GaugeHarness gauge;
    PoolId internal constant PID = PoolId.wrap(bytes25(uint200(2)));

    address constant OWNER = address(0xBEEF);
    bytes32 posKey;

    function setUp() public {
        MockToken2 bmx = new MockToken2();
        gauge = new GaugeHarness(address(0xFEE), address(0x1), address(0x2), address(0x3), bmx);

        posKey = keccak256("dummy-position");
    }

    /*//////////////////////////////////////////////////////////////
                       pendingRewards for single position
    //////////////////////////////////////////////////////////////*/

    function testPendingRewards_Position() public {
        // pool global accumulator
        uint256 poolRpl = 10 * FixedPoint128.Q128; // 10 tokens per unit liq
        gauge.setPoolRpl(PID, poolRpl);

        // set tick range for position (arbitrary valid span)
        gauge.setTickRange(posKey, -60, 60);

        // position snapshot lower (earned 3 tokens already, paid at 7)
        uint256 paidRpl = 7 * FixedPoint128.Q128;
        uint128 liq = 1e6;
        uint256 accrued = 3e18;
        gauge.setPositionState(posKey, paidRpl, accrued, liq);

        uint256 expectedDelta = (poolRpl - paidRpl) * liq / FixedPoint128.Q128; // 3 tokens
        uint256 expected = accrued + expectedDelta;

        uint256 pending = gauge.pendingRewards(posKey, liq, PID);
        assertEq(pending, expected);
    }

    /*//////////////////////////////////////////////////////////////
                       pendingRewardsOwner aggregate
    //////////////////////////////////////////////////////////////*/

    function testPendingRewardsOwner() public {
        // two positions, same owner
        bytes32 pos1 = posKey;
        bytes32 pos2 = keccak256("pos2");
        uint128 liq1 = 1e6;
        uint128 liq2 = 2e6;

        // tick ranges for both positions
        gauge.setTickRange(pos1, -60, 60);
        gauge.setTickRange(pos2, -120, 120);

        // set global RPL
        uint256 poolRpl = 5 * FixedPoint128.Q128;
        gauge.setPoolRpl(PID, poolRpl);

        // position1: paid 2, accrued 1
        gauge.setPositionState(pos1, 2 * FixedPoint128.Q128, 1e18, liq1);
        // position2: paid 3, accrued 0.5
        gauge.setPositionState(pos2, 3 * FixedPoint128.Q128, 5e17, liq2);

        // index positions for owner
        gauge.pushOwnerPos(PID, OWNER, pos1);
        gauge.pushOwnerPos(PID, OWNER, pos2);

        uint256 expected =
            1e18 + ((5-2)*liq1)/FixedPoint128.Q128 + 5e17 + ((5-3)*liq2)/FixedPoint128.Q128;
        uint256 pending = gauge.pendingRewardsOwner(PID, OWNER);
        assertApproxEqAbs(pending, expected, 1e13); // allow tiny rounding error
    }

    /*//////////////////////////////////////////////////////////////
                                claim
    //////////////////////////////////////////////////////////////*/

    function testClaim() public {
        // initialise simple state
        gauge.setPoolRpl(PID, 0);
        gauge.setPositionState(posKey, 0, 4e18, 1e6);

        // send BMX to gauge so it can transfer
        MockToken2(address(gauge.BMX())).transfer(address(gauge), 4e18);

        vm.prank(address(OWNER));
        uint256 claimed = gauge.claim(OWNER, posKey);
        assertEq(claimed, 4e18);
        assertEq(gauge.BMX().balanceOf(OWNER), 4e18);
    }
} 