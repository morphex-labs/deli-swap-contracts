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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract ERC20Mock is ERC20 {
    constructor(string memory n) ERC20(n,n) { _mint(msg.sender, 1e30); }
}

contract GaugeHarness is IncentiveGauge {
    constructor(IPoolManager pm,address hook) IncentiveGauge(pm,IPositionManagerAdapter(address(0x1)),hook) {}

    function setTickRange(bytes32 key,int24 lower,int24 upper) external {
        positionTicks[key] = TickRange({lower: lower, upper: upper});
    }
    function setPoolRpl(PoolId pid,IERC20 tok,uint256 rpl) external {
        poolRewards[pid][tok].rewardsPerLiquidityCumulativeX128 = rpl;
    }
    function setPosition(bytes32 key,IERC20 tok,uint256 paid,uint256 accrued,uint128 liq) external {
        RangePosition.State storage ps = positionRewards[key][tok];
        ps.rewardsPerLiquidityLastX128 = paid;
        ps.rewardsAccrued = accrued;
        positionLiquidity[key] = liq;
    }
    function pushPos(PoolId pid,address owner,bytes32 k) external { ownerPositions[pid][owner].push(k);}    
}

contract IncentiveGauge_ViewTest is Test {
    GaugeHarness gauge;
    MockPoolManager pm;
    ERC20Mock t1; ERC20Mock t2;
    PoolKey key; PoolId pid;
    address hookAddr = address(this);
    address owner = address(0xBEEF);

    function setUp() public {
        pm=new MockPoolManager();
        t1=new ERC20Mock("T1"); t2=new ERC20Mock("T2");
        gauge=new GaugeHarness(IPoolManager(address(pm)),hookAddr);
        gauge.setWhitelist(t1,true); gauge.setWhitelist(t2,true);
        key=PoolKey({currency0:Currency.wrap(address(0xAAA)),currency1:Currency.wrap(address(0xBBB)),fee:3000,tickSpacing:60,hooks:IHooks(address(0))});
        pid=key.toId();
        // Set slot0 with a valid sqrtPriceX96 at tick 0
        pm.setSlot0(PoolId.unwrap(pid), TickMath.getSqrtPriceAtTick(0), 0, 0, 0);
    }

    function _fund(IERC20 tok,uint256 amt) internal { tok.approve(address(gauge),amt); gauge.createIncentive(key,tok,amt);}    

    function testPoolTokensOf() public {
        _fund(t1,7e24); _fund(t2,7e24);
        IERC20[] memory list=gauge.poolTokensOf(pid);
        assertEq(list.length,2);
        assertTrue(list[0]==t1||list[0]==t2);
    }

    function testIncentiveDataBatch() public {
        uint256 amt=7e24;
        _fund(t1,amt);
        IERC20[] memory arr=new IERC20[](1); arr[0]=t1;
        (uint256[] memory rate,,)=gauge.incentiveDataBatch(pid,arr);
        assertEq(rate[0],amt/7 days);
    }

    function testPendingOwnerBatch() public {
        // ensure token registered
        _fund(t1, 1e24);

        // seed pool accumulator
        gauge.setPoolRpl(pid,t1,10*FixedPoint128.Q128);
        bytes32 k=keccak256("pos");
        gauge.setPosition(k,t1,5*FixedPoint128.Q128,1e18,1e6);
        gauge.setTickRange(k,-60,60);
        gauge.pushPos(pid,owner,k);
        PoolId[] memory pids=new PoolId[](1);pids[0]=pid;
        IERC20[] memory toks=new IERC20[](1); toks[0]=t1;
        IncentiveGauge.Pending[][] memory out=gauge.pendingRewardsOwnerBatch(pids,owner);
        assertGt(out[0][0].amount,1e18);
    }
} 