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
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";

contract DeliHookConstantProduct_TestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    DeliHookConstantProduct hook;

    // Mocks / deps
    MockFeeProcessor feeProcessor;
    MockDailyEpochGauge dailyEpochGauge;
    MockIncentiveGauge incentiveGauge;
    V2PositionHandler v2Handler;

    // Currencies
    Currency wBLT;
    Currency bmx;
    Currency token2;
    Currency token3;

    // Pools
    PoolKey key1; // wBLT/token2, 0.3%
    PoolKey key2; // wBLT/token3, 1%
    PoolKey key3; // wBLT/BMX,   0.1%
    PoolId id1;
    PoolId id2;
    PoolId id3;

    uint256 constant MAX_DEADLINE = 12329839823;

    // Events mirrored from hook for expectEmit matching
    event PairCreated(PoolId indexed poolId, Currency indexed currency0, Currency indexed currency1, uint24 fee);
    event Sync(PoolId indexed poolId, uint128 reserve0, uint128 reserve1);
    event Mint(PoolId indexed poolId, address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(PoolId indexed poolId, address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    function setUp() public virtual {
        deployFreshManagerAndRouters();

        // Deploy tokens
        MockERC20[] memory tokens = deployTokens(4, type(uint256).max);
        wBLT = Currency.wrap(address(tokens[0]));
        bmx = Currency.wrap(address(tokens[1]));
        token2 = Currency.wrap(address(tokens[2]));
        token3 = Currency.wrap(address(tokens[3]));

        // Deploy mocks
        feeProcessor = new MockFeeProcessor();
        dailyEpochGauge = new MockDailyEpochGauge();
        incentiveGauge = new MockIncentiveGauge();

        // Hook address via miner
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
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
                Currency.unwrap(bmx),
                address(this)
            )
        );

        hook = new DeliHookConstantProduct{salt: salt}(
            IPoolManager(address(manager)),
            IFeeProcessor(address(feeProcessor)),
            IDailyEpochGauge(address(dailyEpochGauge)),
            IIncentiveGauge(address(incentiveGauge)),
            Currency.unwrap(wBLT),
            Currency.unwrap(bmx),
            address(this)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");

        // V2 handler + adapter wiring
        v2Handler = new V2PositionHandler(address(hook));
        hook.setV2PositionHandler(address(v2Handler));

        PositionManagerAdapter adapter = new PositionManagerAdapter(
            address(dailyEpochGauge),
            address(incentiveGauge),
            address(0x1),
            address(manager)
        );
        v2Handler.setPositionManagerAdapter(address(adapter));
        adapter.addHandler(address(v2Handler));
        adapter.setAuthorizedCaller(address(hook), true);
        adapter.setAuthorizedCaller(address(v2Handler), true);

        // Pool keys
        key1 = PoolKey({
            currency0: wBLT,
            currency1: token2,
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        id1 = key1.toId();

        key2 = PoolKey({
            currency0: wBLT,
            currency1: token3,
            fee: 10000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        id2 = key2.toId();

        key3 = PoolKey({
            currency0: wBLT,
            currency1: bmx,
            fee: 1000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        id3 = key3.toId();

        // Initialize pools at 1:1
        manager.initialize(key1, SQRT_PRICE_1_1);
        manager.initialize(key2, SQRT_PRICE_1_1);
        manager.initialize(key3, SQRT_PRICE_1_1);

        // Approvals
        tokens[0].approve(address(swapRouter), type(uint256).max);
        tokens[0].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[0].approve(address(hook), type(uint256).max);

        tokens[1].approve(address(swapRouter), type(uint256).max);
        tokens[1].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[1].approve(address(hook), type(uint256).max);

        tokens[2].approve(address(swapRouter), type(uint256).max);
        tokens[2].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[2].approve(address(hook), type(uint256).max);

        tokens[3].approve(address(swapRouter), type(uint256).max);
        tokens[3].approve(address(modifyLiquidityRouter), type(uint256).max);
        tokens[3].approve(address(hook), type(uint256).max);
    }

    // ------------------------- Helpers -------------------------
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
        }), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function swapInPool2(uint256 amount, bool zeroForOne) internal {
        swapRouter.swap(key2, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function swapInPool3(uint256 amount, bool zeroForOne) internal {
        swapRouter.swap(key3, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        }), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
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


