// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

// Uniswap
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// Tokens
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Deli Swap contracts
import {FeeProcessor} from "src/FeeProcessor.sol";
import {DeliHook} from "src/DeliHook.sol";
import {DeliHookConstantProduct} from "src/DeliHookConstantProduct.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";

/// @notice Migration script: Deploy fixed IncentiveGauge and a fresh DailyEpochGauge, deploy a new FeeProcessor
///         wired to the new DailyEpochGauge, and reconfigure hooks + adapter to point to the new gauges.
contract MigrateGauges is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant WBLT = 0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A;
    address constant BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;

    address constant HOOK_V4 = 0xC384B99A6e5cD1a800B2d83aB71BaB7bD712b0cc;
    address constant HOOK_V2 = 0x00C9DA9AbC5303219ead3Cf0307b5A8A7644BaC8;
    address constant POSITION_MANAGER_ADAPTER = 0xac4E7dD1f9B5A1899068314d4508df3DDB60072C;

    // Newly deployed contracts
    IncentiveGauge public incentiveGauge;
    DailyEpochGauge public dailyEpochGauge;
    FeeProcessor public feeProcessor;

    function run() public {
        vm.startBroadcast();

        // 1) Deploy new IncentiveGauge (authorize V4 hook in constructor, V2 hook via setter)
        incentiveGauge = new IncentiveGauge(IPoolManager(POOL_MANAGER), IPositionManagerAdapter(address(0)), HOOK_V4);
        incentiveGauge.setHook(HOOK_V2, true);

        // Whitelist BMX for incentives
        incentiveGauge.setWhitelist(IERC20(BMX), true);

        // 2) Deploy new DailyEpochGauge (feeProcessor set after deployment; wire to inc gauge now)
        dailyEpochGauge = new DailyEpochGauge(
            address(0), // feeProcessor will be set later
            IPoolManager(POOL_MANAGER),
            IPositionManagerAdapter(address(0)),
            HOOK_V4,
            IERC20(BMX),
            address(incentiveGauge)
        );
        dailyEpochGauge.setHook(HOOK_V2, true);

        // 3) Deploy a new FeeProcessor wired to the new DailyEpochGauge
        feeProcessor =
            new FeeProcessor(IPoolManager(POOL_MANAGER), HOOK_V4, WBLT, BMX, IDailyEpochGauge(address(dailyEpochGauge)));
        // Authorize both hooks on the new FeeProcessor
        feeProcessor.setHook(HOOK_V4, true);
        feeProcessor.setHook(HOOK_V2, true);

        // 4) Wire gauges with adapter + fee processor
        dailyEpochGauge.setFeeProcessor(address(feeProcessor));
        dailyEpochGauge.setPositionManagerAdapter(POSITION_MANAGER_ADAPTER);
        incentiveGauge.setPositionManagerAdapter(POSITION_MANAGER_ADAPTER);

        // 5) Retarget hooks to the new FeeProcessor and Gauges
        DeliHook(HOOK_V4).setFeeProcessor(address(feeProcessor));
        DeliHook(HOOK_V4).setDailyEpochGauge(address(dailyEpochGauge));
        DeliHook(HOOK_V4).setIncentiveGauge(address(incentiveGauge));

        DeliHookConstantProduct(HOOK_V2).setFeeProcessor(address(feeProcessor));
        DeliHookConstantProduct(HOOK_V2).setDailyEpochGauge(address(dailyEpochGauge));
        DeliHookConstantProduct(HOOK_V2).setIncentiveGauge(address(incentiveGauge));

        // 6) Retarget adapter to the new gauges
        PositionManagerAdapter(POSITION_MANAGER_ADAPTER).setGauges(address(dailyEpochGauge), address(incentiveGauge));

        vm.stopBroadcast();

        _printSummary();
    }

    function _printSummary() internal view {
        console.log("\n=== MIGRATION SUMMARY ===");
        console.log("PoolManager:", POOL_MANAGER);
        console.log("PositionManager:", POSITION_MANAGER);
        console.log("V4 Hook:", HOOK_V4);
        console.log("V2 Hook:", HOOK_V2);
        console.log("Adapter:", POSITION_MANAGER_ADAPTER);
        console.log("WBLT:", WBLT);
        console.log("BMX:", BMX);

        console.log("\nDeployed:");
        console.log("  IncentiveGauge:", address(incentiveGauge));
        console.log("  DailyEpochGauge:", address(dailyEpochGauge));
        console.log("  FeeProcessor:", address(feeProcessor));
    }
}
