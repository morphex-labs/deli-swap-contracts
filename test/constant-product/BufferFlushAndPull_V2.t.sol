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
            poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), VOTER_DST
        );
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
        assertEq(fp.pendingWbltForBuyback(), buybackPortion, "buyback buf");
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter buf");

        // In V2 model, sender only pays the input amount (fee is implicit in output reduction)
        uint256 balAfter = wblt.balanceOf(address(this));
        assertEq(balBefore - balAfter, input, "input amount mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                     TESTS – buffer flush & buy-back
    //////////////////////////////////////////////////////////////*/
    function testBufferFlush() public {
        uint256 input = 1e17;

        // 1. Generate wBLT buy-back buffer via OTHER -> wBLT swap
        poolManager.unlock(abi.encode(address(other), input));

        // 2. Generate BMX voter buffer via canonical pool swap
        poolManager.unlock(abi.encode(address(bmx), input));

        assertGt(fp.pendingWbltForBuyback(), 0, "no wblt buffer");
        assertGt(fp.pendingBmxForVoter(), 0, "no bmx buffer");

        // 3. Configure buyback pool
        fp.setBuybackPoolKey(canonicalKey);

        uint32 dayNow = uint32(block.timestamp / 1 days);
        uint256 bucketBefore = gauge.dayBuckets(canonicalKey.toId(), dayNow + 2);
        uint256 voterBefore = wblt.balanceOf(VOTER_DST);

        // 4. Flush – executes two internal swaps
        fp.flushBuffers();

        assertEq(fp.pendingWbltForBuyback(), 0, "buyback buf not cleared");
        
        // The BMX voter buffer will have a small residual from the internal BMX->wBLT swap
        // This is expected behavior as internal swaps now collect fees
        uint256 bmxVoterResidual = fp.pendingBmxForVoter();
        assertGt(bmxVoterResidual, 0, "should have residual from internal swap");
        
        // The residual should be small (3% of 0.3% = 0.009% of the swap amount)
        assertLt(bmxVoterResidual, input * 3000 / 1e6 / 100, "residual should be small");

        uint256 bucketAfter = gauge.dayBuckets(canonicalKey.toId(), dayNow + 2);
        assertGt(bucketAfter, bucketBefore, "bucket not updated");

        uint256 voterAfter = wblt.balanceOf(VOTER_DST);
        assertGt(voterAfter, voterBefore, "voter not funded");
    }

    /*//////////////////////////////////////////////////////////////
            TEST – wBLT -> BMX swap on canonical pool (immediate bucket)
    //////////////////////////////////////////////////////////////*/
    function testWbltToBmxCanonical() public {
        uint256 input = 1e17;

        // wBLT (token1) -> BMX swap on canonical pool
        poolManager.unlock(abi.encode(address(wblt), input, true)); // true = use canonical

        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4;
        uint256 voterPortion = feeAmt - buybackPortion;

        uint256 bucket = gauge.dayBuckets(canonicalKey.toId(), uint32(block.timestamp / 1 days) + 2);
        assertEq(bucket, buybackPortion, "bucket credit");
        assertEq(fp.pendingBmxForVoter(), voterPortion, "voter buf");
    }

    /*//////////////////////////////////////////////////////////////
               TEST – flush with only wBLT buy-back buffer
    //////////////////////////////////////////////////////////////*/
    function testFlushSingleBuyback() public {
        uint256 input = 1e17;
        poolManager.unlock(abi.encode(address(other), input));
        uint256 buf = fp.pendingWbltForBuyback();
        assertGt(buf, 0, "no buf");

        fp.setBuybackPoolKey(canonicalKey);
        fp.flushBuffers();

        assertEq(fp.pendingWbltForBuyback(), 0, "buyback not cleared");
        assertGt(gauge.dayBuckets(canonicalKey.toId(), uint32(block.timestamp / 1 days) + 2), 0, "bucket empty");
    }

    /*//////////////////////////////////////////////////////////////
                  TEST – slippage revert keeps buffers intact
    //////////////////////////////////////////////////////////////*/
    function testSlippageFailure() public {
        uint256 input = 1e17;
        poolManager.unlock(abi.encode(address(other), input));
        uint256 pending = fp.pendingWbltForBuyback();
        assertGt(pending, 0, "buf");

        fp.setBuybackPoolKey(canonicalKey);
        fp.setMinOutBps(10000); // 100% minOut – will fail
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffers();

        assertEq(fp.pendingWbltForBuyback(), pending, "buf lost");
    }

    /*//////////////////////////////////////////////////////////////
             TEST – claimVoterFees transfers accumulated wBLT
    //////////////////////////////////////////////////////////////*/
    function testClaimVoterFees() public {
        uint256 input = 2e17;
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
               tight slippage success – 0.5 % tolerance
    //////////////////////////////////////////////////////////////*/
    function testSlippageTightSuccess() public {
        uint256 input = 1e17;
        poolManager.unlock(abi.encode(address(other), input));
        uint256 buf = fp.pendingWbltForBuyback();
        assertGt(buf, 0, "no buf");

        fp.setBuybackPoolKey(canonicalKey);
        fp.setMinOutBps(9950); // 0.5 %

        uint32 dayNow2 = uint32(block.timestamp / 1 days);
        uint256 bucketBefore2 = gauge.dayBuckets(canonicalKey.toId(), dayNow2 + 2);
        fp.flushBuffers();
        assertEq(fp.pendingWbltForBuyback(), 0, "buf not cleared");
        uint256 bucketAfter = gauge.dayBuckets(canonicalKey.toId(), dayNow2 + 2);
        assertGt(bucketAfter, bucketBefore2, "bucket not incr");
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
        uint256 swapAmount = 1e18;
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
        fp.setMinOutBps(9900); // 1% slippage tolerance
        
        // Get pending fees and gauge state before flush
        uint256 pendingWblt = fp.pendingWbltForBuyback();
        assertGt(pendingWblt, 0, "Should have pending fees");
        uint32 dayNow3 = uint32(block.timestamp / 1 days);
        uint256 gaugeBucketBefore = gauge.dayBuckets(canonicalKey.toId(), dayNow3 + 2);
        uint256 pendingBmxForVoterBefore = fp.pendingBmxForVoter();
        
        fp.flushBuffers();
        
        // Verify fee distribution: 97% to gauge, 3% to voter buffer
        uint256 gaugeBucketAfter = gauge.dayBuckets(canonicalKey.toId(), dayNow3 + 2);
        uint256 pendingBmxForVoterAfter = fp.pendingBmxForVoter();
        
        uint256 gaugeIncrease = gaugeBucketAfter - gaugeBucketBefore;
        uint256 voterIncrease = pendingBmxForVoterAfter - pendingBmxForVoterBefore;
        
        // The flushBuffers() function triggers multiple internal swaps:
        // 1. wBLT → BMX buyback swap (collects fee in BMX)
        // 2. BMX → wBLT voter conversion swap (collects fee in BMX)
        
        // The gauge gets:
        // - The BMX output from the buyback swap
        // - 97% of the fee from both internal swaps
        
        // The voter buffer gets:
        // - 3% of the fee from both internal swaps
        
        // Verify basic sanity checks
        assertGt(gaugeIncrease, 0, "Gauge should receive funds");
        assertGt(voterIncrease, 0, "Voter should receive funds");
        
        // The gauge gets the swap output PLUS fees, so it should be close to the input amount
        assertGt(gaugeIncrease, pendingWblt * 99 / 100, "Gauge should get most of the input");
        assertLt(gaugeIncrease, pendingWblt, "Gauge should get less than input (some goes to fees)");
        
        // The voter buffer should be very small compared to gauge
        // Since gauge gets swap output + 97% of fees, and voter gets only 3% of fees
        assertLt(voterIncrease, gaugeIncrease / 100, "Voter should get much less than gauge");
        
        // The voter buffer gets a small residual from the cascading internal swaps
        // It's the 3% of the fee from the BMX→wBLT conversion swap
        assertGt(voterIncrease, 0, "Voter should receive residual fees");
        assertLt(voterIncrease, pendingWblt / 10000, "Voter residual should be tiny");
    }

    /*//////////////////////////////////////////////////////////////
              TEST – liquidity operations with fee collection
    //////////////////////////////////////////////////////////////*/
    function testLiquidityWithFees() public {
        // Perform some swaps to generate fees
        poolManager.unlock(abi.encode(address(bmx), 1e18));
        poolManager.unlock(abi.encode(address(wblt), 5e17, true)); // canonical pool
        
        // Check fees accumulated
        uint256 pendingBuyback = fp.pendingWbltForBuyback();
        uint256 pendingVoter = fp.pendingBmxForVoter();
        assertGt(pendingBuyback + pendingVoter, 0, "Should have fees");
        
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
        assertEq(fp.pendingWbltForBuyback(), pendingBuyback, "Buyback buffer unchanged");
        assertEq(fp.pendingBmxForVoter(), pendingVoter, "Voter buffer unchanged");
    }
}
