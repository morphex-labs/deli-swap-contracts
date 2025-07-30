// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IncentiveGaugeInvariant is Test {
    /*//////////////////////////////////////////////////////////////
                                  CONTRACTS
    //////////////////////////////////////////////////////////////*/
    MockPoolManager pm;
    IncentiveGauge gauge;

    MockERC20 t0;
    MockERC20 t1;

    PoolKey key;
    PoolId pid;

    mapping(address => uint256) public totalFunded;

    function setUp() public {
        // deploy tokens
        t0 = new MockERC20("T0","T0",18);
        t1 = new MockERC20("T1","T1",18);
        t0.mint(address(this), 1e25);
        t1.mint(address(this), 1e25);

        // deploy mock pool manager
        pm = new MockPoolManager();

        // deploy gauge with hook = address(this) so we can call pokePool
        gauge = new IncentiveGauge(IPoolManager(address(pm)), IPositionManager(address(0x1)), address(this));

        // whitelist tokens (also implicit pool currency so allowed anyway)
        gauge.setWhitelist(IERC20(address(t0)), true);
        gauge.setWhitelist(IERC20(address(t1)), true);

        // craft pool key
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();

        // ensure tokens approved
        t0.approve(address(gauge), type(uint256).max);
        t1.approve(address(gauge), type(uint256).max);

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ STEP
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(bool useToken0, uint256 amount, uint256 secForward) external {
        // bound amount
        uint256 amt = bound(amount, 1e18, 1e22); // 1e18 to 1e22
        MockERC20 tok = useToken0 ? t0 : t1;

        // create incentive
        gauge.createIncentive(key, IERC20(address(tok)), amt);
        totalFunded[address(tok)] += amt;

        // advance time up to 3 days
        uint256 dt = bound(secForward, 1, 3 days);
        vm.warp(block.timestamp + dt);

        // Update pool state so streaming counters move; this will reduce `remaining` over time.
        gauge.pokePool(key);
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function _checkToken(MockERC20 tok) internal {
        (uint256 rate, uint256 finish, uint256 remaining) = gauge.incentiveData(pid, IERC20(address(tok)));
        uint256 bal = tok.balanceOf(address(gauge));
        // gauge balance should never drop below remaining
        assertGe(bal, remaining, "gauge balance lower than remaining");
        // remaining cannot exceed total funded
        assertLe(remaining, totalFunded[address(tok)], "remaining > funded");
        // if stream active, remaining should be at least rate * secondsLeft
        if (rate > 0 && block.timestamp < finish) {
            uint256 secsLeft = finish - block.timestamp;
            uint256 minRem = rate * secsLeft;
            assertGe(remaining, minRem - 1, "remaining less than expected");
        }
    }

    function invariant_token0() external {
        _checkToken(t0);
    }

    function invariant_token1() external {
        _checkToken(t1);
    }
} 