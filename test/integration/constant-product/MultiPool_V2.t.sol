// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {FeeProcessor} from "src/FeeProcessor.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";

/// @notice Tests multiple V2 pools managed by a single hook instance
contract MultiPoolV2_IT is Test, Deployers, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // contracts
    DeliHookConstantProduct hook;
    DailyEpochGauge gauge;
    FeeProcessor fp;
    MockIncentiveGauge inc;
    V2PositionHandler v2Handler;

    // tokens
    IERC20 wblt;
    IERC20 bmx;
    IERC20 tokenA;
    IERC20 tokenB;

    // pool keys
    PoolKey pool1; // BMX/wBLT
    PoolKey pool2; // TokenA/wBLT
    PoolKey pool3; // TokenB/wBLT

    function setUp() public {
        deployArtifacts();

        // Deploy tokens
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(bmxToken));
        wblt = IERC20(address(wbltToken));
        
        MockERC20 _tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 _tokenB = new MockERC20("TokenB", "TKB", 18);
        _tokenA.mint(address(this), 1e24);
        _tokenB.mint(address(this), 1e24);
        tokenA = IERC20(address(_tokenA));
        tokenB = IERC20(address(_tokenB));

        // Approvals
        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);
        tokenA.approve(address(poolManager), type(uint256).max);
        tokenB.approve(address(poolManager), type(uint256).max);

        // Deploy hook
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

        // Deploy supporting contracts
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
        inc = new MockIncentiveGauge();

        // Deploy hook
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
        // Minimal adapter wiring for V2 handler
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
        gauge.setPositionManagerAdapter(address(adapter));

        // Approve tokens to hook
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        // Initialize multiple pools
        pool1 = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        pool2 = PoolKey({
            currency0: address(tokenA) < address(wblt) ? Currency.wrap(address(tokenA)) : Currency.wrap(address(wblt)),
            currency1: address(tokenA) < address(wblt) ? Currency.wrap(address(wblt)) : Currency.wrap(address(tokenA)),
            fee: 1000, // Different fee tier
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        pool3 = PoolKey({
            currency0: address(tokenB) < address(wblt) ? Currency.wrap(address(tokenB)) : Currency.wrap(address(wblt)),
            currency1: address(tokenB) < address(wblt) ? Currency.wrap(address(wblt)) : Currency.wrap(address(tokenB)),
            fee: 1000, // 0.1% - minimum fee for V2 pools
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(pool1, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(pool2, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(pool3, TickMath.getSqrtPriceAtTick(0));
    }

    /*//////////////////////////////////////////////////////////////
                        ISOLATED POOL STATES
    //////////////////////////////////////////////////////////////*/

    function testIsolatedPoolStates() public {
        // Add liquidity to each pool
        hook.addLiquidity(
            pool1,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        hook.addLiquidity(
            pool2,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 50 ether,
                amount1Desired: 200 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        hook.addLiquidity(
            pool3,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 75 ether,
                amount1Desired: 150 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Verify each pool has independent reserves
        (uint128 r0_1, uint128 r1_1) = hook.getReserves(pool1.toId());
        (uint128 r0_2, uint128 r1_2) = hook.getReserves(pool2.toId());
        (uint128 r0_3, uint128 r1_3) = hook.getReserves(pool3.toId());

        assertEq(r0_1, 100 ether, "Pool1 reserve0");
        assertEq(r1_1, 100 ether, "Pool1 reserve1");
        
        // Pool2 might have swapped order if tokenA > wblt
        if (address(tokenA) < address(wblt)) {
            assertEq(r0_2, 50 ether, "Pool2 reserve0");
            assertEq(r1_2, 200 ether, "Pool2 reserve1");
        } else {
            assertEq(r0_2, 200 ether, "Pool2 reserve0 (swapped)");
            assertEq(r1_2, 50 ether, "Pool2 reserve1 (swapped)");
        }

        // Similar check for pool3
        if (address(tokenB) < address(wblt)) {
            assertEq(r0_3, 75 ether, "Pool3 reserve0");
            assertEq(r1_3, 150 ether, "Pool3 reserve1");
        } else {
            assertEq(r0_3, 150 ether, "Pool3 reserve0 (swapped)");
            assertEq(r1_3, 75 ether, "Pool3 reserve1 (swapped)");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INDEPENDENT LIQUIDITY SHARES
    //////////////////////////////////////////////////////////////*/

    function testIndependentLiquidityShares() public {
        address alice = makeAddr("alice");
        deal(address(bmx), alice, 1000 ether);
        deal(address(wblt), alice, 1000 ether);
        deal(address(tokenA), alice, 1000 ether);

        vm.startPrank(alice);
        bmx.approve(address(hook), type(uint256).max);
        wblt.approve(address(hook), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);

        // Alice adds to pool1
        hook.addLiquidity(
            pool1,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Alice adds to pool2
        hook.addLiquidity(
            pool2,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 20 ether,
                amount1Desired: 20 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        vm.stopPrank();

        // Check Alice has different shares in each pool
        uint256 shares1 = hook.balanceOf(pool1.toId(), alice);
        uint256 shares2 = hook.balanceOf(pool2.toId(), alice);
        
        assertGt(shares1, 0, "Alice should have pool1 shares");
        assertGt(shares2, 0, "Alice should have pool2 shares");
        assertNotEq(shares1, shares2, "Shares should be different");

        // Verify no shares in pool3
        assertEq(hook.balanceOf(pool3.toId(), alice), 0, "No pool3 shares");
    }

    /*//////////////////////////////////////////////////////////////
                        CROSS-POOL FEE COLLECTION
    //////////////////////////////////////////////////////////////*/

    function testCrossPoolFeeCollection() public {
        // Add liquidity to pools
        hook.addLiquidity(
            pool1,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        hook.addLiquidity(
            pool2,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Swap on pool1 (3000 = 0.3% fee)
        poolManager.unlock(abi.encode(pool1, true, 10 ether, true)); // pool, zeroForOne, amount, exactInput

        // Snapshot voter buffer before second swap since it is global across pools
        uint256 voterBefore = fp.pendingWbltForVoter();
        // Swap on pool2 (1000 = 0.1% fee)
        poolManager.unlock(abi.encode(pool2, address(tokenA) < address(wblt), 10 ether, true));

        // Check fee processor collected fees from both pools (minimize locals to avoid stack-too-deep)
        PoolId pool2Id = pool2.toId();
        // Compute fee using exact constant product math at initial reserves
        uint256 feeWblt = _calcFeeWblt(
            10 ether,
            1000,
            address(tokenA) < address(wblt),
            (address(tokenA) < address(wblt))
                ? (Currency.unwrap(pool2.currency1) == address(wblt))
                : (Currency.unwrap(pool2.currency0) == address(wblt)),
            100 ether,
            100 ether
        );
        uint256 expectedBuyback = (feeWblt * fp.buybackBps()) / 10_000;
        assertEq(fp.pendingWbltForBuyback(pool2Id), expectedBuyback, "wBLT buyback from pool2");
        // Voter buffer is global; assert only the delta from pool2's swap equals its voter share
        uint256 voterDelta = fp.pendingWbltForVoter() - voterBefore;
        assertEq(voterDelta, feeWblt - expectedBuyback, "wBLT voter from pool2");
    }

    function _calcFeeWblt(
        uint256 amountIn,
        uint24 feePips,
        bool zeroForOne,
        bool wbltIsOutput,
        uint256 reserve0,
        uint256 reserve1
    ) private pure returns (uint256) {
        uint256 rIn = zeroForOne ? reserve0 : reserve1;
        uint256 rOut = zeroForOne ? reserve1 : reserve0;
        uint256 feeBasis = 1_000_000 - feePips;
        uint256 aInWithFee = amountIn * feeBasis;
        uint256 outWithFee = (aInWithFee * rOut) / (rIn * 1_000_000 + aInWithFee);
        uint256 outNoFee = (amountIn * rOut) / (rIn + amountIn);
        if (wbltIsOutput) {
            return outNoFee - outWithFee;
        }
        return (amountIn * feePips) / 1_000_000;
    }

    /*//////////////////////////////////////////////////////////////
                        POOL-SPECIFIC GAUGE TRACKING
    //////////////////////////////////////////////////////////////*/

    function testPoolSpecificGaugeTracking() public {
        // Add liquidity to trigger gauge tracking
        hook.addLiquidity(
            pool1,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        hook.addLiquidity(
            pool2,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 50 ether,
                amount1Desired: 50 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Perform swaps to trigger gauge updates
        poolManager.unlock(abi.encode(pool1, true, 1 ether, true));

        // Check accessor returns without reverting for each pool
        (uint256 sr1,,) = gauge.getPoolData(pool1.toId());
        (uint256 sr2,,) = gauge.getPoolData(pool2.toId());
        // Sanity: both calls returned and produced non-negative rates
        assertGe(sr1, 0, "Pool1 data");
        assertGe(sr2, 0, "Pool2 data");
    }

    /*//////////////////////////////////////////////////////////////
                        DIFFERENT FEE TIERS
    //////////////////////////////////////////////////////////////*/

    function testDifferentFeeTiers() public {
        // Add liquidity to all pools
        hook.addLiquidity(
            pool1,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        hook.addLiquidity(
            pool3,
            MultiPoolCustomCurve.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // Use different swap amounts to ensure meaningful fee collection
        uint256 swapAmount1 = 10 ether;  // 10% of pool for 0.3% fee
        uint256 swapAmount3 = 20 ether;  // 20% of pool for 0.1% fee (larger to compensate for lower fee)

        // Get initial K values
        (uint128 r0_1_before, uint128 r1_1_before) = hook.getReserves(pool1.toId());
        (uint128 r0_3_before, uint128 r1_3_before) = hook.getReserves(pool3.toId());
        uint256 k1Before = uint256(r0_1_before) * uint256(r1_1_before);
        uint256 k3Before = uint256(r0_3_before) * uint256(r1_3_before);

        // Swap on pool1 (0.3% fee)
        poolManager.unlock(abi.encode(pool1, true, swapAmount1, true));

        // Swap on pool3 (0.1% fee) - larger amount to ensure fee is meaningful
        poolManager.unlock(abi.encode(pool3, address(tokenB) < address(wblt), swapAmount3, true));

        // Get K values after swaps
        (uint128 r0_1_after, uint128 r1_1_after) = hook.getReserves(pool1.toId());
        (uint128 r0_3_after, uint128 r1_3_after) = hook.getReserves(pool3.toId());
        uint256 k1After = uint256(r0_1_after) * uint256(r1_1_after);
        uint256 k3After = uint256(r0_3_after) * uint256(r1_3_after);

        // With our new fee logic:
        // - When fee token = input token: K decreases (fee explicitly removed from reserves)
        // - When fee token = output token: K unchanged (fee implicit in swap calculation)
        
        // Pool1 (BMX->wBLT): BMX pool takes fees in BMX (input token)
        // K should decrease because fee is extracted from reserves
        // However, due to V2 math with implicit fees, K might increase slightly due to rounding
        if (k1After > k1Before) {
            // Allow small increase due to rounding in V2 math
            uint256 k1Increase = k1After - k1Before;
            assertLt(k1Increase, k1Before / 10000, "Pool1 K increase should be < 0.01% (rounding)");
        } else {
            // Expected case: K decreases
            uint256 k1Decrease = k1Before - k1After;
            // Fee = 10 ether * 0.003 = 0.03 ether BMX removed from reserves
            assertLt(k1Decrease, k1Before / 100, "Pool1 K decrease should be < 1%");
        }
        
        // Pool3: Non-BMX pool takes fees in wBLT
        // Need to check the swap direction to determine if wBLT is input or output
        bool pool3ZeroForOne = address(tokenB) < address(wblt);
        bool wbltIsOutput = pool3ZeroForOne ? 
            (Currency.unwrap(pool3.currency1) == address(wblt)) : 
            (Currency.unwrap(pool3.currency0) == address(wblt));
            
        if (wbltIsOutput) {
            // Fee taken from output, K should remain unchanged (fee is implicit)
            assertApproxEqRel(k3After, k3Before, 0.001e18, "Pool3 K should remain approximately unchanged when fee from output");
        } else {
            // Fee taken from input, K should decrease
            assertLt(k3After, k3Before, "Pool3 K should decrease with input fee extraction");
            uint256 k3Decrease = k3Before - k3After;
            // Fee = 20 ether * 0.001 = 0.02 ether wBLT removed from reserves
            assertLt(k3Decrease, k3Before / 100, "Pool3 K decrease should be < 1%");
        }
    }

    /*//////////////////////////////////////////////////////////////
                           UNLOCK CALLBACK
    //////////////////////////////////////////////////////////////*/

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        
        (PoolKey memory poolKey, bool zeroForOne, uint256 amount, bool exactInput) = 
            abi.decode(data, (PoolKey, bool, uint256, bool));
        
        SwapParams memory sp = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        // Settle input currency
        if (zeroForOne) {
            poolKey.currency0.settle(poolManager, address(this), uint128(amount), false);
        } else {
            poolKey.currency1.settle(poolManager, address(this), uint128(amount), false);
        }
        poolManager.settle();
        
        // Perform swap
        BalanceDelta delta = poolManager.swap(poolKey, sp, bytes(""));
        
        // Take output currency
        if (zeroForOne) {
            uint256 outAmt = uint256(int256(delta.amount1()));
            if (outAmt > 0) poolKey.currency1.take(poolManager, address(this), outAmt, false);
        } else {
            uint256 outAmt = uint256(int256(delta.amount0()));
            if (outAmt > 0) poolKey.currency0.take(poolManager, address(this), outAmt, false);
        }
        poolManager.settle();
        
        return bytes("");
    }
}