// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/IncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {RangePool} from "src/libraries/RangePool.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Mocks
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n) ERC20(n, n) {
        _mint(msg.sender, 1e24);
    }
}

contract GaugeHarnessClamp is IncentiveGauge {
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;
    using SafeERC20 for IERC20;

    constructor(address pm, address posMgr, address hook)
        IncentiveGauge(IPoolManager(pm), IPositionManagerAdapter(posMgr), hook)
    {}

    function setTickRange(bytes32 key, int24 lower, int24 upper) external {
        positionTicks[key] = TickRange({lower: lower, upper: upper});
    }

    function setPositionState(bytes32 k, IERC20 tok, uint256 paid, uint256 acc, uint128 liq) external {
        RangePosition.State storage ps = positionRewards[k][tok];
        ps.rewardsPerLiquidityLastX128 = paid;
        ps.rewardsAccrued = acc;
        positionLiquidity[k] = liq;
    }

    function setPoolLiquidity(PoolId pid, uint128 liq) external {
        poolRewards[pid].liquidity = liq;
    }

    function initIfNeeded(PoolKey memory key, int24 tick) external {
        if (poolRewards[key.toId()].lastUpdated == 0) {
            poolRewards[key.toId()].initialize(tick);
        }
    }

    function pendingFor(bytes32 posKey, IERC20 token, uint128 currentLiquidity, PoolId pid)
        external
        view
        returns (uint256 amount)
    {
        TickRange storage tr = positionTicks[posKey];
        RangePosition.State storage ps = positionRewards[posKey][token];
        uint256 rangeRpl = poolRewards[pid].rangeRplX128(address(token), tr.lower, tr.upper);
        uint256 delta = rangeRpl - ps.rewardsPerLiquidityLastX128;
        amount = ps.rewardsAccrued + (delta * currentLiquidity) / FixedPoint128.Q128;
    }
}

contract IncentiveGauge_AccrualClampTest is Test {
    GaugeHarnessClamp gauge;
    MockPoolManager pm;
    address hook = address(0xBEEF);

    MockERC20 tokenA;
    PoolKey key;
    PoolId pid;

    function setUp() public {
        pm = new MockPoolManager();
        tokenA = new MockERC20("TKA");

        gauge = new GaugeHarnessClamp(address(pm), address(0x1), hook);
        gauge.setWhitelist(tokenA, true);

        key = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(0xBBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();

        // init pool at tick 0
        pm.setSlot0(PoolId.unwrap(pid), TickMath.getSqrtPriceAtTick(0), 0, 0, 0);
        gauge.initIfNeeded(key, 0);
    }

    function testZeroLiquidityFunding_ThenLiquidity_AccruesFromTokenStart() public {
        // zero gauge-side liquidity
        gauge.setPoolLiquidity(pid, 0);

        // create incentive at t0
        uint256 amt = 7000 ether;
        tokenA.approve(address(gauge), amt);
        gauge.createIncentive(key, tokenA, amt);

        // advance 1 day with zero liquidity
        vm.warp(block.timestamp + 1 days);

        // add a single position equal to entire pool liquidity
        uint128 L = 1_000_000;
        bytes32 posKey = keccak256("pos");
        gauge.setPositionState(posKey, tokenA, 0, 0, L);
        gauge.setTickRange(posKey, -60, 60);
        gauge.setPoolLiquidity(pid, L);

        // poke (liquidity now > 0): expect accrual from token.lastUpdate only
        vm.prank(hook);
        gauge.pokePool(key);

        // expected streamed = rate * 1 day
        (uint256 rate,,) = gauge.incentiveData(pid, tokenA);
        uint256 expected = rate * 1 days;
        uint256 pending = gauge.pendingFor(posKey, tokenA, L, pid);
        assertApproxEqAbs(pending, expected, 3); // allow minimal rounding tolerance
    }

    function testTopUpDuringZeroLiquidity_NoOverCreditOnFirstLiquidity() public {
        gauge.setPoolLiquidity(pid, 0);

        uint256 first = 700 ether;
        tokenA.approve(address(gauge), first);
        gauge.createIncentive(key, tokenA, first);

        // Wait 12 hours with zero-liquidity, then top-up
        vm.warp(block.timestamp + 12 hours);
        uint256 second = 1400 ether;
        tokenA.approve(address(gauge), second);
        gauge.createIncentive(key, tokenA, second);

        // Now add all liquidity and poke
        uint128 L = 1_000_000;
        bytes32 posKey = keccak256("pos2");
        gauge.setPositionState(posKey, tokenA, 0, 0, L);
        gauge.setTickRange(posKey, -60, 60);
        gauge.setPoolLiquidity(pid, L);
        vm.prank(hook);
        gauge.pokePool(key);

        // Since lastUpdate was reset at top-up, first minted window is tiny (~0) before poke
        // So pending should be near zero just after first poke
        uint256 pending = gauge.pendingFor(posKey, tokenA, L, pid);
        assertLe(pending, (second / 7 days) * 5 minutes + 1e9); // very small bound
    }
}
