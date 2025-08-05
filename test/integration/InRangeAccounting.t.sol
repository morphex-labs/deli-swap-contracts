// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
using EasyPosm for IPositionManager;
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "src/DeliHook.sol";
import "src/DailyEpochGauge.sol";
import "src/IncentiveGauge.sol";
import "src/PositionManagerAdapter.sol";
import "src/handlers/V4PositionHandler.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

using CurrencySettler for Currency;

contract InRangeAccounting_IT is Test, Deployers, IUnlockCallback, IFeeProcessor {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // contracts
    DeliHook hook;
    DailyEpochGauge gauge;
    PositionManagerAdapter adapter;
    V4PositionHandler v4Handler;
    IncentiveGauge inc;

    // tokens
    IERC20 wblt;
    IERC20 bmx;

    // helpers
    PoolKey key;
    PoolId pid;

    uint256 tokenWide;
    uint256 tokenNarrow;

    function setUp() public {
        // 1. Deploy core artifacts (PoolManager, PositionManager, etc.)
        deployArtifacts();

        // 2. Deploy two ERC20 tokens
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 _bmx, MockERC20 _wblt) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(_bmx));
        wblt = IERC20(address(_wblt));

        // approve tokens for liquidity ops
        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);

        // 3. Pre-compute hook address so gauge constructor can reference it
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);

        // 4. Deploy gauge (no feeProcessor required for this test)
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), predictedHook);
        gauge = new DailyEpochGauge(address(0), poolManager, IPositionManagerAdapter(address(0)), predictedHook, bmx, address(inc));

        // 5. Deploy PositionManagerAdapter and V4PositionHandler
        adapter = new PositionManagerAdapter(address(gauge), address(inc));
        v4Handler = new V4PositionHandler(address(positionManager));
        
        // Register V4 handler and wire up the adapter
        adapter.addHandler(address(v4Handler));
        adapter.setAuthorizedCaller(address(positionManager), true);
        adapter.setPositionManager(address(positionManager));

        // 6. Deploy hook
        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );
        hook.setDailyEpochGauge(address(gauge));
        hook.setFeeProcessor(address(this)); // prevent zero-address take
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(this)); // dummy authorised sender for addRewards

        // Update gauges to use the adapter
        gauge.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));
        
        // 7. Initialise pool
        key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // 7. Mint wide-range position (always in-range)
        (tokenWide,) = EasyPosm.mint(
            positionManager,
            key,
            -60000,
            60000,
            1e22,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenWide, address(adapter), bytes(""));

        // 8. Mint narrow-range position initially in-range (-600 to 600)
        (tokenNarrow,) = EasyPosm.mint(
            positionManager,
            key,
            -600,
            600,
            1e22,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenNarrow, address(adapter), bytes(""));

        // 9. Fund gauge bucket and activate streaming
        uint256 bucket = 1000 ether;
        bmx.transfer(address(gauge), bucket);
        vm.prank(address(this));
        gauge.addRewards(pid, bucket);

        // Roll Day0 epoch so queuedRate set
        gauge.rollIfNeeded(pid);
        (, uint64 day0End,,, ) = gauge.epochInfo(pid);
        // Warp two days to activate streamRate
        vm.warp(uint256(day0End) + 2 days);
        gauge.rollIfNeeded(pid);
        require(gauge.streamRate(pid) > 0, "stream inactive");
    }

    /*//////////////////////////////////////////////////////////////
                        TEST LOGIC
    //////////////////////////////////////////////////////////////*/
    function testInRangeOutOfRangeAccrual() public {
        // Record liquidity and position keys
        uint128 liqWide = positionManager.getPositionLiquidity(tokenWide);
        uint128 liqNarrow = positionManager.getPositionLiquidity(tokenNarrow);

        bytes32 posWide = keccak256(abi.encode(address(this), int24(-60000), int24(60000), bytes32(tokenWide), pid));
        bytes32 posNarrow = keccak256(abi.encode(address(this), int24(-600), int24(600), bytes32(tokenNarrow), pid));

        // Advance 3 hours and poke so rewards accrue while both in-range
        vm.warp(block.timestamp + 3 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        uint256 preWide = gauge.pendingRewards(posWide, liqWide, pid);
        uint256 preNarrow = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertGt(preNarrow, 0, "narrow should have accrued initially");

        // ------------------------------------------------------------
        // Move price ABOVE narrow upper tick so narrow goes out-of-range
        // Perform large wBLT -> BMX swap (token1 -> token0) via unlock pattern to push price ABOVE narrow range
        uint256 swapIn = 5e22;
        poolManager.unlock(abi.encode(address(wblt), swapIn));

        // Verify pool price is now above narrow range (tick > 600)
        (uint160 sqrtPriceAfter,,,) = StateLibrary.getSlot0(poolManager, pid);
        int24 currTick = TickMath.getTickAtSqrtPrice(sqrtPriceAfter);
        require(currTick > 600, "price not moved above narrow");

        // ------------------------------------------------------------
        // Advance another 3 hours and poke
        vm.warp(block.timestamp + 3 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        uint256 postWide = gauge.pendingRewards(posWide, liqWide, pid);
        uint256 postNarrow = gauge.pendingRewards(posNarrow, liqNarrow, pid);

        // Wide should have accrued additional rewards
        assertGt(postWide - preWide, 0, "wide did not accrue after move");
        // Narrow should accrue negligible (<=1) additional rewards since it is out-of-range
        assertLe(postNarrow - preNarrow, 1e12, "narrow accrued despite out-of-range");
    }

    // Leave range (price above upper) then re-enter; accrual pauses & resumes
    function testLeaveAndReEnterRange() public {
        uint128 liqNarrow = positionManager.getPositionLiquidity(tokenNarrow);
        bytes32 posNarrow = keccak256(abi.encode(address(this), int24(-600), int24(600), bytes32(tokenNarrow), pid));

        // 1. accrue 1h while in-range
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 inRange1 = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertGt(inRange1, 0, "no accrual initial");

        // 2. push price ABOVE tickUpper so narrow is out-of-range
        uint256 swapIn = 1e23;
        poolManager.unlock(abi.encode(address(wblt), swapIn)); // large wBLT -> BMX
        (, int24 tickNow,,) = StateLibrary.getSlot0(poolManager, pid);
        require(tickNow > 600, "price not above upper");

        // wait 2h & poke – accrual should stall
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 outOfRange = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertApproxEqAbs(outOfRange, inRange1, 1e12, "accrued while out-of-range");

        // 3. Bring the price back *into* the narrow range using adaptive swaps.
        int24 lower = -600;
        int24 upper =  600;

        uint256 chunk = swapIn / 4;          // start with 25% of the initial push
        uint8   steps = 0;
        while (true) {
            (, int24 t,,) = StateLibrary.getSlot0(poolManager, pid);
            if (t >= lower && t <= upper) break; // inside range → done

            // Decide swap direction: if price is above range, swap BMX→wBLT (drives price down).
            // If below range, swap wBLT→BMX (drives price up).
            address tokenIn = (t > upper) ? address(bmx) : address(wblt);
            poolManager.unlock(abi.encode(tokenIn, chunk));

            // Reduce chunk size each iteration for finer adjustment.
            chunk /= 2;
            if (chunk == 0) chunk = 1e18;    // minimum 1 ether granularity
            require(++steps < 12, "price_adjust_loop");
        }

        // wait 1h & poke – accrual should resume now that the position is in-range again
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 backInRange = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertGt(backInRange - outOfRange, 0, "accrual did not resume");
    }

    // Price below tickLower path – symmetry check
    function testPriceBelowLowerStopsAccrual() public {
        uint128 liqNarrow = positionManager.getPositionLiquidity(tokenNarrow);
        bytes32 posNarrow = keccak256(abi.encode(address(this), int24(-600), int24(600), bytes32(tokenNarrow), pid));

        // push price BELOW lower boundary
        poolManager.unlock(abi.encode(address(bmx), 1e23)); // BMX -> wBLT drives price down
        (, int24 tickNow,,) = StateLibrary.getSlot0(poolManager, pid);
        require(tickNow < -600, "price not below lower");

        // poke after 2h & assert no accrual progress
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 pending = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        // advance another 2h while still out-of-range
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 pending2 = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertApproxEqAbs(pending, pending2, 1e12, "accrual while below range");
    }

    // Day-roll while out-of-range – ensure no accrual
    function testDayRollWhileOutOfRange() public {
        uint128 liqNarrow = positionManager.getPositionLiquidity(tokenNarrow);
        bytes32 posNarrow = keccak256(abi.encode(address(this), int24(-600), int24(600), bytes32(tokenNarrow), pid));

        // Move above range
        poolManager.unlock(abi.encode(address(wblt), 1e23));
        (, int24 tickNow,,) = StateLibrary.getSlot0(poolManager, pid);
        require(tickNow > 600, "price not above");

        // warp to epoch end + 1 and roll gauge
        (, uint64 epochEnd,,,) = gauge.epochInfo(pid);
        vm.warp(uint256(epochEnd) + 1);
        gauge.rollIfNeeded(pid);

        // poke pool after roll – should still be out-of-range
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 afterRoll = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        // wait some hours
        vm.warp(block.timestamp + 4 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 later = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertApproxEqAbs(afterRoll, later, 1e12, "accrued during out-of-range day");
    }

    // Sentinel ticks remain safe after full liquidity burn
    function testSentinelTickSafetyAfterBurn() public {
        // Burn the entire narrow position via EasyPosm helper (this triggers notifyBurn)
        EasyPosm.burn(
            positionManager,
            tokenNarrow,
            0,
            0,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );

        // Poke the pool – should not revert due to under-flow in sentinel logic
        vm.prank(address(hook));
        gauge.pokePool(key);

        // If we reach here, sentinel ticks handled correctly
        assertTrue(true);
    }

    function testCrossTickWithLiquidityChange() public {
        // Narrow position info
        uint128 liqNarrow = positionManager.getPositionLiquidity(tokenNarrow);
        bytes32 posNarrow = keccak256(abi.encode(address(this), int24(-600), int24(600), bytes32(tokenNarrow), pid));

        // 1. Move 30 minutes forward and poke so accumulator timestamp is not 0
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // 2. Swap wBLT -> BMX to cross tick +60 (drive price up)
        uint256 swapIn = 2e22; // smaller than previous big push but enough to cross first tick
        poolManager.unlock(abi.encode(address(wblt), swapIn));
        (, int24 tickNow,,) = StateLibrary.getSlot0(poolManager, pid);
        require(tickNow > 60, "tick not crossed");

        // 3. In the SAME transaction remove half the liquidity of the narrow position
        uint256 halfLiq = liqNarrow / 2;
        positionManager.decreaseLiquidity(
            tokenNarrow,
            halfLiq,
            0,
            0,
            address(this),
            block.timestamp + 1,
            bytes("")
        );

        // 4. Ensure pool didn’t underflow active liquidity (implicitly – no revert so far)
        //    Add liquidity back
        positionManager.increaseLiquidity(
            tokenNarrow,
            uint128(halfLiq),
            type(uint256).max,
            type(uint256).max,
            block.timestamp + 1,
            bytes("")
        );

        // 5. Advance 1h and poke – rewards should increase again
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);
        uint256 pending = gauge.pendingRewards(posNarrow, liqNarrow, pid);
        assertGt(pending, 0, "rewards did not resume");
    }

    /*//////////////////////////////////////////////////////////////
                          UNLOCK CALLBACK
    //////////////////////////////////////////////////////////////*/
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        (address tokenIn, uint256 amountIn) = abi.decode(data, (address, uint256));

        // tokenIn must be either token of the pair
        bool inputIsToken0 = (tokenIn == address(bmx));
        bool inputIsToken1 = (tokenIn == address(wblt));
        require(inputIsToken0 || inputIsToken1, "unexpected token");

        // settle input token into PoolManager
        if (inputIsToken0) {
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
        } else {
            key.currency1.settle(poolManager, address(this), uint128(amountIn), false);
        }
        poolManager.settle();

        SwapParams memory sp;
        if (inputIsToken0) {
            // token0 -> token1 (price down)
            uint160 limit = TickMath.MIN_SQRT_PRICE + 1;
            sp = SwapParams({zeroForOne:true, amountSpecified:-int256(amountIn), sqrtPriceLimitX96:limit});
        } else {
            // token1 -> token0 (price up)
            uint160 limit = TickMath.MAX_SQRT_PRICE - 1;
            sp = SwapParams({zeroForOne:false, amountSpecified:-int256(amountIn), sqrtPriceLimitX96:limit});
        }

        BalanceDelta delta = poolManager.swap(key, sp, bytes(""));

        // take output to balance deltas
        uint256 outAmt = inputIsToken0 ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        if (outAmt > 0) {
            if (inputIsToken0) {
                key.currency1.take(poolManager, address(this), outAmt, false);
            } else {
                key.currency0.take(poolManager, address(this), outAmt, false);
            }
        }
        poolManager.settle();
        return bytes("");
    }

    // Dummy implementation to satisfy IFeeProcessor and avoid revert
    function collectFee(PoolKey calldata, uint256) external override {}
    function collectInternalFee(uint256) external override {}
} 