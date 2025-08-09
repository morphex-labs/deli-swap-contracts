// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Our contracts
import {FeeProcessor} from "src/FeeProcessor.sol";
import {DeliHook} from "src/DeliHook.sol";
import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";
import {V4PositionHandler} from "src/handlers/V4PositionHandler.sol";
import {V2PositionHandler} from "src/handlers/V2PositionHandler.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";

import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @notice Deployment script for Base Mainnet
/// @dev Update the addresses below with actual Base Mainnet addresses before deploying
contract BaseMainnetDeploy is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                           BASE MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    
    // UPDATE THESE WITH ACTUAL BASE MAINNET ADDRESSES
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Uniswap V4 PoolManager on Base
    address constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc; // Uniswap V4 PositionManager on Base
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43; // Uniswap Universal Router on Base
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Permit2 on Base
    
    // Token addresses on Base
    address constant WBLT = 0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A;
    address constant BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;  
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /*//////////////////////////////////////////////////////////////
                           DEPLOYED CONTRACTS
    //////////////////////////////////////////////////////////////*/

    // Uniswap contracts
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IUniversalRouter public universalRouter;
    IPermit2 public permit2;

    // Our contracts
    FeeProcessor public feeProcessor;
    DeliHook public deliHook;
    DeliHookConstantProduct public deliHookConstantProduct;
    DailyEpochGauge public dailyEpochGauge;
    IncentiveGauge public incentiveGauge;
    PositionManagerAdapter public positionManagerAdapter;
    V4PositionHandler public v4Handler;
    V2PositionHandler public v2Handler;
    
    // Pool keys
    PoolKey public v4PoolKey;  // wBLT/USDC with DeliHook
    PoolKey public v2PoolKey;  // wBLT/BMX with DeliHookConstantProduct
    
    // Position ID for V4
    uint256 public v4PositionId;

    function run() public {
        console.log("=== Base Mainnet Deployment ===");
        console.log("Deployer:", msg.sender);
        
        // Load existing contracts
        poolManager = IPoolManager(POOL_MANAGER);
        positionManager = IPositionManager(POSITION_MANAGER);
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER);
        permit2 = IPermit2(PERMIT2);
        
        // Mine DeliHook address before broadcast
        (address deliHookAddress, bytes32 deliHookSalt) = _mineDeliHookAddress();
        
        vm.startBroadcast();
        
        // Deploy all our contracts
        _deployContracts(deliHookAddress, deliHookSalt);
        
        // Configure all relationships
        _configureContracts();
        
        // Initialize pools
        _initializePools();
        
        // Perform initial operations
        _performOperations();
        
        // Set up rewards
        _setupIncentives();
        
        vm.stopBroadcast();
        
        _printSummary();
    }
    
    function _mineDeliHookAddress() internal view returns (address, bytes32) {
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG | 
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            WBLT,
            BMX,
            msg.sender // owner
        );
        
        return HookMiner.find(
            CREATE2_DEPLOYER,
            hookFlags,
            type(DeliHook).creationCode,
            ctorArgs
        );
    }
    
    function _mineDeliHookConstantProductAddress(address feeProcessorAddress) internal view returns (address, bytes32) {
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
        
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(feeProcessorAddress),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            WBLT,
            BMX,
            msg.sender // owner
        );
        
        return HookMiner.find(
            CREATE2_DEPLOYER,
            hookFlags,
            type(DeliHookConstantProduct).creationCode,
            ctorArgs
        );
    }
    
    function _deployContracts(address deliHookAddress, bytes32 deliHookSalt) internal {
        console.log("\n=== Deploying Contracts ===");
        
        // 1. Deploy position handlers
        v4Handler = new V4PositionHandler(address(positionManager));
        console.log("V4PositionHandler deployed:", address(v4Handler));
        
        // 2. Deploy IncentiveGauge first
        incentiveGauge = new IncentiveGauge(
            poolManager,
            IPositionManagerAdapter(address(0)), // Will set after PositionManagerAdapter deployment
            deliHookAddress
        );
        console.log("IncentiveGauge deployed:", address(incentiveGauge));
        
        // 3. Deploy DailyEpochGauge with IncentiveGauge address
        dailyEpochGauge = new DailyEpochGauge(
            address(0), // Will set FeeProcessor after deployment
            poolManager,
            IPositionManagerAdapter(address(0)), // Will set after PositionManagerAdapter deployment
            deliHookAddress, // Using predicted address
            IERC20(BMX),
            address(incentiveGauge) // Pass actual IncentiveGauge address
        );
        console.log("DailyEpochGauge deployed:", address(dailyEpochGauge));
        
        // 4. Deploy FeeProcessor with actual DailyEpochGauge address
        feeProcessor = new FeeProcessor(
            poolManager,
            deliHookAddress,
            WBLT,
            BMX,
            IDailyEpochGauge(address(dailyEpochGauge)),
            msg.sender // Using deployer as voter distributor for now
        );
        console.log("FeeProcessor deployed:", address(feeProcessor));
        
        // 5. Deploy DeliHook with salt
        _deployDeliHook(deliHookAddress, deliHookSalt);
        
        // 6. Mine DeliHookConstantProduct address now that we have FeeProcessor
        (address deliHookCPAddress, bytes32 deliHookCPSalt) = _mineDeliHookConstantProductAddress(address(feeProcessor));
        
        // 7. Deploy DeliHookConstantProduct with salt
        _deployDeliHookConstantProduct(deliHookCPAddress, deliHookCPSalt);
        
        // 8. Deploy V2 handler now that we have the hook address
        v2Handler = new V2PositionHandler(address(deliHookConstantProduct));
        console.log("V2PositionHandler deployed:", address(v2Handler));
        
        // 9. Now deploy PositionManagerAdapter with gauge addresses
        positionManagerAdapter = new PositionManagerAdapter(
            address(dailyEpochGauge),
            address(incentiveGauge),
            address(positionManager),
            address(poolManager)
        );
        console.log("PositionManagerAdapter deployed:", address(positionManagerAdapter));
    }
    
    function _deployDeliHook(address predictedHookAddress, bytes32 salt) internal {
        // Deploy hook using CREATE2
        deliHook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            WBLT,
            BMX,
            msg.sender // owner
        );
        
        require(address(deliHook) == predictedHookAddress, "DeliHook address mismatch");
        console.log("DeliHook deployed:", address(deliHook));
    }
    
    function _deployDeliHookConstantProduct(address predictedHookAddress, bytes32 salt) internal {
        // Deploy hook using CREATE2
        deliHookConstantProduct = new DeliHookConstantProduct{salt: salt}(
            poolManager,
            IFeeProcessor(address(feeProcessor)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            WBLT,
            BMX,
            msg.sender // owner
        );
        
        require(address(deliHookConstantProduct) == predictedHookAddress, "DeliHookConstantProduct address mismatch");
        console.log("DeliHookConstantProduct deployed:", address(deliHookConstantProduct));
    }
    
    function _configureContracts() internal {
        console.log("\n=== Configuring Contracts ===");
        
        // Configure hooks
        deliHook.setFeeProcessor(address(feeProcessor));
        deliHook.setDailyEpochGauge(address(dailyEpochGauge));
        deliHook.setIncentiveGauge(address(incentiveGauge));
        
        deliHookConstantProduct.setFeeProcessor(address(feeProcessor));
        deliHookConstantProduct.setDailyEpochGauge(address(dailyEpochGauge));
        deliHookConstantProduct.setIncentiveGauge(address(incentiveGauge));
        
        // Configure FeeProcessor
        feeProcessor.setHook(address(deliHook), true);
        feeProcessor.setHook(address(deliHookConstantProduct), true);
        
        // Configure gauges
        dailyEpochGauge.setFeeProcessor(address(feeProcessor)); // Set the FeeProcessor that was address(0) during deployment
        dailyEpochGauge.setHook(address(deliHook), true);
        dailyEpochGauge.setHook(address(deliHookConstantProduct), true);
        
        incentiveGauge.setHook(address(deliHook), true);
        incentiveGauge.setHook(address(deliHookConstantProduct), true);
        
        // Configure PositionManagerAdapter
        // Note: Gauges are already set in constructor, no need to call setGauges
        positionManagerAdapter.addHandler(address(v4Handler));
        positionManagerAdapter.addHandler(address(v2Handler));
        positionManagerAdapter.setAuthorizedCaller(address(positionManager), true);
        positionManagerAdapter.setAuthorizedCaller(address(deliHookConstantProduct), true);
        positionManagerAdapter.setAuthorizedCaller(address(v2Handler), true);
        
        // Update gauges with adapter (they were deployed with address(0))
        dailyEpochGauge.setPositionManagerAdapter(address(positionManagerAdapter));
        incentiveGauge.setPositionManagerAdapter(address(positionManagerAdapter));
        
        // Add V2 position handler to hook
        deliHookConstantProduct.setV2PositionHandler(address(v2Handler));
        
        // Configure V2 handler
        v2Handler.setPositionManagerAdapter(address(positionManagerAdapter));
        
        // Whitelist BMX for incentives
        incentiveGauge.setWhitelist(IERC20(BMX), true);
        
        console.log("All contracts configured");
    }
    
    function _initializePools() internal {
        console.log("\n=== Initializing Pools ===");
        
        // Create V4 pool key (wBLT/USDC with DeliHook)
        v4PoolKey = PoolKey({
            currency0: Currency.wrap(WBLT < USDC ? WBLT : USDC),
            currency1: Currency.wrap(WBLT < USDC ? USDC : WBLT),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(deliHook))
        });
        
        // Create V2 pool key (wBLT/BMX with DeliHookConstantProduct)
        v2PoolKey = PoolKey({
            currency0: Currency.wrap(WBLT < BMX ? WBLT : BMX),
            currency1: Currency.wrap(WBLT < BMX ? BMX : WBLT),
            fee: 3000, // 0.3%
            tickSpacing: 1, // Must be 1 for V2 pools
            hooks: IHooks(address(deliHookConstantProduct))
        });
        
        // Initialize pools at 1:1 price
        poolManager.initialize(v4PoolKey, TickMath.getSqrtPriceAtTick(0));
        console.log("V4 pool initialized (wBLT/USDC)");
        
        poolManager.initialize(v2PoolKey, TickMath.getSqrtPriceAtTick(0));
        console.log("V2 pool initialized (wBLT/BMX)");
    }
    
    function _performOperations() internal {
        console.log("\n=== Performing Test Operations ===");
        
        // Approve tokens
        _approveTokens();
        
        // V4 Operations
        console.log("\n--- V4 Operations (wBLT/USDC) ---");
        _performV4Operations();
        
        // V2 Operations
        console.log("\n--- V2 Operations (wBLT/BMX) ---");
        _performV2Operations();
    }
    
    function _approveTokens() internal {
        // Approve tokens to Permit2 (all Uniswap V4 contracts use Permit2 for token transfers)
        IERC20(WBLT).approve(address(permit2), type(uint256).max);
        IERC20(BMX).approve(address(permit2), type(uint256).max);
        IERC20(USDC).approve(address(permit2), type(uint256).max);
        
        // Approve PoolManager to spend via Permit2 (it uses Permit2 for token transfers)
        permit2.approve(WBLT, address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(BMX, address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(poolManager), type(uint160).max, type(uint48).max);
        
        // Approve PositionManager to spend via Permit2 (for liquidity operations)
        permit2.approve(WBLT, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(BMX, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(positionManager), type(uint160).max, type(uint48).max);
        
        // Approve Universal Router to spend via Permit2 (for swap operations)
        permit2.approve(WBLT, address(universalRouter), type(uint160).max, type(uint48).max);
        permit2.approve(BMX, address(universalRouter), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(universalRouter), type(uint160).max, type(uint48).max);
        
        // Approve DeliHookConstantProduct for V2 operations (it handles tokens directly)
        IERC20(WBLT).approve(address(deliHookConstantProduct), type(uint256).max);
        IERC20(BMX).approve(address(deliHookConstantProduct), type(uint256).max);
        
        console.log("Token approvals complete");
    }
    
    function _performV4Operations() internal {
        // 1. Mint liquidity
        console.log("1. Minting V4 position with 1 wBLT and 1 USDC...");
        
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(v4PoolKey.toId());
        
        // Determine amounts based on token order
        uint256 amount0 = Currency.unwrap(v4PoolKey.currency0) == WBLT ? 1 ether : 1e6; // 1 USDC = 1e6
        uint256 amount1 = Currency.unwrap(v4PoolKey.currency1) == WBLT ? 1 ether : 1e6; // 1 USDC = 1e6
        
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(-600),
            TickMath.getSqrtPriceAtTick(600),
            amount0,
            amount1
        );
        
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            v4PoolKey,
            -600,
            600,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            msg.sender,
            "" // hookData
        );
        params[1] = abi.encode(v4PoolKey.currency0, v4PoolKey.currency1);
        
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        v4PositionId = positionManager.nextTokenId() - 1;
        console.log("   Position ID:", v4PositionId);
        
        // 2. Test swap - swap USDC for wBLT to avoid fee collection issue
        bool zeroForOne = Currency.unwrap(v4PoolKey.currency0) == USDC;
        // We want to swap USDC->wBLT, so use 0.05 USDC (50000)
        int256 swapAmount = -int256(50000); // 0.05 USDC = 50000 (6 decimals)
        console.log("2. Test swap: swapping 0.05 USDC for wBLT...");
        _swap(v4PoolKey, zeroForOne, swapAmount);
        console.log("   Swap completed");
    }
    
    function _performV2Operations() internal {
        // 1. Add liquidity
        console.log("1. Adding V2 liquidity with 1 wBLT and 1 BMX...");
        
        MultiPoolCustomCurve.AddLiquidityParams memory addParams = MultiPoolCustomCurve.AddLiquidityParams({
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0.9 ether,
            amount1Min: 0.9 ether,
            deadline: block.timestamp + 60,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        });
        
        deliHookConstantProduct.addLiquidity(v2PoolKey, addParams);
        uint256 shares = deliHookConstantProduct.balanceOf(v2PoolKey.toId(), msg.sender);
        console.log("   Shares received:", shares);
        
        // 2. Test swap
        console.log("2. Test swap: 0.05 BMX for wBLT...");
        bool zeroForOne = Currency.unwrap(v2PoolKey.currency0) == BMX;
        _swap(v2PoolKey, zeroForOne, -0.05 ether);
        console.log("   Swap completed");
    }
    
    function _setupIncentives() internal {
        console.log("\n=== Setting up Incentives ===");
        
        // Approve BMX for IncentiveGauge
        IERC20(BMX).approve(address(incentiveGauge), 0.5 ether);
        
        // Create incentives for both pools
        incentiveGauge.createIncentive(v4PoolKey, IERC20(BMX), 0.25 ether);
        console.log("Created 0.25 BMX incentive for V4 pool (wBLT/USDC)");
        
        incentiveGauge.createIncentive(v2PoolKey, IERC20(BMX), 0.25 ether);
        console.log("Created 0.25 BMX incentive for V2 pool (wBLT/BMX)");
    }
    
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        // For V4 swaps via Universal Router
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        
        // Since amountSpecified is negative for exact input, convert to positive
        uint128 amountIn = uint128(uint256(-amountSpecified));
        
        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        
        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        
        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0, // No slippage protection for test
                hookData: bytes("")
            })
        );
        
        // Second parameter: specify input tokens
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        params[1] = abi.encode(inputCurrency, amountIn);
        
        // Third parameter: specify output tokens
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        params[2] = abi.encode(outputCurrency, uint128(0)); // minimum 0 for test
        
        // Combine actions and params
        inputs[0] = abi.encode(actions, params);
        
        // Execute the swap
        universalRouter.execute(commands, inputs, block.timestamp + 60);
    }
    
    function _printSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        
        console.log("\nDeli Protocol Contracts:");
        console.log("  FeeProcessor:", address(feeProcessor));
        console.log("  DeliHook:", address(deliHook));
        console.log("  DeliHookConstantProduct:", address(deliHookConstantProduct));
        console.log("  DailyEpochGauge:", address(dailyEpochGauge));
        console.log("  IncentiveGauge:", address(incentiveGauge));
        console.log("  PositionManagerAdapter:", address(positionManagerAdapter));
        console.log("  V4PositionHandler:", address(v4Handler));
        console.log("  V2PositionHandler:", address(v2Handler));
        
        console.log("\nPools:");
        console.log("  V4 Pool (wBLT/USDC):");
        console.logBytes32(PoolId.unwrap(v4PoolKey.toId()));
        console.log("  V2 Pool (wBLT/BMX):");
        console.logBytes32(PoolId.unwrap(v2PoolKey.toId()));
        
        console.log("\nBase Mainnet deployment complete!");
    }
}