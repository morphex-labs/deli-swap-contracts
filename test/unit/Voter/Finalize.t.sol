// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Voter} from "src/Voter.sol";
import {MintableERC20} from "test/mocks/MintableERC20.sol";
import {MockRewardDistributor} from "test/mocks/MockRewardDistributor.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRewardDistributor} from "src/interfaces/IRewardDistributor.sol";

// Lightweight harness exposing optionWeight for assertions
contract VoterHarness is Voter {
    constructor(IERC20 _weth, IERC20 _sbfBmx, address _safety, IRewardDistributor _dist, uint256 _epochZero)
        Voter(_weth, _sbfBmx, _safety, _dist, _epochZero, 1000, 2000, 3000)
    {}

    function getWeights(uint256 ep) external view returns (uint256[3] memory w) {
        w = epochInfo[ep].optionWeight;
    }
}

contract Voter_FinalizeTest is Test {
    MintableERC20 weth;
    MintableERC20 sbf;
    MockRewardDistributor dist;
    VoterHarness voter;
    address safety = address(0xDEAD);
    uint256 epochZero;

    address user1 = address(0xAAA);
    address user2 = address(0xBBB);

    function setUp() public {
        // Deploy mocks
        weth = new MintableERC20(); weth.initialize("WETH","WETH",18);
        sbf = new MintableERC20(); sbf.initialize("sBMX","sBMX",18);
        dist = new MockRewardDistributor();
        epochZero = block.timestamp; // current timestamp as epoch0 start
        voter = new VoterHarness(IERC20(address(weth)), IERC20(address(sbf)), safety, dist, epochZero);

        // Mint initial balances
        weth.mintExternal(user1, 15 ether);
        sbf.mintExternal(user1, 100 ether);
        weth.mintExternal(user2, 5 ether);
        sbf.mintExternal(user2, 40 ether);

        vm.prank(user1); weth.approve(address(voter), type(uint256).max);
        vm.prank(user2); weth.approve(address(voter), type(uint256).max);

        // grant admin rights to user1 for deposit/finalize
        voter.setAdmin(user1);
    }

    function _depositAndVote() internal {
        // admin user1 deposits 15 WETH and votes option1 (20%)
        vm.startPrank(user1);
        voter.deposit(15 ether);
        voter.vote(1, false);
        vm.stopPrank();

        // user2 votes option2 (30%)
        vm.prank(user2);
        voter.vote(2, false);
    }

    function testFinalizeTransfersAndRate() public {
        _depositAndVote();

        uint256 total = 15 ether;
        uint256 expectSafety = (total * 2000) / 10_000; // 20% = 3 ETH
        uint256 expectRewards = total - expectSafety;   // 12 ETH
        uint256 expectRate = expectRewards / 1 weeks;

        // warp > 1 week to allow finalize
        vm.warp(block.timestamp + 8 days);
        vm.prank(user1);
        voter.finalize(0, 10);

        assertEq(weth.balanceOf(safety), expectSafety, "safety balance");
        assertEq(weth.balanceOf(address(dist)), expectRewards, "distributor balance");
        assertEq(dist.lastTokensPerInterval(), expectRate, "rate set");

        // Epoch marked settled
        (, bool settled) = voter.epochInfo(0);
        assertTrue(settled, "epoch settled");
    }

    function testTieBreakLowerIndexWins() public {
        // Give equal voting weight to both users
        sbf.mintExternal(user2, 60 ether); // now user2 has 100 sbf like user1

        // user1 (admin) deposits total 2 WETH
        vm.startPrank(user1);
        voter.deposit(2 ether);
        voter.vote(2, false);
        vm.stopPrank();

        // user2 casts vote without deposit
        vm.prank(user2);
        voter.vote(0, false);

        // warp > 1 week
        vm.warp(block.timestamp + 8 days);
        vm.prank(user1);
        voter.finalize(0, 10);

        // Option0 (10%) should win due to lower index tie-break
        uint256 total = 2 ether;
        uint256 expectSafety = (total * 1000) / 10_000; // 0.2 ETH
        uint256 expectRewards = total - expectSafety;
        assertEq(weth.balanceOf(safety), expectSafety, "safety after tie");
        assertEq(weth.balanceOf(address(dist)), expectRewards, "rewards after tie");
    }

    function testFinalizeEarlyReverts() public {
        vm.prank(user1);
        vm.expectRevert(DeliErrors.EpochRunning.selector);
        voter.finalize(0, 10);
    }

    function testFinalizeDoubleReverts() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(user1);
        voter.finalize(0, 10);

        vm.prank(user1);
        vm.expectRevert(DeliErrors.AlreadySettled.selector);
        voter.finalize(0, 10);
    }

    function testBatchedFinalizeAcrossCalls() public {
        // create 12 auto-voters each with 1 sbf & auto option0
        for (uint256 i; i < 12; ++i) {
            address acc = address(uint160(uint256(0x1000) + i));
            sbf.mintExternal(acc, 1 ether);
            vm.prank(acc);
            voter.vote(0, true);
        }

        // Admin deposit
        vm.prank(user1);
        voter.deposit(1 ether);

        // Move past epoch0 end
        vm.warp(block.timestamp + 8 days);

        // First finalize with small batch (5) – should not finish all
        vm.prank(user1);
        voter.finalize(0, 5);

        // Distributor should still be empty because epoch not settled yet
        assertEq(dist.lastTokensPerInterval(), 0, "no rewards until full tally");

        // Now finalize remaining voters with bigger batch
        vm.prank(user1);
        voter.finalize(0, 20);

        // Rewards should now be emitted
        assertGt(dist.lastTokensPerInterval(), 0, "rewards emitted after full tally");
    }

    function testFinalizeZeroDeposits() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(user1);
        voter.finalize(0, 10);

        assertEq(weth.balanceOf(safety), 0, "safety bal zero");
        assertEq(weth.balanceOf(address(dist)), 0, "dist bal zero");
        assertEq(dist.lastTokensPerInterval(), 0, "rate zero");
    }
} 