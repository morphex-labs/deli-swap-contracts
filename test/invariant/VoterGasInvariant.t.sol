// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Voter} from "src/Voter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockRewardDistributor} from "test/mocks/MockRewardDistributor.sol";
import {TimeLibrary} from "src/libraries/TimeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VoterGasInvariant is Test {
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

    uint256 constant NUM_USERS = 1; // set to 2000 for full test, 1 is just to speed up overall testing

    function setUp() public {
        // Deploy tokens and distributor
        weth = new MockERC20("WETH","WETH",18);
        sbf  = new MockERC20("sBMX","sBMX",18);
        dist = new MockRewardDistributor();

        // Deploy voter starting now
        voter = new Voter(
            IERC20(address(weth)),
            IERC20(address(sbf)),
            safety,
            dist,
            block.timestamp,
            5000, 3000, 2000
        );
        // Set admin to this contract
        voter.setAdmin(address(this));

        // Create many users with auto-vote enabled
        for (uint256 i; i < NUM_USERS; ++i) {
            address u = address(uint160(i + 1));
            users.push(u);
            sbf.mint(u, 1e21);
            vm.prank(u);
            voter.vote(uint8(i % 3), true);
        }

        targetContract(address(this));
    }

    function fuzz_step(uint256 choice, uint256 p1, uint256 /*p2 unused*/) external {
        uint256 c = choice % 3;
        if (c == 0) {
            // time jump up to 14 days
            vm.warp(block.timestamp + bound(p1, 1, 14 days));
        } else if (c == 1) {
            // extra deposit
            uint256 amt = bound(p1, 1e18, 1e22);
            weth.mint(address(this), amt);
            weth.approve(address(voter), amt);
            voter.deposit(amt);
            totalDeposited += amt;
        } else {
            // finalize with tiny batch size 1-20
            uint256 batch = bound(p1, 1, 20);
            uint256 ep = voter.currentEpoch();
            try voter.finalize(ep, batch) {} catch {}
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_settleEventually() public {
        uint256 ep = voter.currentEpoch();
        if (ep == 0) return;
        // ensure previous epoch settled if it should
        if (block.timestamp < voter.epochEnd(ep - 1)) return;

        // attempt to finalize previous epoch in full
        try voter.finalize(ep - 1, NUM_USERS + 10) { } catch { }

        (, , bool settled) = voter.epochData(ep - 1);
        assertTrue(settled, "prev epoch not settled");
    }

    function invariant_wethConservation() public {
        uint256 balContract = weth.balanceOf(address(voter));
        uint256 balSafety = weth.balanceOf(safety);
        uint256 balDist = weth.balanceOf(address(dist));
        assertEq(balContract + balSafety + balDist, totalDeposited, "WETH conserved");
    }
}