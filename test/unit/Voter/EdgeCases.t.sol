// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Voter} from "src/Voter.sol";
import {MintableERC20} from "test/mocks/MintableERC20.sol";
import {MockRewardDistributor} from "test/mocks/MockRewardDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRewardDistributor} from "src/interfaces/IRewardDistributor.sol";

contract VoterHarnessEC is Voter {
    constructor(IERC20 _weth, IERC20 _sbfBmx, address _safety, IRewardDistributor _dist, uint256 _epochZero)
        Voter(_weth, _sbfBmx, _safety, _dist, _epochZero, 1000, 2000, 3000)
    {}

    function getWeights(uint256 ep) external view returns (uint256[3] memory w) {
        w = epochInfo[ep].optionWeight;
    }
}

contract Voter_EdgeCasesTest is Test {
    MintableERC20 weth;
    MintableERC20 sbf;
    MockRewardDistributor dist;
    VoterHarnessEC voter;
    address safety = address(0xCAFEBABE);
    uint256 epochZero;

    address user = address(0xAAA);

    function setUp() public {
        weth = new MintableERC20(); weth.initialize("WETH","WETH",18);
        sbf = new MintableERC20(); sbf.initialize("sBMX","sBMX",18);
        dist = new MockRewardDistributor();
        epochZero = block.timestamp; // now
        voter = new VoterHarnessEC(IERC20(address(weth)), IERC20(address(sbf)), safety, dist, epochZero);

        // Mint balances and approve
        weth.mintExternal(user, 10 ether);
        sbf.mintExternal(user, 100 ether);
        vm.prank(user); weth.approve(address(voter), type(uint256).max);

        // grant admin to user so they can call deposit/finalize
        voter.setAdmin(user);
    }

    function testAutoVoteNextEpoch() public {
        // Enable auto vote to option 2 via vote(option, enableAuto=true)
        vm.startPrank(user);
        voter.vote(2, true);
        // Deposit something so epoch0 totalWeth non-zero
        voter.deposit(1 ether);
        vm.stopPrank();

        // Move to next epoch
        vm.warp(block.timestamp + 8 days);
        // Deposit again – auto-vote should kick in for epoch1
        vm.prank(user);
        voter.deposit(2 ether);

        // Move forward another week so epoch1 ends and tally
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        voter.finalize(1, 10);

        uint256[3] memory w = voter.getWeights(1);
        assertEq(w[2], 100 ether, "auto vote weight applied");
    }

    function testDisableAutoVote() public {
        // Enable auto vote first
        vm.prank(user);
        voter.vote(1, true);

        // Disable before next deposit
        vm.prank(user);
        voter.vote(1, false);

        // Move to next epoch
        vm.warp(block.timestamp + 8 days);

        // Deposit, should NOT cast vote automatically
        vm.prank(user);
        voter.deposit(1 ether);

        // finalize epoch1 to tally auto votes (should be none)
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        voter.finalize(1, 10);

        uint256[3] memory w = voter.getWeights(1);
        // All weights should be zero (since no explicit vote)
        assertEq(w[0] + w[1] + w[2], 0, "auto vote disabled");
    }

    // Auto-vote weight follows live balance changes across epochs
    function testAutoVoteUpdatesWithNewBalance() public {
        // Enable auto for option0 with initial 100 sbf
        vm.prank(user);
        voter.vote(0, true);

        // Warp to next epoch
        vm.warp(block.timestamp + 8 days);

        // Mint +50 sbf to user in current epoch
        sbf.mintExternal(user, 50 ether);

        // Deposit some WETH so epoch has funds
        vm.prank(user);
        voter.deposit(1 ether);

        // End epoch1 and finalize
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        voter.finalize(1, 10);

        uint256[3] memory w = voter.getWeights(1);
        assertEq(w[0], 150 ether, "auto vote should use updated balance");
    }

    // Auto-voter is removed when balance drops to zero before tally
    function testAutoVoterRemovedAfterBalanceZero() public {
        // Enable auto option1
        vm.prank(user);
        voter.vote(1, true);

        // Warp to next epoch
        vm.warp(block.timestamp + 8 days);

        // Transfer away full balance so user now has 0 sbf
        vm.startPrank(user);
        uint256 bal = sbf.balanceOf(user);
        sbf.transfer(address(0xDEAD), bal);
        vm.stopPrank();

        // Deposit to create non-zero epoch total
        vm.prank(user);
        voter.deposit(1 ether);

        // Finish epoch1
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        voter.finalize(1, 10);

        uint256[3] memory w = voter.getWeights(1);
        assertEq(w[0] + w[1] + w[2], 0, "weight should be zero after balance drained");
    }

    // Re-enable auto-vote with different option after disabling
    function testReenableAutoVoteDifferentOption() public {
        // Enable auto option0
        vm.prank(user);
        voter.vote(0, true);

        // Disable it
        vm.prank(user);
        voter.vote(0, false);

        // Re-enable with option2
        vm.prank(user);
        voter.vote(2, true);

        // Warp to next epoch and deposit
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        voter.deposit(1 ether);

        // End epoch1
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        voter.finalize(1, 10);

        uint256[3] memory w = voter.getWeights(1);
        assertEq(w[2], 100 ether, "new option weight should apply");
        assertEq(w[0], 0, "old option weight should be cleared");
    }
} 