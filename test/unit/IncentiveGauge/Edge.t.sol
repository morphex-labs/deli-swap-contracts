// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/IncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RangePool} from "src/libraries/RangePool.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract ERC20Mock is ERC20 {
    constructor(string memory n) ERC20(n, n) { _mint(msg.sender, 1e24); }
}

contract GaugeHarnessEdge is IncentiveGauge {
    constructor(address pm, address hook) IncentiveGauge(IPoolManager(pm), IPositionManagerAdapter(address(1)), hook) {}

    function setPositionState(bytes32 k, IERC20 tok, uint256 paid, uint256 acc, uint128 liq) external {
        RangePosition.State storage ps = positionRewards[k][tok];
        ps.rewardsPerLiquidityLastX128 = paid;
        ps.rewardsAccrued = acc;
        positionLiquidity[k] = liq;
    }

    function setPoolLiquidity(PoolId pid, IERC20 tok, uint128 liq) external {
        poolRewards[pid][tok].liquidity = liq;
    }
    function pushOwnerPos(PoolId pid, address o, bytes32 k) external { ownerPositions[pid][o].push(k); }

    // expose pool update wrapper to trigger stream bookkeeping
    function forceUpdate(PoolKey calldata k) external {
        PoolId pid = k.toId();
        (, int24 tick,,) = StateLibrary.getSlot0(POOL_MANAGER, pid);
        IERC20[] storage arr = poolTokens[pid];
        uint len = arr.length;
        for (uint i; i < len; ++i) {
            _updatePool(k, pid, arr[i], tick);
        }
    }
}

contract IncentiveGauge_EdgeTest is Test {
    MockPoolManager pm;
    GaugeHarnessEdge gauge;
    address hook = address(0xBEEF);

    ERC20Mock tokA;
    ERC20Mock tokB;

    PoolKey key;
    PoolId pid;

    function setUp() public {
        pm = new MockPoolManager();
        gauge = new GaugeHarnessEdge(address(pm), hook);
        tokA = new ERC20Mock("A");
        tokB = new ERC20Mock("B");
        gauge.setWhitelist(tokA, true);
        gauge.setWhitelist(tokB, true);

        key = PoolKey({
            currency0: Currency.wrap(address(tokA)),
            currency1: Currency.wrap(address(0xBBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();
        pm.setLiquidity(PoolId.unwrap(pid), 1_000_000);
    }

    /* multiple token incentives + claim */
    function testMultiTokenClaim() public {
        uint256 amtA = 700 ether; uint256 amtB = 400 ether;
        tokA.approve(address(gauge), amtA);
        tokB.approve(address(gauge), amtB);
        gauge.createIncentive(key, tokA, amtA);
        gauge.createIncentive(key, tokB, amtB);

        bytes32 k = keccak256("pos");
        gauge.pushOwnerPos(pid, address(this), k);
        gauge.setPositionState(k, tokA, 0, 5 ether, 1e6);
        gauge.setPositionState(k, tokB, 0, 3 ether, 1e6);
        gauge.setPoolLiquidity(pid, tokA, 1e6);
        gauge.setPoolLiquidity(pid, tokB, 1e6);

        uint256 preA = tokA.balanceOf(address(this));
        uint256 preB = tokB.balanceOf(address(this));

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        gauge.claimAllForOwner(arr, address(this));

        assertEq(tokA.balanceOf(address(this)) - preA, 5 ether);
        assertEq(tokB.balanceOf(address(this)) - preB, 3 ether);
    }

    /* stream expiry */
    function testStreamEndsAtPeriodFinish() public {
        // choose amount that gives integer rewardRate: 1 ether/sec for 7 days
        uint256 amt = 604_800 ether; // 604800 = seconds in 7 days
        tokA.approve(address(gauge), amt);
        gauge.createIncentive(key, tokA, amt);
        (, uint256 finish,) = gauge.incentiveData(pid, tokA);
        vm.warp(finish + 1);
        vm.prank(hook);
        gauge.forceUpdate(key);
        (uint256 rate,, uint256 remaining) = gauge.incentiveData(pid, tokA);
        assertEq(rate, 0);
        assertEq(remaining, 0);
    }

    /* zero liquidity skip */
    function testUpdatePoolZeroLiquidityNoRevert() public {
        uint256 amt = 70 ether;
        tokA.approve(address(gauge), amt);
        gauge.createIncentive(key, tokA, amt);
        pm.setLiquidity(PoolId.unwrap(pid), 0);
        vm.prank(hook);
        gauge.pokePool(key); // should not revert
    }

    /* view helpers */
    function testViewHelpersBatch() public {
        tokA.approve(address(gauge), 1 ether);
        gauge.createIncentive(key, tokA, 1 ether);
        tokB.approve(address(gauge), 1 ether);
        gauge.createIncentive(key, tokB, 1 ether);

        IERC20[] memory toks = gauge.poolTokensOf(pid);
        assertEq(toks.length, 2);

        (uint256[] memory rates,,) = gauge.incentiveDataBatch(pid, toks);
        assertEq(rates.length, 2);

        PoolId[] memory arr = new PoolId[](1); arr[0] = pid;
        IncentiveGauge.Pending[][] memory pending = gauge.pendingRewardsOwnerBatch(arr, address(this));
        assertEq(pending.length, 1);
    }
} 