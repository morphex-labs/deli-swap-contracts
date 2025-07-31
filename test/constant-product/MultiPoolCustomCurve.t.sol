// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MultiPoolCustomCurveMock} from "test/mocks/MultiPoolCustomCurveMock.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract MultiPoolCustomCurveTest is Test, Deployers {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    MultiPoolCustomCurveMock hook;

    uint256 constant MAX_DEADLINE = 12329839823;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    // Multiple pools
    PoolKey key1;
    PoolKey key2;
    PoolId id1;
    PoolId id2;

    Currency currency2;
    Currency currency3;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Define hook flags
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        
        // Use HookMiner to find the correct address
        bytes memory ctorArgs = abi.encode(manager);
        (, bytes32 salt) = HookMiner.find(
            address(this), 
            hookFlags, 
            type(MultiPoolCustomCurveMock).creationCode, 
            ctorArgs
        );
        
        // Deploy hook with the salt
        hook = new MultiPoolCustomCurveMock{salt: salt}(manager);

        // Deploy and mint currencies manually to avoid overwriting globals
        MockERC20[] memory tokens = deployTokens(4, 2 ** 255);
        
        currency0 = Currency.wrap(address(tokens[0]));
        currency1 = Currency.wrap(address(tokens[1]));
        currency2 = Currency.wrap(address(tokens[2]));
        currency3 = Currency.wrap(address(tokens[3]));
        
        // Approve currencies for all routers
        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];
        
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < toApprove.length; j++) {
                tokens[i].approve(toApprove[j], type(uint256).max);
            }
        }
        
        // Create pool keys
        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        key2 = PoolKey({
            currency0: currency2,
            currency1: currency3,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        // Initialize pools directly
        manager.initialize(key1, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(0));
        
        // Get pool IDs
        id1 = key1.toId();
        id2 = key2.toId();

        // Approve hook for all currencies
        tokens[0].approve(address(hook), type(uint256).max);
        tokens[1].approve(address(hook), type(uint256).max);
        tokens[2].approve(address(hook), type(uint256).max);
        tokens[3].approve(address(hook), type(uint256).max);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
        vm.label(Currency.unwrap(currency2), "currency2");
        vm.label(Currency.unwrap(currency3), "currency3");
    }

    function test_multiplePoolsInitialized() public view {
        assertTrue(hook.poolInitialized(id1));
        assertTrue(hook.poolInitialized(id2));
        assertFalse(PoolId.unwrap(id1) == PoolId.unwrap(id2));
    }

    function test_swaps_multiplePoolsIndependent() public {
        // Add liquidity to both pools
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams(
            20 ether, 20 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Record balances before swaps
        uint256 balance0_pool1_before = currency0.balanceOf(address(this));
        uint256 balance1_pool1_before = currency1.balanceOf(address(this));
        uint256 balance0_pool2_before = currency2.balanceOf(address(this));
        uint256 balance1_pool2_before = currency3.balanceOf(address(this));

        // Swap in pool 1
        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        swapRouter.swap(key1, params1, settings, ZERO_BYTES);

        // Swap in pool 2 (different amount)
        SwapParams memory params2 = SwapParams({
            zeroForOne: true,
            amountSpecified: -2 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        swapRouter.swap(key2, params2, settings, ZERO_BYTES);

        // Check that swaps affected only their respective pools
        assertEq(currency0.balanceOf(address(this)), balance0_pool1_before - 1 ether);
        assertGt(currency1.balanceOf(address(this)), balance1_pool1_before); // Received some currency1
        assertEq(currency2.balanceOf(address(this)), balance0_pool2_before - 2 ether);
        assertGt(currency3.balanceOf(address(this)), balance1_pool2_before); // Received some currency3
    }

    function test_addLiquidity_swapThenAdd_multiplePoolsSimultaneous() public {
        // Add initial liquidity to both pools
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Perform swaps on both pools
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        swapRouter.swap(key1, params, settings, ZERO_BYTES);
        swapRouter.swap(key2, params, settings, ZERO_BYTES);

        // Add more liquidity after swaps
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            5 ether, 5 ether, 4 ether, 4 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams(
            5 ether, 5 ether, 4 ether, 4 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Check liquidity tokens
        assertGt(hook.balanceOf(id1, address(this)), 10 ether);
        assertGt(hook.balanceOf(id2, address(this)), 10 ether);
    }

    function test_swap_exactOutput_multiplePoolsDifferentAmounts() public {
        // Add liquidity to both pools
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Exact output swap in pool 1
        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // positive for exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        
        // Exact output swap in pool 2 (different amount)
        SwapParams memory params2 = SwapParams({
            zeroForOne: true,
            amountSpecified: 2 ether, // positive for exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key1, params1, settings, ZERO_BYTES);
        swapRouter.swap(key2, params2, settings, ZERO_BYTES);

        // Both swaps should succeed independently
        assertTrue(currency1.balanceOf(address(this)) > 0);
        assertTrue(currency3.balanceOf(address(this)) > 0);
    }

    function test_removeLiquidity_afterSwaps_multiplePoolsProportional() public {
        // Add liquidity to both pools
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Perform swaps
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 10 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        swapRouter.swap(key1, params, settings, ZERO_BYTES);
        swapRouter.swap(key2, params, settings, ZERO_BYTES);

        // Remove liquidity from both pools
        uint256 liquidity1 = hook.balanceOf(id1, address(this));
        uint256 liquidity2 = hook.balanceOf(id2, address(this));

        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            liquidity1, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.removeLiquidity(key2, MultiPoolCustomCurve.RemoveLiquidityParams(
            liquidity2, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        assertEq(manager.getLiquidity(id1), 0);
        assertEq(manager.getLiquidity(id2), 0);
    }

    function test_fuzz_multiplePoolsWithDifferentFees(uint24 fee1, uint24 fee2) public {
        // Bound fees to reasonable values
        fee1 = uint24(bound(fee1, 0, 100000)); // Max 10%
        fee2 = uint24(bound(fee2, 0, 100000)); // Max 10%

        // Initialize new pools with different fees using the same hook
        PoolKey memory feeKey1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee1,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        PoolKey memory feeKey2 = PoolKey({
            currency0: currency2,
            currency1: currency3,
            fee: fee2,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        // Initialize pools
        manager.initialize(feeKey1, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(feeKey2, TickMath.getSqrtPriceAtTick(0));
        
        PoolId feeId1 = feeKey1.toId();
        PoolId feeId2 = feeKey2.toId();

        // Add liquidity to both pools
        hook.addLiquidity(feeKey1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(feeKey2, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Perform swaps - pools with different fees should work independently
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Both swaps should succeed regardless of fee differences
        swapRouter.swap(feeKey1, params, settings, ZERO_BYTES);
        swapRouter.swap(feeKey2, params, settings, ZERO_BYTES);
    }

    function test_contextSwitching_duringNestedOperations() public {
        // This test ensures that context switching works correctly when operations trigger callbacks
        
        // Add liquidity to both pools
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Create a special test that interleaves operations
        uint256 balance1Before = hook.balanceOf(id1, address(this));
        uint256 balance2Before = hook.balanceOf(id2, address(this));

        // Remove from pool 1
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            balance1Before / 2, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Immediately remove from pool 2
        hook.removeLiquidity(key2, MultiPoolCustomCurve.RemoveLiquidityParams(
            balance2Before / 2, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Verify correct balances
        assertEq(hook.balanceOf(id1, address(this)), balance1Before / 2);
        assertEq(hook.balanceOf(id2, address(this)), balance2Before / 2);
    }

    // Additional tests adapted from BaseCustomAccounting.t.sol

    function test_addLiquidity_succeeds() public {
        uint256 prevBalance0 = currency0.balanceOf(address(this));
        uint256 prevBalance1 = currency1.balanceOf(address(this));

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

        assertEq(currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(currency1.balanceOf(address(this)), prevBalance1 - 10 ether);
        assertEq(liquidityTokenBal, 10 ether);
    }

    function test_addLiquidity_tooMuchSlippage_reverts() public {
        vm.expectRevert(MultiPoolCustomCurve.TooMuchSlippage.selector);
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 100000 ether, 100000 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
    }

    function test_addLiquidity_expired_revert() public {
        vm.expectRevert(MultiPoolCustomCurve.ExpiredPastDeadline.selector);
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            0, 0, 0, 0, block.timestamp - 1, MIN_TICK, MAX_TICK, bytes32(0)
        ));
    }

    function test_removeLiquidity_tooMuchSlippage_reverts() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        vm.expectRevert(MultiPoolCustomCurve.TooMuchSlippage.selector);
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            10 ether, 11 ether, 11 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Should succeed with proper slippage tolerance (expecting 10 ether of each)
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            10 ether, 10 ether, 10 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
    }

    function test_removeLiquidity_initialRemove_succeeds() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 prevBalance0 = currency0.balanceOf(address(this));
        uint256 prevBalance1 = currency1.balanceOf(address(this));

        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

        assertEq(liquidityTokenBal, 99 ether);
        assertEq(currency0.balanceOf(address(this)), prevBalance0 + 1 ether);
        assertEq(currency1.balanceOf(address(this)), prevBalance1 + 1 ether);
    }

    function test_removeLiquidity_partial_succeeds() public {
        uint256 prevBalance0 = currency0.balanceOf(address(this));
        uint256 prevBalance1 = currency1.balanceOf(address(this));

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        assertEq(hook.balanceOf(id1, address(this)), 10 ether);
        assertEq(currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            5 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

        assertEq(liquidityTokenBal, 5 ether);
        assertEq(currency0.balanceOf(address(this)), prevBalance0 - 5 ether);
        assertEq(currency1.balanceOf(address(this)), prevBalance1 - 5 ether);
    }

    function test_removeLiquidity_diffRatios_succeeds() public {
        uint256 prevBalance0 = currency0.balanceOf(address(this));
        uint256 prevBalance1 = currency1.balanceOf(address(this));

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        assertEq(currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(currency1.balanceOf(address(this)), prevBalance1 - 10 ether);
        assertEq(hook.balanceOf(id1, address(this)), 10 ether);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            5 ether, 2.5 ether, 2 ether, 2 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // Second add: 5 ether + 2.5 ether, shares = (5 + 2.5) / 2 = 3.75 ether
        // Total shares = 10 + 3.75 = 13.75 ether
        assertEq(currency0.balanceOf(address(this)), prevBalance0 - 15 ether);
        assertEq(currency1.balanceOf(address(this)), prevBalance1 - 12.5 ether);
        assertEq(hook.balanceOf(id1, address(this)), 13.75 ether);

        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            5 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

        // Remaining shares: 13.75 - 5 = 8.75 ether
        assertEq(liquidityTokenBal, 8.75 ether);
        // Proportional removal: 5/13.75 of (15 ether token0, 12.5 ether token1)
        // token0 returned: 5 * 15 / 13.75 = 5.454545... ether
        // token1 returned: 5 * 12.5 / 13.75 = 4.545454... ether
        // So remaining balances should be approximately:
        // token0: 15 - 5.454545 = 9.545455 ether
        // token1: 12.5 - 4.545454 = 7.954546 ether
        assertTrue(currency0.balanceOf(address(this)) > prevBalance0 - 9.6 ether);
        assertTrue(currency0.balanceOf(address(this)) < prevBalance0 - 9.5 ether);
        assertTrue(currency1.balanceOf(address(this)) > prevBalance1 - 8 ether);
        assertTrue(currency1.balanceOf(address(this)) < prevBalance1 - 7.9 ether);
    }

    function test_removeLiquidity_multiple_succeeds() public {
        // Mint tokens for dummy addresses
        deal(Currency.unwrap(currency0), address(1), 2 ** 128);
        deal(Currency.unwrap(currency1), address(1), 2 ** 128);
        deal(Currency.unwrap(currency0), address(2), 2 ** 128);
        deal(Currency.unwrap(currency1), address(2), 2 ** 128);

        // Approve the hook
        vm.prank(address(1));
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        vm.prank(address(1));
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.prank(address(2));
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        vm.prank(address(2));
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // address(1) adds liquidity
        vm.prank(address(1));
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // address(2) adds liquidity
        vm.prank(address(2));
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 100 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-887271)
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key1, params, testSettings, ZERO_BYTES);

        // address(1) removes liquidity, succeeds
        vm.startPrank(address(1));
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            hook.balanceOf(id1, address(1)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
        vm.stopPrank();

        // address(2) removes liquidity, succeeds
        vm.startPrank(address(2));
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            hook.balanceOf(id1, address(2)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        // All liquidity should be removed
        assertEq(hook.balanceOf(id1, address(1)), 0);
        assertEq(hook.balanceOf(id1, address(2)), 0);
    }

    function test_removeLiquidity_notInitialized_reverts() public {
        // Create a new pool key for an uninitialized pool
        PoolKey memory uninitializedKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(MultiPoolCustomCurve.PoolNotInitialized.selector);
        hook.removeLiquidity(uninitializedKey, MultiPoolCustomCurve.RemoveLiquidityParams(
            1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
    }

    function test_addLiquidity_notInitialized_reverts() public {
        // Create a new pool key for an uninitialized pool
        PoolKey memory uninitializedKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(MultiPoolCustomCurve.PoolNotInitialized.selector);
        hook.addLiquidity(uninitializedKey, MultiPoolCustomCurve.AddLiquidityParams(
            1 ether, 1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));
    }

    function test_addLiquidity_fuzz_succeeds(uint112 amount) public {
        vm.assume(amount > 0);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            amount, amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

        assertEq(liquidityTokenBal, amount);
    }

    function test_removeLiquidity_fuzz_succeeds(uint256 amount) public {
        // First add some liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            100 ether, 100 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 balance = hook.balanceOf(id1, address(this));
        
        if (amount > balance) {
            vm.expectRevert();
            hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
                amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            ));
        } else {
            uint256 prevLiquidityTokenBal = hook.balanceOf(id1, address(this));
            hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
                amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            ));

            uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

            assertEq(prevLiquidityTokenBal - liquidityTokenBal, amount);
        }
    }

    function test_swap_twoSwaps_succeeds() public {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            2 ether, 2 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key1, params, settings, ZERO_BYTES);
        swapRouter.swap(key1, params, settings, ZERO_BYTES);
    }

    function test_removeLiquidity_allFuzz_succeeds(uint112 amount) public {
        vm.assume(amount > 0);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams(
            amount, amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        uint256 liquidityTokenBal = hook.balanceOf(id1, address(this));

        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams(
            liquidityTokenBal, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        ));

        assertEq(hook.balanceOf(id1, address(this)), 0);
    }
}