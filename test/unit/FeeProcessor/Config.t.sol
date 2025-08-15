// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Additional FeeProcessor tests focusing on owner config functions and voter fee claim.
contract FeeProcessor_ConfigTest is Test {
    FeeProcessor fp;
    MockDailyEpochGauge gauge;

    address constant HOOK = address(uint160(0xbeef));
    address constant VOTER_DIST = address(uint160(0xcafe));

    address constant BMX_TOKEN = address(0x1111111111111111111111111111111111111111);
    address constant WBLT_TOKEN = address(0x2222222222222222222222222222222222222222);
    address constant OTHER_TOKEN = address(0x3333333333333333333333333333333333333333);

    IPoolManager constant PM = IPoolManager(address(0));

    function setUp() public {
        gauge = new MockDailyEpochGauge();
        fp = new FeeProcessor(PM, HOOK, WBLT_TOKEN, BMX_TOKEN, gauge, VOTER_DIST);
    }

    // ------------------------------------------------------------
    // setBuybackBps / setMinOutBps
    // ------------------------------------------------------------

    function testOwnerCanUpdateBuybackBps() public {
        fp.setBuybackBps(5000);
        assertEq(fp.buybackBps(), 5000);
    }

    function testUpdateBuybackBpsTooHighReverts() public {
        vm.expectRevert(DeliErrors.InvalidBps.selector);
        fp.setBuybackBps(10001);
    }

    function testOwnerCanUpdateMinOutBps() public {
        fp.setMinOutBps(9500);
        assertEq(fp.minOutBps(), 9500);
    }

    function testUpdateMinOutBpsTooHighReverts() public {
        vm.expectRevert(DeliErrors.InvalidBps.selector);
        fp.setMinOutBps(10001);
    }

    // ------------------------------------------------------------
    // flushBuffers access control
    // ------------------------------------------------------------

    function testFlushBuffersRevertsWithoutPoolKey() public {
        vm.expectRevert(DeliErrors.NoKey.selector);
        // Can use any pool ID, will revert before checking
        fp.flushBuffer(PoolId.wrap(bytes32(0)));
    }

    // ------------------------------------------------------------
    // claimVoterFees logic
    // ------------------------------------------------------------

    function _makePoolKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(OTHER_TOKEN),
            currency1: Currency.wrap(WBLT_TOKEN),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _fundVoterBuffer(uint256 amount) internal {
        // Simulate fee collection from non-BMX pool to accrue wBLT voter balance.
        // Transfer wBLT to FeeProcessor (mock ERC20 transfer not required here for accounting)
        PoolKey memory key = _makePoolKey();
        vm.prank(HOOK);
        fp.collectFee(key, amount, false);

        // now pendingWbltForVoter increased by voterPortion (3%)
    }

    function testClaimVoterFees() public {
        uint256 totalFee = 1_000 ether;
        _fundVoterBuffer(totalFee);

        uint256 expectedVoterPortion = (totalFee * (10_000 - fp.buybackBps())) / 10_000; // 3%

        // mock ERC20 transfer expectation
        bytes memory transferCallData = abi.encodeWithSelector(bytes4(0xa9059cbb), VOTER_DIST, expectedVoterPortion);
        vm.expectCall(WBLT_TOKEN, transferCallData);
        vm.mockCall(WBLT_TOKEN, transferCallData, abi.encode(true));

        vm.prank(address(this));
        fp.claimVoterFees(VOTER_DIST);

        assertEq(fp.pendingWbltForVoter(), 0, "pendingWbltForVoter should be cleared");
    }

    function testClaimVoterFeesNotOwnerReverts() public {
        address caller = address(1234);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        fp.claimVoterFees(address(1));
    }
} 