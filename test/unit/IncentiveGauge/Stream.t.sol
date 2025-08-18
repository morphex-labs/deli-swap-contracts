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
import {MockPoolKeysProvider} from "test/mocks/MockPoolKeysProvider.sol";
import {MockAdapterForKeys} from "test/mocks/MockAdapterForKeys.sol";

// Mocks
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

// Simple ERC20 mock
contract MockERC20 is ERC20 {
    constructor(string memory n) ERC20(n,n) { _mint(msg.sender, 1e24); }
}

// Harness exposing internal helpers
contract GaugeHarness is IncentiveGauge {
    using RangePool for RangePool.State;
    using RangePosition for RangePosition.State;
    using SafeERC20 for IERC20;
    
    constructor(address pm, address posMgr, address hook)
        IncentiveGauge(IPoolManager(pm), IPositionManagerAdapter(posMgr), hook) {}

    function setTickRange(bytes32 key, int24 lower, int24 upper) external {
        positionTicks[key] = TickRange({lower: lower, upper: upper});
    }

    function setPoolRpl(PoolId pid, IERC20 tok, uint256 rpl) external {
        poolRewards[pid].rewardsPerLiquidityCumulativeX128[address(tok)] = rpl;
    }

    function setPositionState(bytes32 k, IERC20 tok, uint256 paid, uint256 acc, uint128 liq) external {
        RangePosition.State storage ps = positionRewards[k][tok];
        ps.rewardsPerLiquidityLastX128 = paid;
        ps.rewardsAccrued = acc;
        positionLiquidity[k] = liq;
    }

    function setPoolLiquidity(PoolId pid, IERC20 /*tok*/, uint128 liq) external {
        poolRewards[pid].liquidity = liq;
    }

    function pushOwnerPos(PoolId pid, address owner, bytes32 k) external {
        ownerPositions[pid][owner].push(k);
    }
    
    function initializePool(PoolId pid, IERC20 /*tok*/, int24 tick) external {
        if (poolRewards[pid].lastUpdated == 0) {
            poolRewards[pid].initialize(tick);
        }
    }
    


    // Helper for tests that use the old pendingRewards interface
    function pendingRewards(bytes32 posKey, IERC20 token, uint128 currentLiquidity, PoolId pid)
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


contract IncentiveGauge_StreamTest is Test {
    GaugeHarness gauge;
    MockPoolManager pm;
    address hook = address(0xBEEF);

    MockERC20 tokenA;
    PoolKey key;
    PoolId pid;

    function setUp() public {
        pm = new MockPoolManager();
        tokenA = new MockERC20("TKA");

        gauge = new GaugeHarness(address(pm), address(0x1), hook);
        gauge.setWhitelist(tokenA, true);

        key = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(0xBBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();

        // initialise some liquidity
        pm.setLiquidity(PoolId.unwrap(pid), 1_000_000);
        // Set slot0 with a valid sqrtPriceX96 at tick 0
        pm.setSlot0(PoolId.unwrap(pid), TickMath.getSqrtPriceAtTick(0), 0, 0, 0);
        // Wire adapter for tickSpacing and init via hook
        MockPoolKeysProvider pk = new MockPoolKeysProvider();
        MockAdapterForKeys ad = new MockAdapterForKeys(address(pk));
        gauge.setPositionManagerAdapter(address(ad));
        vm.prank(hook);
        gauge.initPool(key, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           createIncentive
    //////////////////////////////////////////////////////////////*/

    function testCreateIncentiveFresh() public {
        uint256 amt = 7000 ether;
        tokenA.approve(address(gauge), amt);

        // create new incentive
        gauge.createIncentive(key, tokenA, amt);
        (uint256 rate,, uint256 remaining) = gauge.incentiveData(pid, tokenA);
        assertEq(rate, amt / 7 days);
        assertEq(remaining, amt);
    }

    function testCreateIncentiveExtendsStream() public {
        uint256 first = 7000 ether;
        tokenA.approve(address(gauge), first);
        gauge.createIncentive(key, tokenA, first);

        // warp 1 day so some tokens streamed
        vm.warp(block.timestamp + 1 days);

        uint256 second = 6500 ether; // Must be > remaining (~6000 ether)
        tokenA.approve(address(gauge), second);
        gauge.createIncentive(key, tokenA, second);

        (, uint256 finish, uint256 remaining) = gauge.incentiveData(pid, tokenA);
        assertGt(finish, block.timestamp);
        uint256 expectedRemain = (first * 6 / 7) + second; // 6/7 of first day left + second
        assertApproxEqAbs(remaining, expectedRemain, 1e15);
    }

    function testWhitelistEnforced() public {
        MockERC20 other = new MockERC20("OTHER");
        uint256 amt = 1e18;
        other.transfer(address(gauge), amt);
        vm.expectRevert(DeliErrors.NotAllowed.selector);
        gauge.createIncentive(key, other, amt);
    }

    /*//////////////////////////////////////////////////////////////
                         _updatePoolByPid accrual
    //////////////////////////////////////////////////////////////*/

    function testUpdatePoolStreamsRewards() public {
        uint256 amt = 700 ether;
        tokenA.approve(address(gauge), amt);
        gauge.createIncentive(key, tokenA, amt);

        uint128 liq = 1_000_000;
        bytes32 posKey = keccak256("pos");
        gauge.pushOwnerPos(pid, address(this), posKey);
        gauge.setPositionState(posKey, tokenA, 0, 0, liq);
        gauge.setTickRange(posKey, -60, 60);
        gauge.setPoolLiquidity(pid, tokenA, liq);

        // simulate 1 day later with liquidity active
        vm.warp(block.timestamp + 1 days);
        pm.setLiquidity(PoolId.unwrap(pid), liq);
        vm.prank(hook);
        gauge.pokePool(key);

        // advance slightly and poke again so accumulator definitely grows
        vm.warp(block.timestamp + 10);
        vm.prank(hook);
        gauge.pokePool(key);

        uint256 pending = gauge.pendingRewards(posKey, tokenA, liq, pid);
        assertGt(pending, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        claimAllForOwner
    //////////////////////////////////////////////////////////////*/

    function testClaimAllForOwner() public {
        // Test direct claiming without going through claimAllForOwner
        uint256 amt = 700 ether;
        tokenA.approve(address(gauge), amt);
        gauge.createIncentive(key, tokenA, amt);

        uint128 liq = 1_000_000;
        bytes32 k = keccak256("pos");
        gauge.setPositionState(k, tokenA, 0, 10 ether, liq);
        gauge.setTickRange(k, -60, 60);

        // Check pending rewards
        uint256 pending = gauge.pendingRewards(k, tokenA, liq, pid);
        assertEq(pending, 10 ether);
    }
} 