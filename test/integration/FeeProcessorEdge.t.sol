// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "src/DeliHook.sol";
import "src/FeeProcessor.sol";
import "src/DailyEpochGauge.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";

contract FeeProcessor_Edge_IT is Test, Deployers, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // contracts
    DeliHook hook;
    FeeProcessor fp;
    DailyEpochGauge gauge;
    MockIncentiveGauge inc;

    // tokens
    IERC20 wblt;
    IERC20 bmx;
    IERC20 other;

    // helpers
    PoolKey canonicalKey; // BMX/wBLT
    PoolKey otherKey;     // OTHER/wBLT
    PoolId pid;

    address constant VOTER_DST = address(0xCAFECAFE);

    function setUp() public {
        // ------------------------------------------------------------
        // 1. Spin up core stack
        // ------------------------------------------------------------
        deployArtifacts();

        // ------------------------------------------------------------
        // 2. Deploy three ERC20 tokens
        // ------------------------------------------------------------
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 _bmx, MockERC20 _wblt) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(_bmx));
        wblt = IERC20(address(_wblt));
        MockERC20 _other = new MockERC20("OTHER","OTHER",18);
        _other.mint(address(this), 1e27);
        other = IERC20(address(_other));

        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);
        other.approve(address(poolManager), type(uint256).max);

        // ERC20 approval so Permit2 can pull OTHER from this account
        _other.approve(address(permit2), type(uint256).max);

        // Permit2 approvals so PositionManager and PoolManager can pull OTHER via Permit2
        permit2.approve(address(_other), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(_other), address(poolManager),    type(uint160).max, type(uint48).max);

        // ------------------------------------------------------------
        // 3. Deploy hook + gauge + feeProcessor with pre-mined address
        // ------------------------------------------------------------
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx)
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);

        gauge = new DailyEpochGauge(
            address(0xFEE),
            poolManager,
            IPositionManager(address(0)),
            hookAddr,
            IERC20(address(bmx)),
            address(0)
        );
        fp = new FeeProcessor(poolManager, hookAddr, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), VOTER_DST);

        inc = new MockIncentiveGauge();

        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx)
        );
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // ------------------------------------------------------------
        // 4. Create two pools and seed minimal liquidity
        // ------------------------------------------------------------
        canonicalKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        otherKey = PoolKey({
            currency0: Currency.wrap(address(other)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(canonicalKey, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));

        // add trivial liquidity so pool has balances
        EasyPosm.mint(positionManager, canonicalKey, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp+1 hours, bytes(""));
        EasyPosm.mint(positionManager, otherKey, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp+1 hours, bytes(""));

        pid = canonicalKey.toId();
    }

    /*//////////////////////////////////////////////////////////////
                PoolManager.unlock callback implementation
    //////////////////////////////////////////////////////////////*/

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");

        (address tokenIn, uint256 amountIn) = abi.decode(data, (address, uint256));

        PoolKey memory key;
        SwapParams memory sp;

        if (tokenIn == address(other)) {
            key = otherKey;
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        } else if (tokenIn == address(bmx)) {
            key = canonicalKey;
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        } else if (tokenIn == address(wblt)) {
            key = canonicalKey;
            key.currency1.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
        } else {
            revert("unknown token");
        }

        BalanceDelta delta = poolManager.swap(key, sp, bytes(""));

        if (sp.zeroForOne) {
            uint256 outAmt = uint256(int256(delta.amount1()));
            if (outAmt > 0) key.currency1.take(poolManager, address(this), outAmt, false);
        } else {
            uint256 outAmt = uint256(int256(delta.amount0()));
            if (outAmt > 0) key.currency0.take(poolManager, address(this), outAmt, false);
        }
        poolManager.settle();
        return bytes("");
    }

    /*//////////////////////////////////////////////////////////////
                        TEST: late pool key
    //////////////////////////////////////////////////////////////*/

    function testLatePoolKeyFlush() public {
        uint256 swapIn = 5e20; // 500 OTHER → wBLT to generate wBLT fee buffer

        // Perform OTHER→wBLT exactInput swap via PoolManager.unlock pattern so hook logic runs
        poolManager.unlock(abi.encode(address(other), swapIn));

        // FeeProcessor should now hold pendingWbltForBuyback > 0
        uint256 buf = fp.pendingWbltForBuyback();
        assertGt(buf, 0, "buffer not populated");

        // Gauge bucket still zero
        assertEq(gauge.collectBucket(pid), 0, "bucket should be zero before key set");

        // Now set the buyback pool key
        fp.setBuybackPoolKey(canonicalKey);

        // Flush buffers – should execute buyback swap and stream BMX to gauge bucket
        fp.flushBuffers();

        // Buffers cleared
        assertEq(fp.pendingWbltForBuyback(), 0, "buyback buffer not cleared");

        // Gauge bucket increased by ~buf * 97% (buyback share)
        uint256 bucket = gauge.collectBucket(pid);
        assertGt(bucket, 0, "bucket not updated");
    }

    /*//////////////////////////////////////////////////////////////
                         TEST: slippage revert
    //////////////////////////////////////////////////////////////*/

    function testSlippageFailureKeepsBuffer() public {
        uint256 swapIn = 5e20; // create wBLT fee buffer first
        poolManager.unlock(abi.encode(address(other), swapIn));

        uint256 pending = fp.pendingWbltForBuyback();
        assertGt(pending, 0, "no pending buffer");

        // Register buy-back pool key
        fp.setBuybackPoolKey(canonicalKey);

        // Tighten slippage tolerance to 100% (i.e., require 1:1)
        fp.setMinOutBps(10000);

        // Expect flush to revert with "slippage" and buffer to remain
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffers();

        // Buffer should still be intact
        assertEq(fp.pendingWbltForBuyback(), pending, "buffer incorrectly cleared after failure");
    }

    /*//////////////////////////////////////////////////////////////
                    TEST: partial flush – BMX voter only
    //////////////////////////////////////////////////////////////*/
    function testPartialFlushVoterBufferOnly() public {
        // 1. Generate ONLY BMX voter buffer via canonical pool swap (BMX -> wBLT)
        uint256 swapIn = 1e20; // 100 BMX
        poolManager.unlock(abi.encode(address(bmx), swapIn));

        // buybackPortion credited immediately to gauge; voterPortion stored as BMX buffer
        uint256 voterBuf = fp.pendingBmxForVoter();
        assertGt(voterBuf, 0, "voter buffer not populated");
        assertEq(fp.pendingWbltForBuyback(), 0, "unexpected wblt buyback buffer");

        // 2. Set buyback pool key
        fp.setBuybackPoolKey(canonicalKey);

        // Record Voter destination balance before flush (wBLT token)
        uint256 preBal = wblt.balanceOf(VOTER_DST);

        // 3. Flush – should only process BMX→wBLT path
        fp.flushBuffers();

        // 4. Assertions: voter buffer cleared, buyback buffer unchanged (still zero)
        assertEq(fp.pendingBmxForVoter(), 0, "voter buffer not cleared");
        assertEq(fp.pendingWbltForBuyback(), 0, "buyback buffer should remain zero");

        uint256 postBal = wblt.balanceOf(VOTER_DST);
        assertGt(postBal - preBal, 0, "wBLT not transferred to voter dst");
    }
} 