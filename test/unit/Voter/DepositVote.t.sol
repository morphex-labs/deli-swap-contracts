// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Voter} from "src/Voter.sol";
import {MintableERC20} from "test/mocks/MintableERC20.sol";
import {MockRewardDistributor} from "test/mocks/MockRewardDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {IRewardDistributor} from "src/interfaces/IRewardDistributor.sol";

// New: lightweight harness that exposes optionWeight array for testing purposes
contract VoterHarness is Voter {
    constructor(IERC20 _weth, IERC20 _sbfBmx, address _safety, IRewardDistributor _dist, uint256 _epochZero)
        // default option weights: 10%, 20%, 30%
        Voter(_weth, _sbfBmx, _safety, _dist, _epochZero, 1000, 2000, 3000)
    {}

    function getWeights(uint256 ep) external view returns (uint256[3] memory w) {
        w = epochInfo[ep].optionWeight;
    }
}

contract Voter_DepositVoteTest is Test {
    MintableERC20 weth;
    MintableERC20 sbf;
    MockRewardDistributor dist;

    VoterHarness voter;
    address safety = address(0xBEEF);
    uint256 epochZero;

    address user = address(0xAAA);
    address user2 = address(0xBBB);

    function setUp() public {
        weth = new MintableERC20(); weth.initialize("WETH","WETH",18);
        sbf = new MintableERC20(); sbf.initialize("sBMX","sBMX",18);
        dist = new MockRewardDistributor();
        epochZero = block.timestamp; // start now for simplicity
        voter = new VoterHarness(IERC20(address(weth)), IERC20(address(sbf)), safety, dist, epochZero);

        // fund users with tokens
        weth.mintExternal(user, 10 ether);
        sbf.mintExternal(user, 100 ether);
        weth.mintExternal(user2, 5 ether);
        sbf.mintExternal(user2, 40 ether);

        vm.prank(user); weth.approve(address(voter), type(uint256).max);
        vm.prank(user2); weth.approve(address(voter), type(uint256).max);

        // Grant `user` the admin role so they can call deposit/finalize in tests
        voter.setAdmin(user);
    }

    function testDepositUpdatesTotals() public {
        vm.prank(user);
        voter.deposit(2 ether);

        uint256 ep = voter.currentEpoch();
        (uint256 totalW, bool settled) = voter.epochInfo(ep);
        // silence unused var
        settled;
        assertEq(totalW, 2 ether);
        assertEq(weth.balanceOf(user), 8 ether);
        assertEq(weth.balanceOf(address(voter)), 2 ether);
    }

    function testVoteWeightsAndSwitch() public {
        // user votes option 1
        vm.prank(user);
        voter.vote(1, false);
        uint256 ep = voter.currentEpoch();
        uint256[3] memory w = voter.getWeights(ep);
        assertEq(w[1], 100 ether);

        // user switches to option 2
        vm.prank(user);
        voter.vote(2, false);
        w = voter.getWeights(ep);
        assertEq(w[1], 0);
        assertEq(w[2], 100 ether);
    }

    function testAutoVoteSetsWeight() public {
        // Enable auto-vote for option 0 via vote(…, true)
        vm.prank(user);
        voter.vote(0, true);

        uint256 ep = voter.currentEpoch();
        uint256[3] memory w = voter.getWeights(ep);
        assertEq(w[0], 100 ether);
    }

    function testDepositZeroReverts() public {
        vm.prank(user);
        vm.expectRevert(DeliErrors.ZeroAmount.selector);
        voter.deposit(0);
    }

    function testVoteInvalidOptionReverts() public {
        vm.prank(user);
        vm.expectRevert(DeliErrors.InvalidOption.selector);
        voter.vote(3, false);
    }
} 