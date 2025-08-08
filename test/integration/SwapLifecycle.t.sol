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
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";

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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Token is ERC20 { constructor(string memory s) ERC20(s,s) { _mint(msg.sender,1e24);} }

contract SwapLifecycle_IT is Test, Deployers, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    // Note: poolManager and positionManager are inherited from Deployers
    FeeProcessor fp;
    DailyEpochGauge gauge;
    DeliHook hook;
    MockIncentiveGauge inc;

    // tokens
    Token wblt;
    Token bmx;
    Token other;

    address constant VOTER_DST = address(0xCAFEBABE);

    function setUp() public {
        /***************************************************
         * 1. Spin up canonical Uniswap-v4 test stack      *
         ***************************************************/
        deployArtifacts(); // initialise poolManager & positionManager inherited vars

        /***************************************************
         * 2. Deploy tokens with built-in approvals        *
         ***************************************************/
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        MockERC20 bmxToken;
        MockERC20 wbltToken;
        if (address(t0) < address(t1)) {
            bmxToken = t0;
            wbltToken = t1;
        } else {
            bmxToken = t1;
            wbltToken = t0;
        }

        bmx = Token(address(bmxToken));
        wblt = Token(address(wbltToken));

        // Approve PoolManager to pull tokens for swaps
        IERC20(address(bmx)).approve(address(poolManager), type(uint256).max);
        IERC20(address(wblt)).approve(address(poolManager), type(uint256).max);

        // other token will be created below

        // deploy an extra token for the secondary pool (OTHER/wBLT)
        other = new Token("OTHER");
        IERC20(address(other)).approve(address(poolManager), type(uint256).max);
        IERC20(address(other)).approve(address(permit2), type(uint256).max);
        IERC20(address(other)).approve(address(swapRouter), type(uint256).max);

        // Permit2 approvals required for PositionManager & PoolManager (same as deployToken helper)
        permit2.approve(address(other), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(other), address(poolManager), type(uint160).max, type(uint48).max);

        // SECOND POOL KEY (OTHER / wBLT)
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(other)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)) // will be valid after hook deployed
        });

        /***************************************************
         * 3. Provide minimal liquidity so swaps succeed   *
         ***************************************************/
        PoolKey memory initKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)) // temp placeholder; will set later
        });

        // poolManager.initialize requires valid hooks address; we will set after hook deployment.

        // 4. Precompute a valid hook address (with placeholder feeProcessor & gauge = 0) satisfying hook flag constraints
        bytes memory tmpCtorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)), // placeholder
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), hookFlags, type(DeliHook).creationCode, tmpCtorArgs);

        // 3. Deploy gauge now that we know the hook address (deliHook param)
        gauge = new DailyEpochGauge(address(0), poolManager, IPositionManagerAdapter(address(0)), predictedHook, IERC20(address(bmx)), address(0));
        inc = new MockIncentiveGauge();

        // ------------------------------------------------------------------

        // 4. Deploy FeeProcessor with deliHook set to that predicted hook address
        fp = new FeeProcessor(poolManager, predictedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), VOTER_DST);

        // 5. Deploy the hook at the predicted address using the same constructor args (placeholder feeProcessor)
        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)), // will set afterwards
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );

        // Sanity check: ensure address matches prediction
        require(address(hook) == predictedHook, "Hook addr mismatch");

        // 6. Point the hook to the actual FeeProcessor instance
        hook.setFeeProcessor(address(fp));

        // Now point hook to the actual DailyEpochGauge
        hook.setDailyEpochGauge(address(gauge));

        // 7. Update gauge with the correct fee processor address
        gauge.setFeeProcessor(address(fp));

        // 7b. Set a dummy incentive gauge so the hook's beforeInitialize check passes
        hook.setIncentiveGauge(address(inc));

        // 8. Initialise the pool now that hook address is final
        initKey.hooks = IHooks(address(hook));
        poolManager.initialize(initKey, TickMath.getSqrtPriceAtTick(0));

        // 9. Add a small liquidity position so the pool owns tokens
        EasyPosm.mint(
            positionManager,
            initKey,
            -60000,
            60000,
            1e21,
            1e24,
            1e24,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );

        // initialize second pool after hook set
        otherKey.hooks = IHooks(address(hook));
        poolManager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));

        // add liquidity to second pool
        EasyPosm.mint(
            positionManager,
            otherKey,
            -60000,
            60000,
            1e21,
            1e24,
            1e24,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );

    }

    // PoolManager will callback here while unlocked; perform the swap via hook
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        (address tokenIn, uint256 amountIn) = abi.decode(data, (address,uint256));

        PoolKey memory key;
        SwapParams memory sp;

        if (tokenIn == address(bmx)) {
            // -------------------------------
            //  BMX (token0) -> wBLT (token1)
            // -------------------------------
            key = PoolKey({
                currency0: Currency.wrap(address(bmx)),
                currency1: Currency.wrap(address(wblt)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });

            // settle input BMX into PoolManager
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();

            sp = SwapParams({
                zeroForOne: true, // token0 -> token1
                amountSpecified: -int256(amountIn), // exactInput BMX
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        } else if (tokenIn == address(other)) {
            // -------------------------------
            //  OTHER (token0) -> wBLT (token1)
            // -------------------------------
            key = PoolKey({
                currency0: Currency.wrap(address(other)),
                currency1: Currency.wrap(address(wblt)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });

            // settle input OTHER
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();

            sp = SwapParams({
                zeroForOne: true,  // token0 -> token1
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        } else {
            revert("unknown token");
        }

        // Execute the swap and retrieve output so PoolManager balances net to zero
        BalanceDelta delta = poolManager.swap(key, sp, bytes(""));

        if (sp.zeroForOne) {
            uint256 outAmt = uint256(int256(delta.amount1()));
            if (outAmt > 0) {
                key.currency1.take(poolManager, address(this), outAmt, false);
            }
        } else {
            uint256 outAmt = uint256(int256(delta.amount0()));
            if (outAmt > 0) {
                key.currency0.take(poolManager, address(this), outAmt, false);
            }
        }

        // Final settle clears any residual native-currency delta left in PoolManager.
        poolManager.settle();
        return bytes("");
    }

    function testFullLifecycle() public {
        uint256 feeInput = 1e17; // amount for swaps

        // 1) Swap in OTHER/wBLT pool via unlock pattern so manager isn't locked
        poolManager.unlock(abi.encode(address(other), feeInput));

        // 2) Swap in BMX pool via unlock pattern (buy-back)
        poolManager.unlock(abi.encode(address(bmx), feeInput));

        uint256 feeAmt = feeInput * 3000 / 1e6; // 0.3 %
        uint256 expectedBuy = feeAmt * fp.buybackBps() / 1e4;
        uint256 expectedBuyTotal = expectedBuy; // only BMX pool credited immediately
        PoolId pid = PoolId.wrap(bytes25(uint200(0))); // convert key later
        pid = (PoolKey({currency0:Currency.wrap(address(bmx)),currency1:Currency.wrap(address(wblt)),fee:3000,tickSpacing:60,hooks:IHooks(address(hook))})).toId();
        // Verify 97% buy-back bucket registered (credited to day+2 bucket)
        uint32 dayNow = uint32(block.timestamp / 1 days);
        assertEq(gauge.dayBuckets(pid, dayNow + 2), expectedBuyTotal);

        // Voter portion (3%) is kept in FeeProcessor buffers until a flush.
        uint256 voterShare = feeAmt - expectedBuy;
        assertEq(fp.pendingBmxForVoter(), voterShare);

        // keeperless: derive day boundary; streamRate should be zero until activation day (N+2)
        uint256 end0 = TimeLibrary.dayNext(block.timestamp);
        assertEq(gauge.streamRate(pid), 0, "stream should start on Day2");

        // warp to Day2 activation
        vm.warp(uint256(end0) + 1 days);
        // derived model: rate is bucket/86400
        assertEq(gauge.streamRate(pid), expectedBuy / 1 days);
    }

    function testInternalSwapFeeCollection() public {
        // Configure buyback pool first
        PoolKey memory bmxKey = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        fp.setBuybackPoolKey(bmxKey);
        PoolId pid = bmxKey.toId();
        
        // Check gauge balance before
        uint32 dayNow2 = uint32(block.timestamp / 1 days);
        uint256 gaugeBefore = gauge.dayBuckets(pid, dayNow2 + 2);
        
        // 1) Generate wBLT fees in OTHER pool
        // With buyback pool configured, this will trigger automatic flush
        uint256 otherSwapAmount = 1e18;
        poolManager.unlock(abi.encode(address(other), otherSwapAmount));
        
        // Check that automatic flush happened
        uint256 wbltBuybackAfter = fp.pendingWbltForBuyback();
        uint256 wbltVoterAfter = fp.pendingWbltForVoter();
        
        // The buyback buffer should be empty (was flushed)
        assertEq(wbltBuybackAfter, 0, "wBLT buyback should be empty after flush");
        
        // The voter wBLT buffer still has the 3% portion (9e13)
        // This is NOT automatically sent, just accumulated for manual distribution
        assertEq(wbltVoterAfter, 90000000000000, "wBLT voter should have 3% of original fee");
        
        // Verify gauge received BMX from automatic buyback
        uint256 gaugeAfter = gauge.dayBuckets(pid, dayNow2 + 2);
        assertGt(gaugeAfter, gaugeBefore, "gauge should receive BMX from auto buyback");
        
        // The internal swaps generated their own fees
        // Check that there's a small residual from the internal swaps
        uint256 bmxVoterResidual = fp.pendingBmxForVoter();
        assertGt(bmxVoterResidual, 0, "should have residual BMX from internal swaps");
        
        // 2) Generate BMX fees to test BMX->wBLT automatic flush
        uint256 bmxSwapAmount = 2e18;
        poolManager.unlock(abi.encode(address(bmx), bmxSwapAmount));
        
        // The swap should have triggered automatic flush of BMX voter buffer
        // But there will be residual from the internal BMX->wBLT swap
        uint256 bmxVoterAfterSecondSwap = fp.pendingBmxForVoter();
        assertGt(bmxVoterAfterSecondSwap, 0, "should have residual from internal swap");
        
        // The residual should be much smaller than the original fee
        // (it's 3% of 0.3% = 0.009% of the swap amount)
        assertLt(bmxVoterAfterSecondSwap, bmxSwapAmount * 3000 / 1e6 / 100, "residual should be small");
        
        // The automatic flush demonstrates that internal swaps:
        // 1. Execute automatically when buffers have funds
        // 2. Generate their own fees that are collected
        // 3. Don't cause recursion (residuals don't trigger more flushes)
    }
} 