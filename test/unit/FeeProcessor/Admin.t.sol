// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MockERC20} from "lib/uniswap-hooks/lib/v4-core/lib/forge-std/src/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

contract MintableERC20 is MockERC20 {
    function mintExternal(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice FeeProcessor tests covering admin helpers & edge-cases.
contract FeeProcessor_AdminTest is Test {
    using PoolIdLibrary for PoolKey;
    
    FeeProcessor fp;
    MockDailyEpochGauge gauge;
    MintableERC20 miscToken;

    address constant HOOK = address(uint160(0xbeef));
    address constant VOTER = address(uint160(0xcafe));

    address constant BMX_TOKEN = address(0x1111111111111111111111111111111111111111);
    address constant WBLT_TOKEN = address(0x2222222222222222222222222222222222222222);

    IPoolManager constant PM = IPoolManager(address(0));

    function setUp() public {
        gauge = new MockDailyEpochGauge();
        fp = new FeeProcessor(PM, HOOK, WBLT_TOKEN, BMX_TOKEN, gauge, VOTER);

        miscToken = new MintableERC20();
        miscToken.initialize("Misc", "MISC", 18);
        miscToken.mintExternal(address(fp), 1e18);
    }

    // ---------------------------------------------------------------------
    // sweepERC20
    // ---------------------------------------------------------------------

    function testSweepERC20CoreTokenReverts() public {
        vm.expectRevert(DeliErrors.NotAllowed.selector);
        fp.sweepERC20(WBLT_TOKEN, 1e18, address(this));
    }

    function testSweepERC20TransfersTokens() public {
        uint256 amt = 1e18;
        bytes memory transferCall = abi.encodeWithSelector(miscToken.transfer.selector, address(this), amt);
        vm.expectCall(address(miscToken), transferCall);

        fp.sweepERC20(address(miscToken), amt, address(this));
        assertEq(miscToken.balanceOf(address(this)), amt, "receiver did not receive tokens");
    }

    // ---------------------------------------------------------------------
    // flushBuffers when buybackPoolSet but empty buffers ‑ should not revert
    // ---------------------------------------------------------------------
    function _makePoolKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(BMX_TOKEN),
            currency1: Currency.wrap(WBLT_TOKEN),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function testFlushBuffersNoopWhenEmpty() public {
        // set pool key first
        PoolKey memory key = _makePoolKey();
        fp.setBuybackPoolKey(key);
        // should not revert even though buffers zero
        fp.flushBuffer(key.toId());
    }

    // ---------------------------------------------------------------------
    // claimVoterFees no funds revert
    // ---------------------------------------------------------------------
    function testClaimVoterFeesNoFundsReverts() public {
        vm.expectRevert(DeliErrors.NoFunds.selector);
        fp.claimVoterFees(address(this));
    }
} 