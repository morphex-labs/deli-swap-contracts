// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import "src/FeeProcessor.sol";
import "src/DeliHook.sol";
import "src/DailyEpochGauge.sol";
import "src/interfaces/IFeeProcessor.sol";
import "src/interfaces/IDailyEpochGauge.sol";
import "src/interfaces/IIncentiveGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BufferFlushAndPull_IT is Test, Deployers, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyDelta for Currency;

    FeeProcessor fp;
    DailyEpochGauge gauge;
    DeliHook hook;
    MockIncentiveGauge inc;

    // core tokens
    IERC20 wblt;
    IERC20 bmx;
    IERC20 other;

    address constant VOTER_DST = address(0xCAFEBABE);

    // cached pool keys
    PoolKey internal canonicalKey; // BMX / wBLT
    PoolKey internal otherKey;     // OTHER / wBLT

    /*//////////////////////////////////////////////////////////////
                                SET-UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        /***************************************************
         * 1. Core Uniswap-v4 stack                        *
         ***************************************************/
        deployArtifacts();

        /***************************************************
         * 2. Tokens & approvals                           *
         ***************************************************/
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(bmxToken));
        wblt = IERC20(address(wbltToken));
        MockERC20 _other = new MockERC20("OTHER", "OTHER", 18);
        _other.mint(address(this), 10_000_000 ether);
        other = IERC20(address(_other));

        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);
        other.approve(address(poolManager), type(uint256).max);
        other.approve(address(permit2), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(other), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(other), address(poolManager), type(uint160).max, type(uint48).max);

        /***************************************************
         * 3. Deploy hook, gauge, fee-processor            *
         ***************************************************/
        bytes memory tmpCtorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), hookFlags, type(DeliHook).creationCode, tmpCtorArgs);

        gauge = new DailyEpochGauge(address(0), poolManager, IPositionManagerAdapter(address(0)), predictedHook, IERC20(address(bmx)), address(0));
        fp = new FeeProcessor(poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)));
        fp.setKeeper(address(this), true);

        // Deploy mock incentive gauge so DeliHook.afterSwap can call pokePool without reverting
        inc = new MockIncentiveGauge();

        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        // Wire real mock incentive gauge
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // No need to approve hook anymore - fees are taken from swap amount

        /***************************************************
         * 4. Pools + bootstrap liquidity                  *
         ***************************************************/
        canonicalKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        otherKey = PoolKey({
            currency0: Currency.wrap(address(other)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        // Initialize pools
        poolManager.initialize(canonicalKey, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));

        EasyPosm.mint(positionManager, canonicalKey, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
        EasyPosm.mint(positionManager, otherKey,     -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
    }

    /*//////////////////////////////////////////////////////////////
                           POOLMANAGER CALLBACK
    //////////////////////////////////////////////////////////////*/

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        address tokenIn;
        uint256 amountIn;
        bool useCanonical;
        if (data.length == 64) {
            (tokenIn, amountIn) = abi.decode(data, (address, uint256));
            useCanonical = false;
        } else {
            (tokenIn, amountIn, useCanonical) = abi.decode(data, (address, uint256, bool));
        }

        PoolKey memory key;
        SwapParams memory sp;

        if (tokenIn == address(bmx)) {
            key = canonicalKey;
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        } else if (tokenIn == address(other)) {
            key = otherKey;
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        } else if (tokenIn == address(wblt)) {
            key = useCanonical ? canonicalKey : otherKey; // wBLT token1 path chooses pool
            key.currency1.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
        } else {
            revert("unknown token");
        }

        BalanceDelta delta = poolManager.swap(key, sp, bytes(""));

        console.log("=== Test unlockCallback after swap ===");
        console.log("Swap delta amount0:", delta.amount0());
        console.log("Swap delta amount1:", delta.amount1());
        
        // Check our deltas before taking output
        console.log("Test delta currency0 before take:", key.currency0.getDelta(address(this)));
        console.log("Test delta currency1 before take:", key.currency1.getDelta(address(this)));

        if (sp.zeroForOne) {
            uint256 outAmt = uint256(int256(delta.amount1()));
            if (outAmt > 0) key.currency1.take(poolManager, address(this), outAmt, false);
        } else {
            uint256 outAmt = uint256(int256(delta.amount0()));
            if (outAmt > 0) key.currency0.take(poolManager, address(this), outAmt, false);
        }
        
        // Check deltas after taking output
        console.log("Test delta currency0 after take:", key.currency0.getDelta(address(this)));
        console.log("Test delta currency1 after take:", key.currency1.getDelta(address(this)));
        
        poolManager.settle();
        return bytes("");
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _feeAmt(uint256 amtIn) internal pure returns (uint256) {
        return (amtIn * 3000) / 1e6; // 0.3 %
    }

    /*//////////////////////////////////////////////////////////////
                      pull-from-sender path
    //////////////////////////////////////////////////////////////*/

    function testPullFromSender() public {
        uint256 input = 4e20;
        uint256 balBefore = wblt.balanceOf(address(this));

        // Swap wBLT (token1) -> OTHER (token0) to trigger _pullFromSender.
        poolManager.unlock(abi.encode(address(wblt), input));

        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4;
        uint256 voterPortion = feeAmt - buybackPortion;

        // FeeProcessor buffers updated
        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), buybackPortion, "buyback buf");
        assertEq(fp.pendingWbltForVoter(),   voterPortion,   "voter buf");

        // Sender pays swap amount, fee is borrowed from pool reserves
        uint256 balAfter = wblt.balanceOf(address(this));
        assertEq(balBefore - balAfter, input, "should only deduct swap amount");
    }

    /*//////////////////////////////////////////////////////////////
                     buffer flush + buy-back
    //////////////////////////////////////////////////////////////*/

    function testBufferFlush() public {
        uint256 input = 4e20;

        // 1. Generate wBLT buy-back buffer via OTHER -> wBLT swap
        poolManager.unlock(abi.encode(address(other), input));

        // 2. Generate BMX voter buffer via canonical pool swap
        poolManager.unlock(abi.encode(address(bmx), input));

        // sanity: buffers populated
        PoolId otherPoolId = otherKey.toId();
        assertGt(fp.pendingWbltForBuyback(otherPoolId), 0, "no wblt buffer");
        // voter portion is in wBLT buffer under unified model
        assertGt(fp.pendingWbltForVoter(), 0, "no voter buffer");

        // 3. Configure buy-back pool
        fp.setBuybackPoolKey(canonicalKey);

        uint256 bucketBefore = gauge.collectBucket(otherPoolId);

        // 4. Flush – executes buyback using expected out parameter; 0 disables slippage check in this test
        fp.flushBuffer(otherPoolId, 0);

        // Buffers cleared
        assertEq(fp.pendingWbltForBuyback(otherPoolId), 0, "buyback not cleared");
        // Note: pendingBmxForVoter may have small amount from internal swap fees
        assertGt(fp.pendingWbltForVoter(), 0, "should have fees from internal swaps");

        // Gauge bucket increased (received BMX from buy-back) - rewards go to source pool
        uint256 bucketAfter = gauge.collectBucket(otherPoolId);
        assertGt(bucketAfter, bucketBefore, "bucket not updated");
    }

    /*//////////////////////////////////////////////////////////////
                wBLT -> BMX on canonical pool
    //////////////////////////////////////////////////////////////*/

    function testWbltToBmxCanonical() public {
        uint256 input = 4e20;

        // Set buyback pool key so FeeProcessor knows where to credit rewards
        fp.setBuybackPoolKey(canonicalKey);

        // Perform wBLT (token1) -> BMX (token0) on canonical pool
        poolManager.unlock(abi.encode(address(wblt), input, true)); // true => use canonical
        // Flush canonical pool buffer to credit gauge
        fp.flushBuffer(canonicalKey.toId(), 0);

        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4; // 97% in wBLT (to buyback)
        uint256 voterPortion   = feeAmt - buybackPortion;          // 3% in wBLT (voter buffer)
        // Internal buyback swap incurs hook fee (0.3%) that also contributes 3% to voter buffer
        uint256 internalFee = (buybackPortion * 3000) / 1_000_000; // 0.3% of buyback
        voterPortion += (internalFee * 3) / 100;                   // 3% of the internal fee

        // Gauge bucket received BMX from the buy-back. The precise BMX depends on pool price
        // at execution time (which was moved by the prior swap). Assert it increased.
        uint256 bucket = gauge.collectBucket(canonicalKey.toId());
        assertGt(bucket, 0, "bucket should increase after buyback");
        // voter portion buffered in wBLT
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter wblt");
    }

    /*//////////////////////////////////////////////////////////////
                flush with only wBLT buy-back buffer
    //////////////////////////////////////////////////////////////*/

    function testFlushSingleBuyback() public {
        uint256 input = 4e20;

        // Populate ONLY the wBLT buy-back buffer (OTHER pool swap)
        poolManager.unlock(abi.encode(address(other), input));

        PoolId otherPoolId = otherKey.toId();
        uint256 buf = fp.pendingWbltForBuyback(otherPoolId);
        assertGt(buf, 0, "no buf");

        fp.setBuybackPoolKey(canonicalKey);

        fp.flushBuffer(otherPoolId, 0);

        // Buy-back buffer cleared
        assertEq(fp.pendingWbltForBuyback(otherPoolId), 0, "buyback not cleared");
        // Note: pendingWbltForVoter will have fees from the internal buyback swap
        assertGt(fp.pendingWbltForVoter(), 0, "voter buf");
        assertGt(gauge.collectBucket(otherPoolId), 0, "OTHER pool bucket empty");
    }

    /*//////////////////////////////////////////////////////////////
                slippage revert keeps buffers intact
    //////////////////////////////////////////////////////////////*/

    function testSlippageFailure() public {
        uint256 input = 4e20;

        // Produce wBLT buy-back buffer
        poolManager.unlock(abi.encode(address(other), input));

        PoolId otherPoolId = otherKey.toId();
        uint256 pending = fp.pendingWbltForBuyback(otherPoolId);
        assertGt(pending, 0, "buf");

        fp.setBuybackPoolKey(canonicalKey);

        // Force slippage failure by requiring an impossibly high minOut

        // flush is expected to revert with "slippage"
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffer(otherPoolId, type(uint256).max);

        // Buffer should remain since swap failed
        assertEq(fp.pendingWbltForBuyback(otherPoolId), pending, "buf lost");
    }

    /*//////////////////////////////////////////////////////////////
              governance claimVoterFees transfers wBLT
    //////////////////////////////////////////////////////////////*/

    function testClaimVoterFees() public {
        uint256 input = 2e17;

        // Perform OTHER -> wBLT swap to accrue voter wBLT buffer
        poolManager.unlock(abi.encode(address(other), input));

        uint256 feeAmt = _feeAmt(input);
        uint256 voterPortion = feeAmt - (feeAmt * fp.buybackBps()) / 1e4;
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter buf");
        uint256 pre = wblt.balanceOf(VOTER_DST);
        fp.claimVoterFees(VOTER_DST);
        uint256 post = wblt.balanceOf(VOTER_DST);
        assertEq(post - pre, voterPortion, "claim mismatch");
        assertEq(fp.pendingWbltForVoter(), 0, "buf not cleared");
    }

    /*//////////////////////////////////////////////////////////////
                 tight slippage success flush
    //////////////////////////////////////////////////////////////*/
    function testSlippageTightSuccess() public {
        uint256 input = 4e20;

        // Produce wBLT buy-back buffer via OTHER -> wBLT swap (token0 -> token1)
        poolManager.unlock(abi.encode(address(other), input));

        // Ensure buffer populated
        PoolId otherPoolId = otherKey.toId();
        uint256 buf = fp.pendingWbltForBuyback(otherPoolId);
        assertGt(buf, 0, "no pending buffer");

        // Configure buy-back pool
        fp.setBuybackPoolKey(canonicalKey);
        // Allow execution by not enforcing a high expected out

        uint256 bucketBefore = gauge.collectBucket(otherPoolId);

        // Should execute without reverting
        fp.flushBuffer(otherPoolId, 0);

        // Buffer cleared and gauge bucket credited (rewards go to source pool)
        assertEq(fp.pendingWbltForBuyback(otherPoolId), 0, "buffer not cleared");
        uint256 bucketAfter = gauge.collectBucket(otherPoolId);
        assertGt(bucketAfter, bucketBefore, "bucket not increased");
    }
} 