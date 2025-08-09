// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockFeeProcessor} from "test/mocks/MockFeeProcessor.sol";
import {MockDailyEpochGauge} from "test/mocks/MockDailyEpochGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {DeliErrors} from "src/libraries/DeliErrors.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";

contract V2ConstantProductHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    DeliHookConstantProduct hook;
    
    // Mock contracts
    MockFeeProcessor feeProcessor;
    MockDailyEpochGauge dailyEpochGauge;
    MockIncentiveGauge incentiveGauge;
    V2PositionHandler v2Handler;
    
    // Tokens - token0 will be wBLT, token1 will be BMX
    Currency wBLT;
    Currency bmx;
    Currency token2;
    Currency token3;
    
    PoolKey key1; // 0.3% fee pool (wBLT/token2)
    PoolKey key2; // 1% fee pool (wBLT/token3)
    PoolKey key3; // 0.1% fee pool (wBLT/BMX)
    
    PoolId id1;
    PoolId id2;
    PoolId id3;

    uint256 constant MAX_DEADLINE = 12329839823;

    event PoolInitialized(PoolId indexed poolId);
    event Sync(PoolId indexed poolId, uint128 reserve0, uint128 reserve1);
    event MintShares(PoolId indexed poolId, address indexed to, uint256 shares);
    event BurnShares(PoolId indexed poolId, address indexed from, uint256 shares);

    function setUp() public {
        deployFreshManagerAndRouters();
        
        // Deploy tokens
        MockERC20[] memory tokens = deployTokens(4, type(uint256).max);
        wBLT = Currency.wrap(address(tokens[0]));  // wBLT
        bmx = Currency.wrap(address(tokens[1]));   // BMX
        token2 = Currency.wrap(address(tokens[2]));
        token3 = Currency.wrap(address(tokens[3]));
        
        // Deploy mock contracts
        feeProcessor = new MockFeeProcessor();
        dailyEpochGauge = new MockDailyEpochGauge();
        incentiveGauge = new MockIncentiveGauge();

        // Determine hook address with proper flags (including AFTER_INITIALIZE_FLAG and AFTER_SWAP_RETURNS_DELTA_FLAG)
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG | 
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            hookFlags,
            type(DeliHookConstantProduct).creationCode,
            abi.encode(
                address(manager),
                address(feeProcessor),
                address(dailyEpochGauge),
                address(incentiveGauge),
                Currency.unwrap(wBLT),
                Currency.unwrap(bmx)
            )
        );

        hook = new DeliHookConstantProduct{salt: salt}(
            IPoolManager(address(manager)),
            IFeeProcessor(address(feeProcessor)),
            IDailyEpochGauge(address(dailyEpochGauge)),
            IIncentiveGauge(address(incentiveGauge)),
            Currency.unwrap(wBLT),
            Currency.unwrap(bmx)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Deploy and set V2PositionHandler
        v2Handler = new V2PositionHandler(address(hook));
        hook.setV2PositionHandler(address(v2Handler));

        // Create pool keys with different fees (all pools must have wBLT)
        key1 = PoolKey({
            currency0: wBLT,
            currency1: token2,
            fee: 3000, // 0.3%
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        id1 = key1.toId();

        key2 = PoolKey({
            currency0: wBLT,
            currency1: token3,
            fee: 10000, // 1%
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        id2 = key2.toId();

        key3 = PoolKey({
            currency0: wBLT,
            currency1: bmx,
            fee: 1000, // 0.1% - minimum fee for V2 pools
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        id3 = key3.toId();

        // Initialize pools
        manager.initialize(key1, SQRT_PRICE_1_1);
        manager.initialize(key2, SQRT_PRICE_1_1);
        manager.initialize(key3, SQRT_PRICE_1_1);

        // Approve tokens
        tokens[0].approve(address(swapRouter), type(uint256).max); // wBLT
        tokens[0].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[0].approve(address(hook), type(uint256).max);
        
        tokens[1].approve(address(swapRouter), type(uint256).max); // BMX
        tokens[1].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[1].approve(address(hook), type(uint256).max);
        
        tokens[2].approve(address(swapRouter), type(uint256).max); // token2
        tokens[2].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[2].approve(address(hook), type(uint256).max);
        
        tokens[3].approve(address(swapRouter), type(uint256).max); // token3
        tokens[3].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[3].approve(address(hook), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_poolInitialization() public view {
        // Check pools are initialized
        assertTrue(hook.poolInitialized(id1));
        assertTrue(hook.poolInitialized(id2));
        assertTrue(hook.poolInitialized(id3));

        // Check initial reserves are 0
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);

        // Check initial total supply is 0
        assertEq(hook.getTotalSupply(id1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_firstLiquidityAddition() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20 ether;

        // Calculate expected shares (sqrt(10 * 20) - 1000)
        uint256 expectedShares = sqrt(amount0 * amount1) - hook.MINIMUM_LIQUIDITY();

        vm.expectEmit(true, true, true, true);
        emit MintShares(id1, address(this), expectedShares);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0,
            amount1Min: amount1,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Check balances
        assertEq(hook.balanceOf(id1, address(this)), expectedShares);
        assertEq(hook.getTotalSupply(id1), expectedShares + hook.MINIMUM_LIQUIDITY());
        
        // Check minimum liquidity is locked
        assertEq(hook.balanceOf(id1, address(0)), hook.MINIMUM_LIQUIDITY());

        // Check reserves
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, amount0);
        assertEq(reserve1, amount1);
    }

    function test_subsequentLiquidityAddition_optimalRatio() public {
        // First add liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 balanceBefore = hook.balanceOf(id1, address(this));
        uint256 totalSupplyBefore = hook.getTotalSupply(id1);

        // Add liquidity at same ratio
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 5 ether,
            amount1Desired: 10 ether,
            amount0Min: 5 ether,
            amount1Min: 10 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Should mint proportional shares
        // Calculate expected shares based on the minimum of the two ratios
        uint256 expectedNewShares = min(
            (5 ether * totalSupplyBefore) / 10 ether,
            (10 ether * totalSupplyBefore) / 20 ether
        );
        assertEq(hook.balanceOf(id1, address(this)), balanceBefore + expectedNewShares);

        // Check reserves updated correctly
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, 15 ether);
        assertEq(reserve1, 30 ether);
    }

    function test_liquidityAddition_nonOptimalRatio() public {
        // First add liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Try to add liquidity with non-optimal ratio (more token0 than needed)
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 10 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Should only use 5 ether of token0 (to maintain 1:2 ratio)
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, 15 ether);
        assertEq(reserve1, 30 ether);
    }

    function test_liquidityRemoval_partial() public {
        // Add liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 sharesBefore = hook.balanceOf(id1, address(this));
        uint256 wBLTBefore = wBLT.balanceOf(address(this));
        uint256 token2Before = token2.balanceOf(address(this));

        // Remove 50% of liquidity
        uint256 sharesToBurn = sharesBefore / 2;
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: sharesToBurn,
            amount0Min: 0, // No slippage protection for test
            amount1Min: 0, // No slippage protection for test
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Check shares burned
        assertEq(hook.balanceOf(id1, address(this)), sharesBefore - sharesToBurn);

        // Check tokens received (approximately 5 and 10 ether)
        // Allow for rounding errors up to 1000 wei
        assertApproxEqAbs(wBLT.balanceOf(address(this)) - wBLTBefore, 5 ether, 1000);
        assertApproxEqAbs(token2.balanceOf(address(this)) - token2Before, 10 ether, 1000);

        // Check reserves after removing half the user's liquidity
        // Note: Due to MINIMUM_LIQUIDITY locked forever, removing half of user's shares
        // doesn't give exactly half the reserves
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        // Expected: shares_burned * balance / total_supply
        // = 7071067811865474744 * 10 ether / 14142135623730950488 ≈ 4.99999999999999965 ether
        assertEq(reserve0, 5000000000000000354);
        assertEq(reserve1, 10000000000000000708);
    }

    function test_liquidityRemoval_full() public {
        // Add liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 shares = hook.balanceOf(id1, address(this));

        // Remove all liquidity
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Check all shares burned
        assertEq(hook.balanceOf(id1, address(this)), 0);

        // Check only minimum liquidity remains
        assertEq(hook.getTotalSupply(id1), hook.MINIMUM_LIQUIDITY());

        // Check reserves (should have only minimum liquidity worth)
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertTrue(reserve0 > 0 && reserve0 < 1000);
        assertTrue(reserve1 > 0 && reserve1 < 2000);
    }

    function test_liquidityAddition_slippageProtection() public {
        // Add initial liquidity
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 20 ether,
            amount0Min: 10 ether,
            amount1Min: 20 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        // Try to add with too high minimum requirements
        // When trying to add 10 ether of each token to a pool with 1:2 ratio,
        // the contract will calculate that only 5 ether of token0 is needed.
        // This causes slippage error in _getAmountIn
        vm.expectRevert(DeliErrors.Slippage.selector);
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 10 ether, // Can't use full 10 ether at current ratio
            amount1Min: 10 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_swap_exactInput_zeroForOne() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountIn = 10 ether;
        uint256 expectedAmountOut = calculateExactInputSwap(
            amountIn,
            100 ether, // reserve0
            200 ether, // reserve1
            3000       // 0.3% fee
        );

        uint256 token1Before = token2.balanceOf(address(this));

        // Perform swap
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn), // Negative for exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), settings, "");

        // Check output
        assertEq(token2.balanceOf(address(this)) - token1Before, expectedAmountOut);

        // Check reserves updated correctly
        // Note: reserve0 should be 110 - fee amount (0.3% of 10 = 0.03)
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        assertEq(reserve0, 110 ether - 0.03 ether); // 109.97 ether
        assertEq(reserve1, 200 ether - expectedAmountOut);
    }

    function test_swap_exactInput_oneForZero() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountIn = 20 ether;
        
        // For token2 -> wBLT swap, fee is in wBLT (output currency)
        // The user receives output as per standard V2 formula WITH fee
        uint256 expectedAmountOut = calculateExactInputSwap(
            amountIn,
            200 ether, // reserve1
            100 ether, // reserve0
            3000       // 0.3% fee
        );

        uint256 wBLTBefore = wBLT.balanceOf(address(this));

        // Perform swap
        swapRouter.swap(key1, SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");

        // Check output
        assertEq(wBLT.balanceOf(address(this)) - wBLTBefore, expectedAmountOut);
    }

    function test_swap_exactOutput_zeroForOne() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountOut = 20 ether;
        uint256 expectedAmountIn = calculateExactOutputSwap(
            amountOut,
            100 ether, // reserve0
            200 ether, // reserve1
            3000       // 0.3% fee
        );

        uint256 wBLTBefore = wBLT.balanceOf(address(this));
        uint256 token2Before = token2.balanceOf(address(this));

        // Perform swap
        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountOut), // Positive for exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");

        // Check amounts
        assertEq(wBLTBefore - wBLT.balanceOf(address(this)), expectedAmountIn);
        assertEq(token2.balanceOf(address(this)) - token2Before, amountOut);
    }

    function test_swap_differentFees() public {
        // Add liquidity to pools with different fees
        addLiquidityToPool1(100 ether, 100 ether); // 0.3% fee
        addLiquidityToPool2(100 ether, 100 ether); // 1% fee
        addLiquidityToPool3(100 ether, 100 ether); // 0.1% fee

        uint256 amountIn = 10 ether;

        // Calculate expected outputs for different fees
        uint256 expectedOut1 = calculateExactInputSwap(amountIn, 100 ether, 100 ether, 3000);
        uint256 expectedOut2 = calculateExactInputSwap(amountIn, 100 ether, 100 ether, 10000);
        uint256 expectedOut3 = calculateExactInputSwap(amountIn, 100 ether, 100 ether, 1000);

        // Pool with lower fee should give more output
        assertTrue(expectedOut3 > expectedOut1);
        assertTrue(expectedOut1 > expectedOut2);

        // Test actual swaps - note that the expected calculations should match our implementation
        // Pool 1: 0.3% fee
        uint256 token1Before = token2.balanceOf(address(this));
        swapInPool1(amountIn, true);
        uint256 actualOut1 = token2.balanceOf(address(this)) - token1Before;
        
        // Pool 2: 1% fee  
        uint256 token3Before = token3.balanceOf(address(this));
        swapInPool2(amountIn, true);
        uint256 actualOut2 = token3.balanceOf(address(this)) - token3Before;
        
        // Pool 3: 0.1% fee (wBLT/BMX)
        uint256 bmxBefore = MockERC20(Currency.unwrap(bmx)).balanceOf(address(this));
        swapInPool3(amountIn, true);
        uint256 actualOut3 = MockERC20(Currency.unwrap(bmx)).balanceOf(address(this)) - bmxBefore;

        // Pool with lower fee should give more output
        assertTrue(actualOut3 > actualOut1);
        assertTrue(actualOut1 > actualOut2);
    }

    function test_swap_largeSwap_priceImpact() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 100 ether);
        
        // Get actual reserves after adding liquidity
        (uint128 r0Init, uint128 r1Init) = hook.getReserves(id1);
        uint256 kBefore = uint256(r0Init) * uint256(r1Init);

        // Swap 50% of one reserve
        uint256 largeAmountIn = 50 ether;
        uint256 expectedOut = calculateExactInputSwap(largeAmountIn, r0Init, r1Init, 3000);

        swapInPool1(largeAmountIn, true);

        // Check significant price impact
        // For a 50 ether input on 100:100 reserves with 0.3% fee:
        // Expected output ≈ 33.22 ether (about 66% of input, not 40%)
        assertTrue(expectedOut < largeAmountIn); // Output less than input
        assertTrue(expectedOut > largeAmountIn * 30 / 100); // But more than 30% of input

        // Check k remains constant (within rounding)
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        uint256 kAfter = uint256(reserve0) * uint256(reserve1);
        
        // In V2 AMMs with implicit fees and separate fee extraction,
        // K can remain constant or increase slightly due to rounding
        // Large swaps may show more variance but K should remain stable
        assertTrue(kAfter >= kBefore * 999 / 1000); // K should remain within 0.1% of original
        assertTrue(kAfter <= kBefore * 1001 / 1000); // Allow up to 0.1% increase
    }

    function test_swap_insufficientLiquidity() public {
        // Add liquidity
        addLiquidityToPool1(10 ether, 10 ether);

        // Try to swap out more than available
        vm.expectRevert();
        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: int256(11 ether), // Want more output than available
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    /*//////////////////////////////////////////////////////////////
                              SLIPPAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_slippage_exactInput_zeroForOne_revertWithLimitAboveCurrent() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 200 ether);

        // Use virtual price from hook (derived from reserves)
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);

        // zeroForOne, exact input, limit just above virtual current -> expect revert (wrapped)
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: sqrt0 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactInput_zeroForOne_succeedsWithMinLimit() public {
        addLiquidityToPool1(100 ether, 200 ether);
        // MIN price limit should allow any zeroForOne move
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactInput_oneForZero_revertWithLimitBelowCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);

        // oneForZero increases price, so a limit just below virtual current should fail (wrapped)
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: sqrt0 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactInput_oneForZero_succeedsWithMaxLimit() public {
        addLiquidityToPool1(100 ether, 200 ether);
        // MAX price limit should allow any oneForZero move
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactOutput_zeroForOne_revertWithLimitAboveCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);

        // zeroForOne decreases price; setting limit above virtual current should fail even for exact output (wrapped)
        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: int256(1 ether), sqrtPriceLimitX96: sqrt0 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_exactOutput_oneForZero_revertWithLimitBelowCurrent() public {
        addLiquidityToPool1(100 ether, 200 ether);
        (uint160 sqrt0,,,) = hook.getSlot0(manager, id1);

        vm.expectRevert();
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: false, amountSpecified: int256(1 ether), sqrtPriceLimitX96: sqrt0 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_slippage_noLimit_allowsSwap() public {
        addLiquidityToPool1(100 ether, 200 ether);
        // sqrtPriceLimitX96 = 0 disables hook-level slippage check
        swapRouter.swap(
            key1,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: 0}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_swap_multipleSwapsInSameBlock() public {
        // Add liquidity
        addLiquidityToPool1(1000 ether, 1000 ether);

        // Perform multiple swaps
        // Swap 1: wBLT -> token2 (fee in wBLT input, K decreases)
        swapInPool1(10 ether, true);
        // Swap 2: token2 -> wBLT (fee in wBLT output, K unchanged)
        swapInPool1(20 ether, false);
        // Swap 3: wBLT -> token2 (fee in wBLT input, K decreases)
        swapInPool1(5 ether, true);

        // Check final reserves
        (uint128 reserve0, uint128 reserve1) = hook.getReserves(id1);
        uint256 k = uint256(reserve0) * uint256(reserve1);
        uint256 kInitial = 1000 ether * 1000 ether;
        
        // With V2 AMMs and our fee extraction logic, K behavior is complex:
        // - The V2 math already accounts for fees implicitly in the swap calculation
        // - When we extract fees from reserves, it can cause K to change slightly
        // - Rounding effects in the constant product formula can cause small variations
        
        // Allow K to vary within 0.1% of initial value
        uint256 tolerance = kInitial / 1000; // 0.1%
        assertApproxEqAbs(k, kInitial, tolerance, "K should remain within 0.1% of initial");
    }

    /*//////////////////////////////////////////////////////////////
                        MULTI-POOL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_multiPool_independence() public {
        // Add different liquidity to each pool
        addLiquidityToPool1(100 ether, 200 ether);
        addLiquidityToPool2(300 ether, 150 ether);

        // Check reserves are independent
        (uint128 reserve0_1, uint128 reserve1_1) = hook.getReserves(id1);
        (uint128 reserve0_2, uint128 reserve1_2) = hook.getReserves(id2);

        assertEq(reserve0_1, 100 ether);
        assertEq(reserve1_1, 200 ether);
        assertEq(reserve0_2, 300 ether);
        assertEq(reserve1_2, 150 ether);

        // Swap in pool 1 shouldn't affect pool 2
        swapInPool1(10 ether, true);

        (reserve0_2, reserve1_2) = hook.getReserves(id2);
        assertEq(reserve0_2, 300 ether); // Unchanged
        assertEq(reserve1_2, 150 ether); // Unchanged
    }

    /*//////////////////////////////////////////////////////////////
                    ADVANCED SCENARIOS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_swap_zeroAmountIn_reverts() public {
        addLiquidityToPool1(100 ether, 100 ether);

        // Try to swap 0 amount - should revert
        vm.expectRevert();
        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    function test_liquidityAddition_multipleUsers() public {
        // User 1 adds initial liquidity
        addLiquidityToPool1(100 ether, 200 ether);
        uint256 user1Shares = hook.balanceOf(id1, address(this));

        // User 2 adds liquidity
        address user2 = address(0x2);
        deal(Currency.unwrap(wBLT), user2, 1000 ether);
        deal(Currency.unwrap(token2), user2, 1000 ether);
        
        vm.startPrank(user2);
        ERC20(Currency.unwrap(wBLT)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(token2)).approve(address(hook), type(uint256).max);

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 50 ether,
            amount1Desired: 100 ether,
            amount0Min: 50 ether,
            amount1Min: 100 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
        vm.stopPrank();

        uint256 user2Shares = hook.balanceOf(id1, user2);

        // User 2 should get approximately half of user 1's shares (same proportion)
        // Allow for small rounding differences
        assertApproxEqAbs(user2Shares, user1Shares / 2, 1000);

        // Total supply should be sum of both users + minimum liquidity
        assertEq(hook.getTotalSupply(id1), user1Shares + user2Shares + hook.MINIMUM_LIQUIDITY());
    }

    function test_swap_afterFeesAccumulated() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 100 ether);

        // Perform multiple swaps to accumulate fees
        for (uint i = 0; i < 10; i++) {
            swapInPool1(1 ether, true);
            swapInPool1(1 ether, false);
        }

        // Add more liquidity - in our system, fees are extracted so pool value decreases slightly
        uint256 sharesBefore = hook.balanceOf(id1, address(this));
        (uint128 reserve0Before, uint128 reserve1Before) = hook.getReserves(id1);

        // Calculate the exact ratio to maintain
        uint256 amount0 = 100 ether;
        uint256 amount1 = (amount0 * reserve1Before) / reserve0Before;

        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1 + 1 ether, // Add extra to ensure we use full amount0
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        uint256 sharesAfter = hook.balanceOf(id1, address(this));
        uint256 newShares = sharesAfter - sharesBefore;

        // Since fees are extracted, the pool has slightly less value
        // New liquidity providers get slightly MORE shares per unit of liquidity
        assertTrue(newShares > sharesBefore);
    }

    function test_liquidityRemoval_slippageProtection() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 100 ether);

        uint256 shares = hook.balanceOf(id1, address(this));

        // Try to remove with too high slippage protection
        vm.expectRevert(DeliErrors.InsufficientOutput.selector);
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: shares,
            amount0Min: 101 ether, // More than deposited
            amount1Min: 101 ether,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function test_constantProduct_invariant() public {
        // Add liquidity
        addLiquidityToPool1(100 ether, 100 ether);
        
        // Get actual reserves after adding liquidity
        (uint128 r0Init, uint128 r1Init) = hook.getReserves(id1);
        uint256 k0 = uint256(r0Init) * uint256(r1Init);

        // Perform various swaps
        swapInPool1(10 ether, true);
        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        uint256 k1 = uint256(r0) * uint256(r1);
        // Since fees are extracted and forwarded to FeeProcessor,
        // K should remain approximately constant (not increase)
        assertApproxEqRel(k1, k0, 0.01e18); // K should remain within 1% of original

        swapInPool1(5 ether, false);
        (r0, r1) = hook.getReserves(id1);
        uint256 k2 = uint256(r0) * uint256(r1);
        // Each swap maintains K approximately constant
        assertApproxEqRel(k2, k1, 0.01e18); // K should remain within 1% of k1

        // Add more liquidity - use current ratio
        // After swaps, reserves are no longer 1:1, so we need to add at the current ratio
        uint256 amount0ToAdd = 50 ether;
        uint256 amount1ToAdd = (amount0ToAdd * r1) / r0; // Maintain current ratio
        
        addLiquidityToPool1(amount0ToAdd, amount1ToAdd + 1 ether); // Add extra to ensure we use full amount0
        (r0, r1) = hook.getReserves(id1);
        uint256 k3 = uint256(r0) * uint256(r1);
        assertTrue(k3 > k2); // k increases with liquidity

        // Remove some liquidity
        uint256 shares = hook.balanceOf(id1, address(this)) / 2;
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        (r0, r1) = hook.getReserves(id1);
        uint256 k4 = uint256(r0) * uint256(r1);
        assertTrue(k4 < k3); // k decreases with liquidity removal
        
        // When we remove half the liquidity shares, k is reduced proportionally
        // k4 should be approximately k3 * (remaining_liquidity / total_liquidity)²
        // Since we removed half: k4 ≈ k3 * 0.5² = k3 * 0.25
        // Allow for some variance due to rounding
        uint256 expectedK4 = k3 / 4;
        assertApproxEqRel(k4, expectedK4, 0.01e18); // Within 1%
    }

    function test_liquidityAddition_deadline() public {
        // Try to add liquidity with expired deadline
        vm.expectRevert(MultiPoolCustomCurve.ExpiredPastDeadline.selector);
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp - 1,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function test_swap_exactOutput_insufficientInput() public {
        // Add liquidity
        addLiquidityToPool1(10 ether, 10 ether);

        // Calculate how much input would be needed for 5 ether output
        uint256 expectedInput = calculateExactOutputSwap(5 ether, 10 ether, 10 ether, 3000);

        // User doesn't have enough tokens
        address poorUser = address(0x3);
        deal(Currency.unwrap(wBLT), poorUser, expectedInput - 1); // Not enough
        
        vm.startPrank(poorUser);
        ERC20(Currency.unwrap(wBLT)).approve(address(swapRouter), type(uint256).max);

        // Should revert due to insufficient balance
        vm.expectRevert();
        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: int256(5 ether),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        FEE ORIENTATION TESTS
    //////////////////////////////////////////////////////////////*/

    // wBLT -> token2, exact input: fee in wBLT (input side)
    function test_fee_wbltToToken2_exactInput() public {
        // Add liquidity so reserves are known
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountIn = 10 ether; // wBLT in
        uint256 feePips = 3000; // 0.3%

        // Expected fee is percentage of input since fee currency = wBLT = input
        uint256 expectedFee = (amountIn * feePips) / 1_000_000;

        // Perform swap: token0 (wBLT) -> token1 (token2), exact input
        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        // FeeProcessor should have received the expected wBLT amount
        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch (wBLT->x exact in)");
        assertEq(feeProcessor.calls(), 1, "collectFee not called");
    }

    // wBLT -> token2, exact output: fee in wBLT (input side)
    function test_fee_wbltToToken2_exactOutput() public {
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountOut = 20 ether; // token2 out
        uint256 feePips = 3000; // 0.3%

        // Compute inputs at pre-swap reserves
        // With fee (actual input)
        uint256 inputWithFee = calculateExactOutputSwap(amountOut, 100 ether, 200 ether, feePips);
        // Without fee
        uint256 inputNoFee = calculateExactOutputSwap(amountOut, 100 ether, 200 ether, 0);
        uint256 expectedFee = inputWithFee > inputNoFee ? inputWithFee - inputNoFee : 0;

        // Perform swap: token0 (wBLT) -> token1 (token2), exact output
        swapRouter.swap(key1, SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch (wBLT->x exact out)");
        assertEq(feeProcessor.calls(), 1, "collectFee not called");
    }

    // token2 -> wBLT, exact input: fee in wBLT (output side)
    function test_fee_token2ToWblt_exactInput() public {
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountIn = 10 ether; // token2 in
        uint256 feePips = 3000; // 0.3%

        // Compute output with and without fee from pre-swap reserves
        uint256 outWithFee = calculateExactInputSwap(amountIn, 200 ether, 100 ether, feePips);
        uint256 outNoFee = calculateExactInputSwap(amountIn, 200 ether, 100 ether, 0);
        uint256 expectedFee = outNoFee > outWithFee ? outNoFee - outWithFee : 0; // fee in wBLT (output)

        // Perform swap: token1 (token2) -> token0 (wBLT), exact input
        swapRouter.swap(key1, SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch (x->wBLT exact in)");
        assertEq(feeProcessor.calls(), 1, "collectFee not called");
    }

    // token2 -> wBLT, exact output: fee in wBLT (output side)
    function test_fee_token2ToWblt_exactOutput() public {
        addLiquidityToPool1(100 ether, 200 ether);

        uint256 amountOut = 15 ether; // wBLT out
        uint256 feePips = 3000; // 0.3%

        // Fee is percentage of specified output since fee currency = wBLT = specified
        uint256 expectedFee = (amountOut * feePips) / 1_000_000;

        // Perform swap: token1 (token2) -> token0 (wBLT), exact output
        swapRouter.swap(key1, SwapParams({
            zeroForOne: false,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        assertEq(feeProcessor.lastAmount(), expectedFee, "fee mismatch (x->wBLT exact out)");
        assertEq(feeProcessor.calls(), 1, "collectFee not called");
    }

    function test_fuzz_constantProductMath(
        uint128 reserve0,
        uint128 reserve1,
        uint112 amountIn
    ) public {
        // Bound inputs to reasonable values
        reserve0 = uint128(bound(reserve0, 1 ether, 1000000 ether));
        reserve1 = uint128(bound(reserve1, 1 ether, 1000000 ether));
        amountIn = uint112(bound(amountIn, 0.001 ether, reserve0 / 2));

        // First mint to get initial liquidity
        addLiquidityToPool1(reserve0, reserve1);
        
        // Get actual reserves after adding liquidity
        (uint128 actualReserve0, uint128 actualReserve1) = hook.getReserves(id1);

        // Perform swap
        uint256 expectedOut = calculateExactInputSwap(amountIn, actualReserve0, actualReserve1, 3000);
        
        uint256 token1Before = token2.balanceOf(address(this));
        swapInPool1(amountIn, true);
        uint256 actualOut = token2.balanceOf(address(this)) - token1Before;

        // Check output matches expected
        assertEq(actualOut, expectedOut);

        // Verify constant product maintained (with fees)
        (uint128 newReserve0, uint128 newReserve1) = hook.getReserves(id1);
        uint256 kBefore = uint256(actualReserve0) * uint256(actualReserve1);
        uint256 kAfter = uint256(newReserve0) * uint256(newReserve1);
        
        // In V2 AMMs with implicit fees, K remains approximately constant
        // It may increase slightly due to rounding in the constant product formula
        assertTrue(kAfter >= kBefore * 999 / 1000); // K should remain within 0.1% of original
        assertTrue(kAfter <= kBefore * 1001 / 1000); // Allow up to 0.1% increase
    }

    function test_internalSwapOnlyFeeProcessor() public {
        // Setup BMX pool (key3 is wBLT/BMX pool)
        addLiquidityToPool3(100 ether, 100 ether);
        
        // Try to use internal swap flag as non-FeeProcessor
        bytes memory hookData = abi.encode(bytes4(0xDE1ABEEF)); // INTERNAL_SWAP_FLAG
        
        // Track fee calls before
        uint256 regularFeeCallsBefore = feeProcessor.calls();
        
        // Perform swap with internal flag but from swapRouter (not FeeProcessor)
        // This should be treated as a regular swap since sender != feeProcessor
        swapRouter.swap(key3, SwapParams({
            zeroForOne: false, // wBLT -> BMX
            amountSpecified: -int256(10 ether),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), hookData);
        
        // Check that REGULAR fee was collected (not internal)
        assertEq(feeProcessor.calls(), regularFeeCallsBefore + 1, "Regular fee should be collected");
        assertEq(feeProcessor.internalFeeCalls(), 0, "Internal fee should NOT be collected");
        
        // Check that gauges WERE poked (regular swap behavior)
        assertGt(dailyEpochGauge.pokeCalls(), 0, "DailyEpochGauge should be poked for regular swap");
        assertGt(incentiveGauge.pokeCount(), 0, "IncentiveGauge should be poked for regular swap");
    }
    
    function test_internalSwapFromFeeProcessor() public {
        // This test would need to simulate an actual call from FeeProcessor
        // In real usage, only FeeProcessor can trigger internal swaps during flushBuffers
        // The MockFeeProcessor doesn't actually perform swaps, so we can't test the full flow here
        // But we've verified above that non-FeeProcessor senders can't trigger internal swap behavior
    }

    function test_regularSwapStillWorksAfterInternalSwap() public {
        // Setup BMX pool
        addLiquidityToPool3(100 ether, 100 ether);
        
        // First perform swap with internal flag (but from swapRouter, so treated as regular)
        bytes memory hookData = abi.encode(bytes4(0xDE1ABEEF));
        swapRouter.swap(key3, SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(5 ether),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), hookData);
        
        // Track gauge calls and fee calls before second swap
        uint256 dailyPokesBefore = dailyEpochGauge.pokeCalls();
        uint256 incentivePokesBefore = incentiveGauge.pokeCount();
        uint256 feeCallsBefore = feeProcessor.calls();
        
        // Now perform regular swap
        swapInPool3(10 ether, false);
        
        // Check that regular fee collection occurred
        assertEq(feeProcessor.calls(), feeCallsBefore + 1, "Regular fee should be collected");
        
        // For BMX -> wBLT swap on BMX pool (key3), fee is in BMX (input)
        // Since zeroForOne=false: input=currency1=BMX, output=currency0=wBLT
        uint256 feeAmount = feeProcessor.lastAmount();
        assertGt(feeAmount, 0, "Fee should be collected");
        // Fee should be exactly 0.1% of input since fee is taken from input currency
        assertEq(feeAmount, 10 * 10**15, "Fee should be 0.1% of input");
        
        // Check gauges were poked for regular swap
        assertEq(dailyEpochGauge.pokeCalls(), dailyPokesBefore + 1, "DailyEpochGauge should be poked");
        assertEq(incentiveGauge.pokeCount(), incentivePokesBefore + 1, "IncentiveGauge should be poked");
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addLiquidityToPool1(uint256 amount0, uint256 amount1) internal {
        hook.addLiquidity(key1, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function addLiquidityToPool2(uint256 amount0, uint256 amount1) internal {
        hook.addLiquidity(key2, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function addLiquidityToPool3(uint256 amount0, uint256 amount1) internal {
        hook.addLiquidity(key3, MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));
    }

    function swapInPool1(uint256 amount, bool zeroForOne) internal {
        swapRouter.swap(key1, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    function swapInPool2(uint256 amount, bool zeroForOne) internal {
        swapRouter.swap(key2, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    function swapInPool3(uint256 amount, bool zeroForOne) internal {
        swapRouter.swap(key3, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }), "");
    }

    function calculateExactInputSwap(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fee
    ) internal pure returns (uint256) {
        uint256 feeBasis = 1000000 - fee;
        uint256 amountInWithFee = amountIn * feeBasis;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000000 + amountInWithFee;
        return numerator / denominator;
    }

    function calculateExactOutputSwap(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fee
    ) internal pure returns (uint256) {
        if (amountOut >= reserveOut) revert DeliErrors.InsufficientLiquidity();
        uint256 feeBasis = 1000000 - fee;
        uint256 numerator = reserveIn * amountOut * 1000000;
        uint256 denominator = (reserveOut - amountOut) * feeBasis;
        return (numerator / denominator) + 1;
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}