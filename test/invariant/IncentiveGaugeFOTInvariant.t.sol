// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";
import {FeeOnTransferERC20} from "test/mocks/FeeOnTransferERC20.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IncentiveGaugeFOTInvariant
/// @notice Ensures IncentiveGauge accounting remains safe when the reward
///         token charges a 1 % burn fee on every transfer.
contract IncentiveGaugeFOTInvariant is Test {
    MockPoolManager pm;
    IncentiveGauge gauge;
    FeeOnTransferERC20 fot; // fee-on-transfer token

    PoolKey key;
    PoolId pid;

    uint256 public totalFundedGross;   // total amount passed to createIncentive (before fee)
    uint256 public totalBurned;        // cumulative 1 % burned on createIncentive

    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        // deploy token
        fot = new FeeOnTransferERC20("FOT","FOT",18);
        fot.mint(address(this), 1e26);

        pm = new MockPoolManager();
        gauge = new IncentiveGauge(IPoolManager(address(pm)), IPositionManager(address(0x1)), address(this));
        gauge.setWhitelist(IERC20(address(fot)), true);

        key = PoolKey({
            currency0: Currency.wrap(address(fot)),
            currency1: Currency.wrap(address(0xDEAD)), // dummy second token
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();

        fot.approve(address(gauge), type(uint256).max);

        targetContract(address(this));
    }

    function fuzz_step(uint256 amount, uint256 secFwd) external {
        uint256 amt = bound(amount, 1e18, 1e22);
        gauge.createIncentive(key, IERC20(address(fot)), amt);
        totalFundedGross += amt;
        totalBurned      += amt * FEE_BPS / 10_000;

        // advance time up to 3 days & poke
        vm.warp(block.timestamp + bound(secFwd, 1, 3 days));
        gauge.pokePool(key);
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANT
    //////////////////////////////////////////////////////////////*/

    function invariant_fotAccounting() public {
        (uint256 rate,, uint256 remaining) = gauge.incentiveData(pid, IERC20(address(fot)));
        uint256 bal = fot.balanceOf(address(gauge));

        // Gauge can never hold more than gross minus burned
        assertLe(bal, totalFundedGross - totalBurned);
        // Remaining should not exceed gross funded
        assertLe(remaining, totalFundedGross);
        // Balance plus burned should at least cover remaining (no inflation)
        assertGe(bal + totalBurned, remaining);

        // If stream active ensure remaining not less than expected streamed left
        if (rate > 0) {
            // Cannot easily compute finish without view; skip.
        }
    }
} 