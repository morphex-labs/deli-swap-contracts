// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/IncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {RangePool} from "src/libraries/RangePool.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockPoolKeysProvider} from "test/mocks/MockPoolKeysProvider.sol";
import {MockAdapterForKeys} from "test/mocks/MockAdapterForKeys.sol";

contract DummyToken is ERC20 {
    constructor(string memory n) ERC20(n,n) { _mint(msg.sender, 1e30); }
}

contract IncentiveGaugeHarness is IncentiveGauge {
    using RangePosition for RangePosition.State;
    using RangePool for RangePool.State;

    function setTickRange(bytes32 key, int24 lower, int24 upper) external {
        positionTicks[key] = TickRange({lower: lower, upper: upper});
    }

    constructor(IPoolManager pm, address hook) IncentiveGauge(pm, IPositionManagerAdapter(address(0x1)), hook) {}

    function poolRpl(PoolId pid, IERC20 tok) external view returns (uint256) {
        return poolRewards[pid].cumulativeRplX128(address(tok));
    }

    function posAccrued(bytes32 key, IERC20 tok) external view returns (uint256) {
        return positionRewards[key][tok].rewardsAccrued;
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

    // Mimic removed updatePosition hook entry for tests only.
    function updatePosition(
        PoolKey calldata key,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidity
    ) external {
        PoolId pid = key.toId();

        // maintain owner index & liquidity cache
        bytes32 posKey = keccak256(abi.encode(owner, tickLower, tickUpper, salt, pid));
        if (positionLiquidity[posKey] == 0 && liquidity > 0) {
            ownerPositions[pid][owner].push(posKey);
        }
        positionLiquidity[posKey] = liquidity;

        // Accrue pending rewards before taking new snapshot
        IERC20[] storage toks = poolTokens[pid];
        uint256 len = toks.length;
        for (uint256 i; i < len; ++i) {
            // Accrue based on previous snapshot and existing liquidity
            RangePosition.State storage ps = positionRewards[posKey][toks[i]];
            // accrue with old snapshot
            ps.accrue(positionLiquidity[posKey], poolRewards[pid].cumulativeRplX128(address(toks[i])));
            // set new snapshot
            ps.rewardsPerLiquidityLastX128 = poolRewards[pid].cumulativeRplX128(address(toks[i]));
            // ensure liquidity set for accumulator logic
            poolRewards[pid].liquidity = liquidity;
        }

        // store tick range so pendingRewards works
        positionTicks[posKey] = TickRange({lower: tickLower, upper: tickUpper});

        // Remove position if liquidity is zero
        if (liquidity == 0) {
            bytes32[] storage arr = ownerPositions[pid][owner];
            uint256 alen = arr.length;
            for (uint256 j; j < alen; ++j) {
                if (arr[j] == posKey) {
                    arr[j] = arr[alen - 1];
                    arr.pop();
                    break;
                }
            }
        }
    }
}


contract IncentiveGauge_StorageTest is Test {
    IncentiveGaugeHarness gauge;
    MockPoolManager pm;
    DummyToken reward;
    PoolKey key;
    PoolId pid;

    address hookAddr = address(this); // make test contract the hook

    function setUp() public {
        pm = new MockPoolManager();
        reward = new DummyToken("RWT");

        gauge = new IncentiveGaugeHarness(IPoolManager(address(pm)), hookAddr);

        // whitelist token
        gauge.setWhitelist(reward, true);

        key = PoolKey({
            currency0: Currency.wrap(address(0xAAA)),
            currency1: Currency.wrap(address(0xBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();

        // set pool liquidity for accumulator tests
        pm.setLiquidity(PoolId.unwrap(pid), 1_000_000);
        // Set slot0 with a valid sqrtPriceX96 at tick 0
        pm.setSlot0(PoolId.unwrap(pid), TickMath.getSqrtPriceAtTick(0), 0, 0, 0);

        vm.warp(1000); // deterministic start
        // Provide adapter for tickSpacing lookups and init via hook
        MockPoolKeysProvider pk = new MockPoolKeysProvider();
        MockAdapterForKeys ad = new MockAdapterForKeys(address(pk));
        gauge.setPositionManagerAdapter(address(ad));
        vm.prank(hookAddr);
        gauge.initPool(pid, 0);
    }

    /* createIncentive basic */
    function testCreateIncentive_New() public {
        uint256 amt = 7e24; // 7e24 / 7d = 1e18 per sec
        reward.transfer(address(this), amt);
        reward.approve(address(gauge), amt);
        gauge.createIncentive(key, reward, amt);
        (uint128 rate,uint64 finish,,uint128 rem) = gauge.incentives(pid, reward);
        assertEq(rate, uint128(amt / 7 days));
        assertEq(rem, amt);
        assertEq(finish, uint64(block.timestamp + 7 days));
    }

    /* leftover logic */
    function testCreateIncentive_TopUp() public {
        uint256 amt = 7e24;
        reward.approve(address(gauge), amt*2);
        gauge.createIncentive(key, reward, amt);
        // advance half duration
        vm.warp(block.timestamp + 3 days + 12 hours);
        gauge.createIncentive(key, reward, amt);
        (uint128 rate,, , uint128 remaining) = gauge.incentives(pid, reward);
        // remaining should be > amt because leftover added
        assertGt(remaining, amt);
        assertEq(rate, remaining / 7 days);
    }

    /* pool accumulator via pokePool */
    function testPokePoolUpdatesRpl() public {
        uint256 amt = 7e24;
        reward.approve(address(gauge), amt);
        gauge.createIncentive(key, reward, amt);
        // advance some time so dt>0
        vm.warp(block.timestamp + 1 hours);
        // add position to supply liquidity
        bytes32 s = 0x0;
        vm.prank(hookAddr);
        gauge.updatePosition(key, address(this), -60000, 60000, s, 1_000_000);
        // first poke initialises but dt=0
        gauge.pokePool(key);
        uint256 before = gauge.poolRpl(pid, reward);
        // second poke after dt>0 to accumulate
        vm.warp(block.timestamp + 10);
        gauge.pokePool(key);
        uint256 afterRpl = gauge.poolRpl(pid, reward);
        assertGt(afterRpl, before);
    }

    /* position accrue and claim */
    function testUpdateAndClaim() public {
        uint256 amt = 7e24;
        reward.approve(address(gauge), amt);
        gauge.createIncentive(key, reward, amt);

        // advance 1 day and poke to seed accumulator
        vm.warp(block.timestamp + 1 days);
        gauge.pokePool(key);

        // update position
        bytes32 salt = 0x0;
        vm.prank(hookAddr);
        gauge.updatePosition(key, address(1), -60000, 60000, salt, 1_000_000);
        vm.warp(block.timestamp + 3600);
        gauge.pokePool(key);
        // allow another small advance and poke to accrue
        vm.warp(block.timestamp + 10);
        gauge.pokePool(key);
        bytes32 posKey = keccak256(abi.encode(address(1), int24(-60000), int24(60000), salt, pid));
        uint256 pending = gauge.pendingRewards(posKey, reward, 1_000_000, pid);
        assertGt(pending, 0);
    }
} 