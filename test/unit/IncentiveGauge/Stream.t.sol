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

// Mocks
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

// Simple ERC20 mock
contract MockERC20 is ERC20 {
    constructor(string memory n) ERC20(n,n) { _mint(msg.sender, 1e24); }
}

// Harness exposing internal helpers
contract GaugeHarness is IncentiveGauge {
    constructor(address pm, address posMgr, address hook)
        IncentiveGauge(IPoolManager(pm), IPositionManagerAdapter(posMgr), hook) {}

    function setTickRange(bytes32 key, int24 lower, int24 upper) external {
        positionTicks[key] = TickRange({lower: lower, upper: upper});
    }

    function setPoolRpl(PoolId pid, IERC20 tok, uint256 rpl) external {
        poolRewards[pid][tok].rewardsPerLiquidityCumulativeX128 = rpl;
    }

    function setPositionState(bytes32 k, IERC20 tok, uint256 paid, uint256 acc, uint128 liq) external {
        RangePosition.State storage ps = positionRewards[k][tok];
        ps.rewardsPerLiquidityLastX128 = paid;
        ps.rewardsAccrued = acc;
        positionLiquidity[k] = liq;
    }

    function setPoolLiquidity(PoolId pid, IERC20 tok, uint128 liq) external {
        poolRewards[pid][tok].liquidity = liq;
    }

    function pushOwnerPos(PoolId pid, address owner, bytes32 k) external {
        ownerPositions[pid][owner].push(k);
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

        uint256 second = 3500 ether;
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
                         _updatePool accrual
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
        uint256 amt = 700 ether;
        tokenA.approve(address(gauge), amt);
        gauge.createIncentive(key, tokenA, amt);

        uint128 liq = 1_000_000;
        bytes32 k = keccak256("pos");
        gauge.pushOwnerPos(pid, address(this), k);
        gauge.setPositionState(k, tokenA, 0, 10 ether, liq);
        gauge.setTickRange(k, -60, 60);

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 pre = tokenA.balanceOf(address(this));
        gauge.claimAllForOwner(arr, address(this));
        uint256 post = tokenA.balanceOf(address(this));
        assertEq(post - pre, 10 ether);
        assertEq(gauge.pendingRewards(k, tokenA, liq, pid), 0);
    }
} 