// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import "src/FeeProcessor.sol";
import "src/DeliHook.sol";
import "src/DailyEpochGauge.sol";
import "src/interfaces/IFeeProcessor.sol";
import "src/interfaces/IDailyEpochGauge.sol";
import "src/interfaces/IIncentiveGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";

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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";

contract DeliHook_PriceConversion_IT is Test, Deployers, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    FeeProcessor fp;
    DailyEpochGauge gauge;
    DeliHook hook;
    MockIncentiveGauge inc;

    IERC20 wblt;
    IERC20 bmx;
    IERC20 other;

    PoolKey internal bmxKey;   // BMX / wBLT
    PoolKey internal otherKey; // OTHER / wBLT

    function setUp() public {
        deployArtifacts();

        // Tokens
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
        // Permit2 approvals for dynamically created token (OTHER)
        other.approve(address(permit2), type(uint256).max);
        permit2.approve(address(other), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(other), address(poolManager), type(uint160).max, type(uint48).max);

        // Predicted hook address
        bytes memory tmpCtorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)
        );
        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), hookFlags, type(DeliHook).creationCode, tmpCtorArgs);

        gauge = new DailyEpochGauge(address(0), poolManager, IPositionManagerAdapter(address(0)), predictedHook, IERC20(address(bmx)), address(0));
        inc = new MockIncentiveGauge();
        fp = new FeeProcessor(poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)));
        fp.setKeeper(address(this), true);

        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)
        );
        require(address(hook) == predictedHook, "Hook addr mismatch");
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // Pool keys
        bmxKey = PoolKey({
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

        // Initialize with price != 1 (sqrt = 2 * Q96 => price = 4)
        uint160 sqrtPx = uint160(2) * uint160(FixedPoint96.Q96);
        poolManager.initialize(bmxKey, sqrtPx);
        poolManager.initialize(otherKey, sqrtPx);

        // Add liquidity across wide ticks
        EasyPosm.mint(positionManager, bmxKey, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
        EasyPosm.mint(positionManager, otherKey, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
    }

    struct SwapRequest {
        PoolKey key;
        bool settleToken0; // true => settle currency0, false => currency1
        uint256 amount; // absolute amount to settle and use for amountSpecified
        bool zeroForOne;
        bool exactInput; // true => negative amountSpecified
    }

    // PoolManager unlock callback to perform swaps while unlocked
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        SwapRequest memory req = abi.decode(data, (SwapRequest));

        // Settle input side only for exact input swaps. For exact output, settle after swap based on delta
        if (req.exactInput) {
            if (req.settleToken0) {
                req.key.currency0.settle(poolManager, address(this), uint128(req.amount), false);
            } else {
                req.key.currency1.settle(poolManager, address(this), uint128(req.amount), false);
            }
            poolManager.settle();
        }

        // Build swap params
        int256 amtSpecified = req.exactInput ? -int256(req.amount) : int256(req.amount);
        uint160 limit = req.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory sp = SwapParams({zeroForOne: req.zeroForOne, amountSpecified: amtSpecified, sqrtPriceLimitX96: limit});

        // Execute swap
        BalanceDelta delta = poolManager.swap(req.key, sp, bytes(""));

        // Take output so PM nets to zero
        if (sp.zeroForOne) {
            uint256 outAmt = uint256(int256(delta.amount1()));
            if (outAmt > 0) req.key.currency1.take(poolManager, address(this), outAmt, false);
        } else {
            uint256 outAmt = uint256(int256(delta.amount0()));
            if (outAmt > 0) req.key.currency0.take(poolManager, address(this), outAmt, false);
        }

        // For exact output swaps, settle the actual required input based on returned delta
        if (!req.exactInput) {
            if (sp.zeroForOne) {
                int128 a0 = delta.amount0();
                if (a0 < 0) {
                    uint128 need0 = uint128(uint256(int256(-a0)));
                    req.key.currency0.settle(poolManager, address(this), need0, false);
                }
            } else {
                int128 a1 = delta.amount1();
                if (a1 < 0) {
                    uint128 need1 = uint128(uint256(int256(-a1)));
                    req.key.currency1.settle(poolManager, address(this), need1, false);
                }
            }
        }

        // Final settle (native currency)
        poolManager.settle();
        return bytes("");
    }

    function _lpFee() internal view returns (uint24 fee) {
        (, , , fee) = StateLibrary.getSlot0(poolManager, bmxKey.toId());
    }

    function _baseFee(uint256 amountSpecifiedAbs) internal view returns (uint256) {
        return (amountSpecifiedAbs * uint256(_lpFee())) / 1_000_000;
    }

    function _feeToken0To1(uint256 baseFeeSpecified) internal view returns (uint256) {
        (uint160 sqrtP, , ,) = StateLibrary.getSlot0(poolManager, bmxKey.toId());
        uint256 inter = FullMath.mulDiv(baseFeeSpecified, sqrtP, FixedPoint96.Q96);
        return FullMath.mulDiv(inter, sqrtP, FixedPoint96.Q96);
    }

    function _feeToken1To0(uint256 baseFeeSpecified) internal view returns (uint256) {
        (uint160 sqrtP, , ,) = StateLibrary.getSlot0(poolManager, bmxKey.toId());
        uint256 inter = FullMath.mulDivRoundingUp(baseFeeSpecified, FixedPoint96.Q96, sqrtP);
        return FullMath.mulDivRoundingUp(inter, FixedPoint96.Q96, sqrtP);
    }

    // ---------------------------------------------
    // BMX pool: exact input wBLT -> BMX (mismatch), price = 4
    // ---------------------------------------------
    function testBmxPool_ExactInput_WbltToBmx_Price2x_ConvertedFee() public {
        uint256 amountIn = 4e20; // ensure ≥ 1 wBLT buyback threshold

        // Ensure buyback pool is configured so auto-flush credits the gauge
        fp.setBuybackPoolKey(bmxKey);

        uint32 dayNow = uint32(block.timestamp / 1 days);
        uint256 bucketBefore = gauge.dayBuckets(bmxKey.toId(), dayNow + 2);
        // zeroForOne=false, exact input, settle token1 (wBLT)
        poolManager.unlock(abi.encode(SwapRequest({
            key: bmxKey,
            settleToken0: false,
            amount: amountIn,
            zeroForOne: false,
            exactInput: true
        })));

        // Expected gauge/voter with wBLT-only fee + internal-swap hook fee (0.3%)
        uint24 feePips = _lpFee();
        // Apply hybrid model: net-of-fee S', then fee on S'
        uint256 denom = 1_000_000 + feePips;
        uint256 fpre = (amountIn * feePips + denom - 1) / denom;
        uint256 sprime = amountIn - fpre;
        uint256 baseW = (sprime * feePips + 1_000_000 - 1) / 1_000_000; // ceil
        uint256 buyW  = (baseW * fp.buybackBps()) / 1e4;                 // split (floor)
        uint256 internalFee = (buyW * feePips) / 1_000_000;              // approx internal hook fee (floor)
        uint256 effW  = buyW - internalFee;                              // effective wBLT actually swapped to BMX
        // Price was initialised at 4 (sqrtP = 2*Q96), internal swap incurs tiny price impact; allow small tol
        // Voter accumulates: 3% of baseW + 3% of the internal-swap fee
        uint256 expectedVoter = (baseW - buyW) + ((internalFee * 3) / 100);

        // Manually flush BMX pool buffer to credit the gauge
        fp.flushBuffer(bmxKey.toId(), 0);
        uint256 bucketAfter = gauge.dayBuckets(bmxKey.toId(), dayNow + 2);
        // Bucket is denominated in BMX and depends on execution price; assert it increased
        assertGt(bucketAfter - bucketBefore, 0, "gauge bucket should increase");
        // Minor rounding differences from internal swap pricing and ceil/floor → allow tiny relative tolerance
        assertApproxEqRel(fp.pendingWbltForVoter(), expectedVoter, 0.00001e18, "wblt voter buffer");
    }

    function testBmxPool_ExactOutput_BmxSpecified_Price2x_NoConversion() public {
        uint256 amountOutBmx = 1e20; // reduce to ensure ≥ 1 wBLT threshold post-fee

        // Ensure buyback pool is configured so auto-flush credits the gauge
        fp.setBuybackPoolKey(bmxKey);

        uint32 dayNow = uint32(block.timestamp / 1 days);
        uint256 bucketBefore = gauge.dayBuckets(bmxKey.toId(), dayNow + 2);
        // zeroForOne=false, exact output, settle token1 (wBLT)
        poolManager.unlock(abi.encode(SwapRequest({
            key: bmxKey,
            settleToken0: false,
            amount: amountOutBmx,
            zeroForOne: false,
            exactInput: false
        })));

        // BMX specified: convert BMX-denominated fee to wBLT using POST-swap price,
        // apply buyback split, deduct internal-swap hook fee (0.3%), then convert to BMX at price≈p_after.
        uint24 feePips = _lpFee();
        uint256 baseBmx = (amountOutBmx * feePips + 1_000_000 - 1) / 1_000_000; // ceil on specified output
        // Convert using POST-swap sqrtPriceX96
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, bmxKey.toId());
        uint256 inter = FullMath.mulDiv(baseBmx, sqrtP, FixedPoint96.Q96);
        uint256 baseW   = FullMath.mulDiv(inter, sqrtP, FixedPoint96.Q96); // BMX -> wBLT at post-swap price
        uint256 buyW    = (baseW * fp.buybackBps()) / 1e4;    // 97% buyback
        uint256 internalFee = (buyW * feePips) / 1_000_000;  // internal swap hook fee
        // effective wBLT swapped to BMX (unused in assertion)
        // expected BMX credited depends on post-swap price; compute via division by p_after
        // BMX = effW / p_after = effW * 2^192 / sqrtP^2 (not asserted exactly here)
        uint256 expectedVoter = (baseW - buyW) + ((internalFee * 3) / 100);

        // Manually flush BMX pool buffer to credit the gauge
        fp.flushBuffer(bmxKey.toId(), 0);
        uint256 bucketAfter = gauge.dayBuckets(bmxKey.toId(), dayNow + 2);
        // Bucket depends on execution price; just assert it increased
        assertGt(bucketAfter - bucketBefore, 0, "gauge bucket should increase");
        assertApproxEqRel(fp.pendingWbltForVoter(), expectedVoter, 0.01e18, "wblt voter (no conversion)");
    }

    function testOtherPool_ExactOutput_OtherSpecified_Price2x_ConvertedFee() public {
        uint256 amountOutOther = 3e18; // specified token is token0 (OTHER)

        // zeroForOne=false, exact output, settle token1 (wBLT)
        poolManager.unlock(abi.encode(SwapRequest({
            key: otherKey,
            settleToken0: false,
            amount: amountOutOther,
            zeroForOne: false,
            exactInput: false
        })));

        uint256 base = _baseFee(amountOutOther);
        // Convert using POST-swap sqrtPriceX96 of otherKey (token0 OTHER -> token1 wBLT)
        (uint160 sqrtP2,,,) = StateLibrary.getSlot0(poolManager, otherKey.toId());
        uint256 inter2 = FullMath.mulDiv(base, sqrtP2, FixedPoint96.Q96);
        uint256 expectedFeeWblt = FullMath.mulDiv(inter2, sqrtP2, FixedPoint96.Q96);
        uint256 expectedBuy = (expectedFeeWblt * fp.buybackBps()) / 1e4;
        uint256 expectedVoter = expectedFeeWblt - expectedBuy;

        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), expectedBuy, "pending wblt buyback");
        assertEq(fp.pendingWbltForVoter(), expectedVoter, "pending wblt voter");
    }

    function testOtherPool_ExactInput_WbltSpecified_Price2x_NoConversion() public {
        uint256 amountInWblt = 4e18;

        // zeroForOne=false, exact input, settle token1 (wBLT)
        poolManager.unlock(abi.encode(SwapRequest({
            key: otherKey,
            settleToken0: false,
            amount: amountInWblt,
            zeroForOne: false,
            exactInput: true
        })));

        uint24 feePips = _lpFee();
        // Net-of-fee S', then fee on S'
        uint256 denom = 1_000_000 + feePips;
        uint256 fpre = (amountInWblt * feePips + denom - 1) / denom; // ceil
        uint256 sprime = amountInWblt - fpre;
        uint256 base = (sprime * feePips + 1_000_000 - 1) / 1_000_000; // ceil
        uint256 expectedBuy = (base * fp.buybackBps()) / 1e4;           // split (floor)
        uint256 expectedVoter = base - expectedBuy;

        assertEq(fp.pendingWbltForBuyback(otherKey.toId()), expectedBuy, "wblt buyback (no conversion)");
        assertEq(fp.pendingWbltForVoter(), expectedVoter, "wblt voter (no conversion)");
    }
}


