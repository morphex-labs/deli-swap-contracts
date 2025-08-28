// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Voter} from "src/Voter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockRewardDistributor} from "test/mocks/MockRewardDistributor.sol";
import {TimeLibrary} from "src/libraries/TimeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VoterInvariant is Test {
    /*//////////////////////////////////////////////////////////////
                                  TOKENS
    //////////////////////////////////////////////////////////////*/
    MockERC20 weth;
    MockERC20 sbf;

    /*//////////////////////////////////////////////////////////////
                                  CONTRACTS
    //////////////////////////////////////////////////////////////*/
    Voter voter;
    MockRewardDistributor dist;
    address safety = address(0xBEEF);

    /*//////////////////////////////////////////////////////////////
                               STATE TRACK
    //////////////////////////////////////////////////////////////*/
    uint256 totalDeposited;
    address[] users;
    uint256 usersCount = 10; // set to 200 for testing

    function setUp() public {
        weth = new MockERC20("WETH","WETH",18);
        sbf  = new MockERC20("sBMX","sBMX",18);
        dist = new MockRewardDistributor();

        uint256 epochZero = block.timestamp; // start now
        voter = new Voter(
            IERC20(address(weth)),
            IERC20(address(sbf)),
            safety,
            dist,
            epochZero,
            5000, 3000, 2000 // options 50%,30%,20% (irrelevant for invariant)
        );

        // owner is address(this) → set admin to this contract
        voter.setAdmin(address(this));

        // mint tokens to users
        for (uint256 i; i < usersCount; ++i) {
            address addr = address(uint160(i + 1));
            users.push(addr);
            sbf.mint(addr, 1e22);
        }

        targetContract(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ STEP
    //////////////////////////////////////////////////////////////*/

    function fuzz_step(uint256 action, uint256 param1, uint256 param2, uint256 param3) external {
        uint256 act = action % 4;
        if (act == 0) {
            // admin deposit
            uint256 amt = (param1 % 1e20) + 1; // keep deposits modest to avoid extreme weights
            weth.mint(address(this), amt);
            weth.approve(address(voter), amt);
            voter.deposit(amt);
            totalDeposited += amt;
        } else if (act == 1) {
            // user vote / auto toggle
            address user = users[param1 % users.length];
            uint8 opt = uint8(param2 % 3);
            bool enable = param3 % 2 == 0;
            vm.prank(user);
            voter.vote(opt, enable);
        } else if (act == 2) {
            // time advance
            uint256 secs = (param1 % (2 * TimeLibrary.WEEK)) + 1;
            vm.warp(block.timestamp + secs + 1);
        } else {
            // finalize current epoch if ended
            uint256 cur = voter.currentEpoch();
            // attempt prior two epochs finalize loops
            for (uint256 ep = 0; ep <= cur; ++ep) {
                // we call finalize with large batch to process all
                try voter.finalize(ep, 1000) { } catch { }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_wethConservation() public view {
        uint256 balContract = weth.balanceOf(address(voter));
        uint256 balSafety   = weth.balanceOf(safety);
        uint256 balDist     = weth.balanceOf(address(dist));
        assertEq(balContract + balSafety + balDist, totalDeposited, "WETH conservation failed");
    }

    function invariant_weightConsistency() public view {
        uint256 ep = voter.currentEpoch();
        ( , uint256[3] memory weights, bool settled) = voter.epochData(ep);

        uint256 check0; uint256 check1; uint256 check2;
        uint256 len = users.length;
        for (uint256 i; i < len; ++i) {
            address u = users[i];
            (uint8 opt, uint256 weight) = voter.getUserVote(ep, u);
            (, bool autoEnabled) = voter.autoVoteOf(u);
            // For ongoing epochs, skip all auto-enabled users since their live weights are not yet tallied
            if (!settled && autoEnabled) continue;
            if (opt == 0) check0 += weight;
            else if (opt == 1) check1 += weight;
            else if (opt == 2) check2 += weight;
        }

        if (settled) {
            // On settled epochs, all auto-votes are tallied; equality must hold
            assertEq(weights[0], check0, "opt0 weights mismatch");
            assertEq(weights[1], check1, "opt1 weights mismatch");
            assertEq(weights[2], check2, "opt2 weights mismatch");
        } else {
            // On ongoing epochs, stored weights must be at least the sum of manual votes
            assertGe(weights[0], check0, "opt0 weights mismatch");
            assertGe(weights[1], check1, "opt1 weights mismatch");
            assertGe(weights[2], check2, "opt2 weights mismatch");
        }
    }
} 