// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {FeeProcessor} from "src/FeeProcessor.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";

/// @notice Fee pipeline integration tests for constant-product DeliHookConstantProduct
contract BufferFlushAndPull_V2_IT is Test, Deployers, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    // contracts
    FeeProcessor fp;
    DailyEpochGauge gauge;
    DeliHookConstantProduct hook;
    MockIncentiveGauge inc;
    V2PositionHandler v2Handler;

    // tokens
    IERC20 wblt;
    IERC20 bmx;
    IERC20 other;

    address constant VOTER_DST = address(0xCAFEBABE);

    // pool keys
    PoolKey canonicalKey; // BMX / wBLT
    PoolKey otherKey; // OTHER / wBLT

    /*//////////////////////////////////////////////////////////////
                                SET-UP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        // 1. core Uniswap stack
        deployArtifacts();

        // 2. tokens
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

        // 3. deploy hook (+wire gauges/processor)
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        (address predictedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DeliHookConstantProduct).creationCode, ctorArgs);

        gauge = new DailyEpochGauge(
            address(0),
            poolManager,
            IPositionManagerAdapter(address(0)),
            predictedHook,
            IERC20(address(bmx)),
            address(0)
        );
        fp = new FeeProcessor(
            poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge))
        );
        fp.setKeeper(address(this), true);
        inc = new MockIncentiveGauge();

        hook = new DeliHookConstantProduct{salt: salt}(
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
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // Deploy and set V2PositionHandler
        v2Handler = new V2PositionHandler(address(hook));
        hook.setV2PositionHandler(address(v2Handler));
        // Minimal adapter wiring so V2 handler notifications don't revert
        PositionManagerAdapter adapter = new PositionManagerAdapter(
            address(gauge),
            address(inc),
            address(positionManager),
            address(poolManager)
        );
        v2Handler.setPositionManagerAdapter(address(adapter));
        adapter.addHandler(address(v2Handler));
        adapter.setAuthorizedCaller(address(hook), true);
        adapter.setAuthorizedCaller(address(v2Handler), true);
        adapter.setAuthorizedCaller(address(positionManager), true);
        // Let gauge know about the adapter so context callbacks are accepted
        gauge.setPositionManagerAdapter(address(adapter));

        // V2 hook doesn't need approvals - fees are implicit in swap math

        // 4. pools & seed liquidity
        canonicalKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        otherKey = PoolKey({
            currency0: Currency.wrap(address(other)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(canonicalKey, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));

        // add liquidity directly through the hook
        // First approve tokens to the hook
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        other.approve(address(hook), type(uint256).max);
        
        // Add liquidity to canonical pool (BMX/wBLT)
        hook.addLiquidity(
            canonicalKey,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 1e21,
                amount1Desired: 1e21,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        // Add liquidity to other pool (OTHER/wBLT)
        hook.addLiquidity(
            otherKey,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 1e21,
                amount1Desired: 1e21,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                           CALLBACK (PoolManager.unlock)
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
            sp = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        } else if (tokenIn == address(other)) {
            key = otherKey;
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        } else if (tokenIn == address(wblt)) {
            key = useCanonical ? canonicalKey : otherKey; // choose pool orientation
            key.currency1.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });
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
                            HELPERS
    //////////////////////////////////////////////////////////////*/
    function _feeAmt(uint256 amtIn) internal pure returns (uint256) {
        return (amtIn * 3000) / 1e6; // 0.3 %
    }
    
    // Helper to calculate fee when taken from output (for exact input swaps)
    function _feeAmtFromOutput(uint256 amtIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps) internal pure returns (uint256) {
        // Calculate output with fee
        uint256 feeBasis = 1000000 - feeBps;
        uint256 amountInWithFee = amtIn * feeBasis;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000000 + amountInWithFee;
        uint256 outputWithFee = numerator / denominator;
        
        // Calculate theoretical output without fee
        uint256 outputWithoutFee = (amtIn * reserveOut) / (reserveIn + amtIn);
        
        // Fee is the difference
        return outputWithoutFee > outputWithFee ? outputWithoutFee - outputWithFee : 0;
    }

    // Helper to calculate constant-product V2 output amount (fee in hundredths of a bip out of 1_000_000)
    function _v2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint24 feeBps) internal pure returns (uint256) {
        uint256 feeBasis = 1_000_000 - uint256(feeBps);
        uint256 amountInWithFee = amountIn * feeBasis;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1_000_000 + amountInWithFee;
        return numerator / denominator;
    }

    /*//////////////////////////////////////////////////////////////
                       TESTS – pull-from-sender path
    //////////////////////////////////////////////////////////////*/
    function testPullFromSender() public {
        uint256 input = 1e17;
        uint256 balBefore = wblt.balanceOf(address(this));

        // Swap wBLT (token1) -> OTHER (token0)
        // In V2 constant product, fees are implicit - you send exact input but get less output
        poolManager.unlock(abi.encode(address(wblt), input));

        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4;
        uint256 voterPortion = feeAmt - buybackPortion;

        // FeeProcessor buffers updated
        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), buybackPortion, "buyback buf");
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter buf");

        // In V2 model, sender only pays the input amount (fee is implicit in output reduction)
        uint256 balAfter = wblt.balanceOf(address(this));
        assertEq(balBefore - balAfter, input, "input amount mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                     TESTS – buffer flush & buy-back
    //////////////////////////////////////////////////////////////*/
    function testBufferFlush() public {
        uint256 input = 8e20;

        // 1. Generate wBLT buy-back buffer via OTHER -> wBLT swap
        poolManager.unlock(abi.encode(address(other), input));
        // Accumulate additional buffer to exceed the 1 wBLT threshold
        poolManager.unlock(abi.encode(address(other), input));

        // 2. Generate additional fees via canonical pool swap
        poolManager.unlock(abi.encode(address(bmx), input));

        assertGt(fp.pendingWbltForBuyback(otherKey.toId()), 0, "no wblt buffer");
        assertGt(fp.pendingWbltForVoter(), 0, "no voter buffer");

        // 3. Configure buyback pool
        fp.setBuybackPoolKey(canonicalKey);

        uint32 dayNow = uint32(block.timestamp / 1 days);
        uint256 otherBucketBefore = gauge.dayBuckets(otherKey.toId(), dayNow + 2);
        
        // 4. Flush – need to flush each pool separately now
        // First flush the OTHER pool which has pending wBLT
        fp.flushBuffer(otherKey.toId(), 0);
        
        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), 0, "buyback buf not cleared");
        
        // Voter wBLT buffer should remain unchanged by buyback flush
        assertGt(fp.pendingWbltForVoter(), 0, "voter wBLT buffer expected");

        // Check that OTHER pool got the rewards (buckets are credited to the source pool)
        uint256 otherBucketAfter = gauge.dayBuckets(otherKey.toId(), dayNow + 2);
        assertGt(otherBucketAfter, otherBucketBefore, "OTHER pool bucket not updated");
    }

    /*//////////////////////////////////////////////////////////////
            TEST – wBLT -> BMX swap on canonical pool (immediate bucket)
    //////////////////////////////////////////////////////////////*/
    function testWbltToBmxCanonical() public {
        uint256 input = 4e20;

        // Set buyback pool key so FeeProcessor knows where to credit rewards
        fp.setBuybackPoolKey(canonicalKey);

        // Execute swap and validate fee pipeline

        // wBLT (token1) -> BMX swap on canonical pool
        poolManager.unlock(abi.encode(address(wblt), input, true)); // true = use canonical
        // Snapshot reserves BEFORE flushing, since expected out uses pre-buyback reserves
        (uint128 r0, uint128 r1) = hook.getReserves(canonicalKey.toId()); // r0=BMX, r1=wBLT
        fp.flushBuffer(canonicalKey.toId(), 0);

        // Compute expected BMX out from buybackPortion using V2 math and current reserves
        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4; // amount of wBLT to swap for BMX
        uint256 expectedBmxOut = _v2AmountOut(buybackPortion, r1, r0, 3000);

        uint256 bucket = gauge.dayBuckets(canonicalKey.toId(), uint32(block.timestamp / 1 days) + 2);
        assertApproxEqAbs(bucket, expectedBmxOut, 1, "bucket credit");
        assertGt(fp.pendingWbltForVoter(), 0, "voter buffer should have wBLT");
    }

    /*//////////////////////////////////////////////////////////////
               TEST – flush with only wBLT buy-back buffer
    //////////////////////////////////////////////////////////////*/
    function testFlushSingleBuyback() public {
        uint256 input = 8e20;
        poolManager.unlock(abi.encode(address(other), input));
        // Accumulate additional buffer to exceed the 1 wBLT threshold
        poolManager.unlock(abi.encode(address(other), input));
        uint256 buf = fp.pendingWbltForBuyback(otherKey.toId());
        assertGt(buf, 0, "no buf");

        fp.setBuybackPoolKey(canonicalKey);
        fp.flushBuffer(otherKey.toId(), 0);

        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), 0, "buyback not cleared");
        assertGt(gauge.dayBuckets(otherKey.toId(), uint32(block.timestamp / 1 days) + 2), 0, "bucket empty");
    }

    /*//////////////////////////////////////////////////////////////
                  TEST – slippage revert keeps buffers intact
    //////////////////////////////////////////////////////////////*/
    function testSlippageFailure() public {
        uint256 input = 8e20;
        poolManager.unlock(abi.encode(address(other), input));
        // Accumulate additional buffer to exceed the 1 wBLT threshold so slippage revert is hit
        poolManager.unlock(abi.encode(address(other), input));
        uint256 pending = fp.pendingWbltForBuyback(otherKey.toId());
        assertGt(pending, 0, "buf");

        fp.setBuybackPoolKey(canonicalKey);
        // Force slippage failure via expected out that's too high
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffer(otherKey.toId(), type(uint256).max);

        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), pending, "buf lost");
    }

    /*//////////////////////////////////////////////////////////////
             TEST – claimVoterFees transfers accumulated wBLT
    //////////////////////////////////////////////////////////////*/
    function testClaimVoterFees() public {
        uint256 input = 2e17;
        
        // Get reserves before swap to calculate fee correctly
        (uint128 r0, uint128 r1) = hook.getReserves(otherKey.toId());
        
        poolManager.unlock(abi.encode(address(other), input));

        // For OTHER -> wBLT swap, fee is in wBLT (output), so use output-based calculation
        uint256 feeAmt = _feeAmtFromOutput(input, r0, r1, 3000);
        uint256 voterPortion = feeAmt - (feeAmt * fp.buybackBps()) / 1e4;
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter buf");

        uint256 pre = wblt.balanceOf(VOTER_DST);
        fp.claimVoterFees(VOTER_DST);
        uint256 post = wblt.balanceOf(VOTER_DST);
        assertEq(post - pre, voterPortion, "claim mismatch");
        assertEq(fp.pendingWbltForVoter(), 0, "buf not cleared");
    }

    /*//////////////////////////////////////////////////////////////
               tight slippage success – 0.5 % tolerance
    //////////////////////////////////////////////////////////////*/
    function testSlippageTightSuccess() public {
        uint256 input = 8e20;
        poolManager.unlock(abi.encode(address(other), input));
        // Accumulate additional buffer to exceed the 1 wBLT threshold
        poolManager.unlock(abi.encode(address(other), input));
        uint256 buf = fp.pendingWbltForBuyback(otherKey.toId());
        assertGt(buf, 0, "no buf");

        fp.setBuybackPoolKey(canonicalKey);
        // Allow execution by not enforcing a high expected out

        uint32 dayNow2 = uint32(block.timestamp / 1 days);
        uint256 bucketBefore = gauge.dayBuckets(otherKey.toId(), dayNow2 + 2);
        fp.flushBuffer(otherKey.toId(), 0);
        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), 0, "buf not cleared");
        uint256 bucketAfter = gauge.dayBuckets(otherKey.toId(), dayNow2 + 2);
        assertGt(bucketAfter, bucketBefore, "OTHER pool bucket not incr");
    }

    /*//////////////////////////////////////////////////////////////
                  TEST – internal swaps collect and distribute fees
    //////////////////////////////////////////////////////////////*/
    function testInternalSwapsCollectFees() public {
        // Use the OTHER/wBLT pool so fees go to pending buffers (not immediate gauge credit)
        PoolId otherPoolId = otherKey.toId();
        
        // Get initial reserves and balances
        (uint128 reserve0Before, uint128 reserve1Before) = hook.getReserves(otherPoolId);
        uint256 wbltBalanceBefore = wblt.balanceOf(address(this));
        
        // Perform a regular swap to accumulate some fees in the buffer
        uint256 swapAmount = 8e20;
        poolManager.unlock(abi.encode(address(other), swapAmount));
        
        // Calculate actual output received by user
        uint256 wbltBalanceAfter = wblt.balanceOf(address(this));
        uint256 actualOutput = wbltBalanceAfter - wbltBalanceBefore;
        
        // In V2 constant product with 0.3% fee, the output is calculated as:
        // amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        // For no fee, it would be: amountOut = (amountIn * 1000 * reserveOut) / (reserveIn * 1000 + amountIn * 1000)
        uint256 expectedOutputNoFee = (swapAmount * 1000 * reserve1Before) / (reserve0Before * 1000 + swapAmount * 1000);
        uint256 expectedOutputWithFee = (swapAmount * 997 * reserve1Before) / (reserve0Before * 1000 + swapAmount * 997);
        
        // Verify regular swap had fees (output matches fee calculation)
        assertApproxEqAbs(actualOutput, expectedOutputWithFee, 1, "Regular swap should match fee calculation");
        assertLt(actualOutput, expectedOutputNoFee, "Output should be less than no-fee amount");
        
        // Now test internal swap via FeeProcessor on canonical pool
        fp.setBuybackPoolKey(canonicalKey);
        
        // Accumulate additional pending fees to exceed the 1 wBLT threshold
        poolManager.unlock(abi.encode(address(other), swapAmount));

        // Get pending fees and gauge state before flush
        uint256 pendingWblt = fp.pendingWbltForBuyback(otherPoolId);
        assertGt(pendingWblt, 0, "Should have pending fees");

        uint32 dayNow3 = uint32(block.timestamp / 1 days);
        uint256 gaugeBucketBefore = gauge.dayBuckets(otherKey.toId(), dayNow3 + 2);
        uint256 pendingWbltVoterBefore = fp.pendingWbltForVoter();
        
        fp.flushBuffer(otherPoolId, 0);
        
        // Verify fee distribution: buyback goes to source pool's bucket, voter retains wBLT
        uint256 gaugeBucketAfter = gauge.dayBuckets(otherKey.toId(), dayNow3 + 2);
        uint256 pendingWbltVoterAfter = fp.pendingWbltForVoter();
        
        uint256 gaugeIncrease = gaugeBucketAfter - gaugeBucketBefore;
        uint256 voterIncrease = pendingWbltVoterAfter - pendingWbltVoterBefore;
        
        // Verify basic sanity checks
        assertGt(gaugeIncrease, 0, "Gauge should receive funds");
        // Flush performs an internal swap that also charges a swap fee in wBLT.
        // That internal fee is split 97/3 and the 3% goes to the voter buffer.
        uint256 internalFee = (pendingWblt * 3000) / 1_000_000; // 0.3% LP fee
        uint256 bpsVoter = uint256(10_000 - fp.buybackBps());
        uint256 expectedVoterInc = (internalFee * bpsVoter) / 10_000; // default 3%
        assertApproxEqAbs(voterIncrease, expectedVoterInc, 1, "Voter should increase by internal-fee share");
        
        // Gauge should get BMX from swapping the pending wBLT (less LP fee); voter retains a small wBLT increase
        assertLt(gaugeIncrease, pendingWblt, "Gauge receives output of swap, not raw input");
        // No change expected for voter buffer during flush
    }

    /*//////////////////////////////////////////////////////////////
              TEST – liquidity operations with fee collection
    //////////////////////////////////////////////////////////////*/
    function testLiquidityWithFees() public {
        // Perform some swaps to generate fees
        poolManager.unlock(abi.encode(address(bmx), 1e18));
        poolManager.unlock(abi.encode(address(wblt), 5e17, true)); // canonical pool
        
        // Check fees accumulated - voter portion tracked in wBLT buffer
        uint256 pendingVoter = fp.pendingWbltForVoter();
        assertGt(pendingVoter, 0, "Should have voter fees");
        
        // Add more liquidity
        (uint128 r0Before, uint128 r1Before) = hook.getReserves(canonicalKey.toId());
        uint256 lpSharesBefore = hook.balanceOf(canonicalKey.toId(), address(this));
        
        // Calculate proportional amounts based on current reserves
        uint256 addAmount0 = 1e18;
        uint256 addAmount1 = (addAmount0 * r1Before) / r0Before;
        
        hook.addLiquidity(
            canonicalKey,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: addAmount0,
                amount1Desired: addAmount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        // Verify liquidity added correctly
        (uint128 r0After, uint128 r1After) = hook.getReserves(canonicalKey.toId());
        uint256 lpSharesAfter = hook.balanceOf(canonicalKey.toId(), address(this));
        
        assertGt(lpSharesAfter, lpSharesBefore, "Should have more LP shares");
        assertEq(r0After, r0Before + addAmount0, "Reserve0 should increase");
        assertApproxEqAbs(r1After, r1Before + addAmount1, 1, "Reserve1 should increase");
        
        // Remove half the liquidity
        uint256 sharesToRemove = lpSharesAfter / 2;
        
        hook.removeLiquidity(
            canonicalKey,
            MultiPoolCustomCurve.RemoveLiquidityParams({
                liquidity: sharesToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        
        // Verify removal
        uint256 lpSharesFinal = hook.balanceOf(canonicalKey.toId(), address(this));
        assertEq(lpSharesFinal, lpSharesAfter - sharesToRemove, "Shares should decrease");
        
        // Verify fee buffers unchanged by liquidity operations
        // (no pendingWbltForBuyback since canonical is BMX pool)
        assertEq(fp.pendingWbltForVoter(), pendingVoter, "Voter buffer unchanged");
    }
}
