// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BufferFlushAndPull_IT is Test, Deployers, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

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
            address(bmx)
        );
        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), hookFlags, type(DeliHook).creationCode, tmpCtorArgs);

        gauge = new DailyEpochGauge(address(0), poolManager, IPositionManager(address(0)), predictedHook, IERC20(address(bmx)), address(0));
        fp = new FeeProcessor(poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), VOTER_DST);

        // Deploy mock incentive gauge so DeliHook.afterSwap can call pokePool without reverting
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
        // Wire real mock incentive gauge
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // Allow hook to pull wBLT fees from this contract during _pullFromSender path
        wblt.approve(address(hook), type(uint256).max);

        /***************************************************
         * 4. Pools + bootstrap liquidity                  *
         ***************************************************/
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
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _feeAmt(uint256 amtIn) internal pure returns (uint256) {
        return (amtIn * 3000) / 1e6; // 0.3 %
    }

    /*//////////////////////////////////////////////////////////////
                      pull-from-sender path
    //////////////////////////////////////////////////////////////*/

    function testPullFromSender() public {
        uint256 input = 1e17;
        uint256 balBefore = wblt.balanceOf(address(this));

        // Swap wBLT (token1) -> OTHER (token0) to trigger _pullFromSender.
        poolManager.unlock(abi.encode(address(wblt), input));

        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4;
        uint256 voterPortion = feeAmt - buybackPortion;

        // FeeProcessor buffers updated
        assertEq(fp.pendingWbltForBuyback(), buybackPortion, "buyback buf");
        assertEq(fp.pendingWbltForVoter(),   voterPortion,   "voter buf");

        // Sender paid fee (input + fee)
        uint256 balAfter = wblt.balanceOf(address(this));
        assertEq(balBefore - balAfter, input + feeAmt, "fee pull mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                     buffer flush + buy-back
    //////////////////////////////////////////////////////////////*/

    function testBufferFlush() public {
        uint256 input = 1e17;

        // 1. Generate wBLT buy-back buffer via OTHER -> wBLT swap
        poolManager.unlock(abi.encode(address(other), input));

        // 2. Generate BMX voter buffer via canonical pool swap
        poolManager.unlock(abi.encode(address(bmx), input));

        // sanity: buffers populated
        assertGt(fp.pendingWbltForBuyback(), 0, "no wblt buffer");
        assertGt(fp.pendingBmxForVoter(),    0, "no bmx buffer");

        // 3. Configure buy-back pool
        fp.setBuybackPoolKey(canonicalKey);

        uint256 bucketBefore = gauge.collectBucket(canonicalKey.toId());
        uint256 voterBalBefore = wblt.balanceOf(VOTER_DST);

        // 4. Flush – executes two internal swaps synchronously
        fp.flushBuffers();

        // Buffers cleared
        assertEq(fp.pendingWbltForBuyback(), 0, "buyback not cleared");
        assertEq(fp.pendingBmxForVoter(),    0, "voter not cleared");

        // Gauge bucket increased (received BMX from buy-back)
        uint256 bucketAfter = gauge.collectBucket(canonicalKey.toId());
        assertGt(bucketAfter, bucketBefore, "bucket not updated");

        // Voter destination received wBLT
        uint256 voterBalAfter = wblt.balanceOf(VOTER_DST);
        assertGt(voterBalAfter, voterBalBefore, "voter wblt missing");
    }

    /*//////////////////////////////////////////////////////////////
                wBLT -> BMX on canonical pool
    //////////////////////////////////////////////////////////////*/

    function testWbltToBmxCanonical() public {
        uint256 input = 1e17;

        // Perform wBLT (token1) -> BMX (token0) on canonical pool
        poolManager.unlock(abi.encode(address(wblt), input, true)); // true => use canonical

        uint256 feeAmt = _feeAmt(input);
        uint256 buybackPortion = (feeAmt * fp.buybackBps()) / 1e4; // 97% in BMX
        uint256 voterPortion   = feeAmt - buybackPortion;          // 3% in BMX (voter buffer)

        // Immediately credited to gauge bucket (since fee is already BMX)
        uint256 bucket = gauge.collectBucket(canonicalKey.toId());
        assertEq(bucket, buybackPortion, "bucket credit");

        // Voter buffer (BMX)
        assertEq(fp.pendingBmxForVoter(), voterPortion, "bmx voter buf");
    }

    /*//////////////////////////////////////////////////////////////
                flush with only wBLT buy-back buffer
    //////////////////////////////////////////////////////////////*/

    function testFlushSingleBuyback() public {
        uint256 input = 1e17;

        // Populate ONLY the wBLT buy-back buffer (OTHER pool swap)
        poolManager.unlock(abi.encode(address(other), input));

        uint256 buf = fp.pendingWbltForBuyback();
        assertGt(buf, 0, "no buf");

        fp.setBuybackPoolKey(canonicalKey);

        fp.flushBuffers();

        // Buy-back buffer cleared, voter buffers untouched (should be zero)
        assertEq(fp.pendingWbltForBuyback(), 0, "buyback not cleared");
        assertEq(fp.pendingBmxForVoter(),    0, "voter bmx unexpected");

        // Gauge bucket received BMX > 0
        assertGt(gauge.collectBucket(canonicalKey.toId()), 0, "bucket empty");
    }

    /*//////////////////////////////////////////////////////////////
                slippage revert keeps buffers intact
    //////////////////////////////////////////////////////////////*/

    function testSlippageFailure() public {
        uint256 input = 1e17;

        // Produce wBLT buy-back buffer
        poolManager.unlock(abi.encode(address(other), input));

        uint256 pending = fp.pendingWbltForBuyback();
        assertGt(pending, 0, "buf");

        fp.setBuybackPoolKey(canonicalKey);

        // Tighten slippage to 100% (will fail because swap outputs < quote due to fee)
        fp.setMinOutBps(10000);

        // flush is expected to revert with "slippage"
        vm.expectRevert(DeliErrors.Slippage.selector);
        fp.flushBuffers();

        // Buffer should remain since swap failed
        assertEq(fp.pendingWbltForBuyback(), pending, "buf lost");
    }

    /*//////////////////////////////////////////////////////////////
              governance claimVoterFees transfers wBLT
    //////////////////////////////////////////////////////////////*/

    function testClaimVoterFees() public {
        uint256 input = 2e17;

        // Perform OTHER -> wBLT swap to accrue voter wBLT buffer
        poolManager.unlock(abi.encode(address(other), input));

        uint256 feeAmt = _feeAmt(input);
        uint256 voterPortion = feeAmt - (feeAmt * fp.buybackBps()) / 1e4; // 3 % of fee

        // Ensure voter buffer matches expectation
        assertEq(fp.pendingWbltForVoter(), voterPortion, "voter buf mismatch");

        uint256 preBal = wblt.balanceOf(VOTER_DST);

        // Owner (this contract) claims voter fees
        fp.claimVoterFees(VOTER_DST);

        uint256 postBal = wblt.balanceOf(VOTER_DST);
        assertEq(postBal - preBal, voterPortion, "voter did not receive tokens");
        assertEq(fp.pendingWbltForVoter(), 0, "buffer not cleared");
    }

    /*//////////////////////////////////////////////////////////////
                 tight slippage success flush
    //////////////////////////////////////////////////////////////*/
    function testSlippageTightSuccess() public {
        uint256 input = 1e17;

        // Produce wBLT buy-back buffer via OTHER -> wBLT swap (token0 -> token1)
        poolManager.unlock(abi.encode(address(other), input));

        // Ensure buffer populated
        uint256 buf = fp.pendingWbltForBuyback();
        assertGt(buf, 0, "no pending buffer");

        // Configure buy-back pool and tighten slippage tolerance to 0.5%
        fp.setBuybackPoolKey(canonicalKey);
        fp.setMinOutBps(9950); // allow only 0.5% slippage

        uint256 bucketBefore = gauge.collectBucket(canonicalKey.toId());

        // Should execute without reverting
        fp.flushBuffers();

        // Buffer cleared and gauge bucket credited
        assertEq(fp.pendingWbltForBuyback(), 0, "buffer not cleared");
        uint256 bucketAfter = gauge.collectBucket(canonicalKey.toId());
        assertGt(bucketAfter, bucketBefore, "bucket not increased");
    }
} 