// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeliHook} from "src/DeliHook.sol";
import {IncentiveGauge} from "src/IncentiveGauge.sol";
import {DailyEpochGauge} from "src/DailyEpochGauge.sol";
import {PositionManagerAdapter} from "src/PositionManagerAdapter.sol";
import {V4PositionHandler} from "src/handlers/V4PositionHandler.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IDailyEpochGauge} from "src/interfaces/IDailyEpochGauge.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {MockFeeProcessor} from "test/mocks/MockFeeProcessor.sol";

contract IncentiveGauge_OvershootRepro_IT is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // Core
    DeliHook hook;
    IncentiveGauge inc;
    DailyEpochGauge daily;
    MockFeeProcessor fp;
    PositionManagerAdapter adapter;
    V4PositionHandler v4Handler;

    // Tokens
    IERC20 wblt;
    IERC20 bmx;

    // Pool
    PoolKey key;
    PoolId pid;

    function setUp() public {
        // Core stack
        deployArtifacts();

        // Tokens (order BMX < wBLT)
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(bmxToken));
        wblt = IERC20(address(wbltToken));

        // Approvals to PoolManager
        bmxToken.approve(address(poolManager), type(uint256).max);
        wbltToken.approve(address(poolManager), type(uint256).max);

        // Predict hook address for constructor wiring
        bytes memory ctorArgs = abi.encode(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wbltToken),
            address(bmxToken),
            address(this)
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);

        // Deploy gauges
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), predicted);
        daily = new DailyEpochGauge(address(this), poolManager, IPositionManagerAdapter(address(0)), predicted, bmx, address(inc));
        fp = new MockFeeProcessor();

        // Hook
        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wbltToken),
            address(bmxToken),
            address(this)
        );

        // Wire
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(daily));
        hook.setIncentiveGauge(address(inc));
        daily.setFeeProcessor(address(this));
        adapter = new PositionManagerAdapter(address(daily), address(inc), address(positionManager), address(poolManager));
        v4Handler = new V4PositionHandler(address(positionManager));
        adapter.addHandler(address(v4Handler));
        adapter.setAuthorizedCaller(address(positionManager), true);
        adapter.setAuthorizedCaller(address(hook), true);
        daily.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));

        // Whitelist BMX as incentive token
        inc.setWhitelist(bmx, true);

        // Create pool
        key = PoolKey({
            currency0: Currency.wrap(address(bmxToken)),
            currency1: Currency.wrap(address(wbltToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        pid = key.toId();

        // Bootstrap minimal liquidity so pool is active
        EasyPosm.mint(positionManager, key, -60000, 60000, 1e21, type(uint256).max, type(uint256).max, address(this),
            block.timestamp + 1 hours, bytes(""));
    }

    /// @notice Attempts to reproduce pending > balance then revert on claim for a second position
    function test_Repro_PendingExceedsBalance_CanRevertOnSecondClaim() public {
        // Exact full-range ticks used on mainnet
        int24 fullLow = -887220;
        int24 fullHigh = 887220;

        // Track positions
        uint256 posA; // created 23h ago, subscribed immediately
        uint256 posB; // created 11d ago, subscribed 10d ago (initial liquidity)

        // t(-11d): Create posB (initial liquidity) but do not subscribe yet
        (posB,) = EasyPosm.mint(
            positionManager, key, fullLow, fullHigh, 1398803570097, type(uint256).max, type(uint256).max, address(this),
            block.timestamp + 1 hours, bytes("")
        );

        // Fund and register incentives over staggered times (mainnet-like timeline)
        MockERC20(address(bmx)).approve(address(inc), type(uint256).max);
        MockERC20(address(wblt)).approve(address(inc), type(uint256).max);

        // t0 + 18h25m: 0.01290763 BMX (Oct-25-2025 10:44:09 UTC)
        vm.warp(block.timestamp + 18 hours + 25 minutes);
        inc.createIncentive(key, bmx, 12907630000000000); // ~0.01290763

        // +7m34s: 0.092741 wBLT (Oct-25-2025 10:51:43 UTC)
        vm.warp(block.timestamp + 7 minutes + 34 seconds);
        inc.createIncentive(key, wblt, 92741000000000000); // ~0.092741
        
        // +22m16s: 0.2 BMX (Oct-25-2025 11:13:59 UTC)
        vm.warp(block.timestamp + 22 minutes + 16 seconds);
        inc.createIncentive(key, bmx, 200000000000000000); // 0.2
        
        // +2h22m02s: Subscribe posB (Oct-25-2025 13:36:01 UTC)
        vm.warp(block.timestamp + 2 hours + 22 minutes + 2 seconds);
        positionManager.subscribe(posB, address(adapter), bytes(""));

        // +49m10s: first swap → poke (Oct-25-2025 14:25:11 UTC)
        vm.warp(block.timestamp + 49 minutes + 10 seconds);
        vm.prank(address(hook));
        inc.pokePool(key);
        // +10m56s: second swap → poke (Oct-25-2025 14:36:07 UTC)
        vm.warp(block.timestamp + 10 minutes + 56 seconds);
        vm.prank(address(hook));
        inc.pokePool(key);

        // +8d57m30s: 0.01 BMX (Nov-02-2025 15:33:37 UTC)
        vm.warp(block.timestamp + 8 days + 57 minutes + 30 seconds);
        inc.createIncentive(key, bmx, 10000000000000000); // 0.01

        // +1d21h53m12s: create posA full-range and subscribe immediately (Nov-04-2025 13:26:49 UTC)
        vm.warp(block.timestamp + 1 days + 21 hours + 53 minutes + 12 seconds);
        (posA,) = EasyPosm.mint(
            positionManager, key, fullLow, fullHigh, 106412717322, type(uint256).max, type(uint256).max, address(this),
            block.timestamp + 1 hours, bytes("")
        );
        positionManager.subscribe(posA, address(adapter), bytes(""));

        // Emulate last 22h..17h burst of add/remove events (adapter-driven syncs)
        {
            // 22h ago: multiple Adds (mirror mainnet sequence ~10 adds + one tiny add)
            vm.warp(block.timestamp + 1 hours); // from 23h ago -> 22h ago
            uint256[] memory tempAdds = new uint256[](12);
            for (uint256 i; i < 9; ++i) {
                (uint256 tid,) = EasyPosm.mint(
                    positionManager, key, -1800, 1800, 1e20, type(uint256).max, type(uint256).max, address(this),
                    block.timestamp + 1 hours, bytes("")
                );
                tempAdds[i] = tid; // not subscribed on purpose
            }
            // 22h: tiny add ~0.01 WBLT
            (uint256 tidTiny,) = EasyPosm.mint(
                positionManager, key, -1800, 1800, 1e19, type(uint256).max, type(uint256).max, address(this),
                block.timestamp + 1 hours, bytes("")
            );
            tempAdds[9] = tidTiny;
            // 22h: one more standard add
            (uint256 tid9,) = EasyPosm.mint(
                positionManager, key, -1800, 1800, 1e20, type(uint256).max, type(uint256).max, address(this),
                block.timestamp + 1 hours, bytes("")
            );
            tempAdds[10] = tid9;

            // 21h: single Add
            vm.warp(block.timestamp + 1 hours);
            (uint256 tid21h,) = EasyPosm.mint(
                positionManager, key, -1800, 1800, 1e20, type(uint256).max, type(uint256).max, address(this),
                block.timestamp + 1 hours, bytes("")
            );
            tempAdds[11] = tid21h;

            // 18h: Removes and a large Add
            vm.warp(block.timestamp + 3 hours);
            // Removes on a subset (approximate sizes)
            for (uint256 i; i < 2; ++i) {
                uint128 liq = positionManager.getPositionLiquidity(tempAdds[i]);
                if (liq > 0) {
                    EasyPosm.decreaseLiquidity(
                        positionManager, tempAdds[i], uint256(liq), 0, 0, address(this), block.timestamp + 1 hours,
                        bytes("")
                    );
                }
            }
            // One more remove
            {
                uint128 liq = positionManager.getPositionLiquidity(tempAdds[2]);
                if (liq > 0) {
                    EasyPosm.decreaseLiquidity(
                        positionManager, tempAdds[2], uint256(liq), 0, 0, address(this), block.timestamp + 1 hours,
                        bytes("")
                    );
                }
            }
            // 18h: Large Add (~$1.48)
            EasyPosm.mint(
                positionManager, key, -1800, 1800, 15e20, type(uint256).max, type(uint256).max, address(this),
                block.timestamp + 1 hours, bytes("")
            );
            // not subscribed

            // 17h: Add, Remove, Add (approx $0.234, then full remove, then smaller add)
            vm.warp(block.timestamp + 1 hours);
            (uint256 tidA,) = EasyPosm.mint(
                positionManager, key, -1800, 1800, 234e18, type(uint256).max, type(uint256).max, address(this),
                block.timestamp + 1 hours, bytes("")
            );
            uint128 liqA = positionManager.getPositionLiquidity(tidA);
            EasyPosm.decreaseLiquidity(
                positionManager, tidA, uint256(liqA), 0, 0, address(this), block.timestamp + 1 hours, bytes("")
            );
            EasyPosm.mint(
                positionManager, key, -1800, 1800, 6e19, type(uint256).max, type(uint256).max, address(this),
                block.timestamp + 1 hours, bytes("")
            );
        }

        // +5h18m24s from the last add/remove block → first claim (Nov-04-2025 23:45:13 UTC)
        vm.warp(block.timestamp + 5 hours + 18 minutes + 24 seconds);
        uint256 preBalA = MockERC20(address(bmx)).balanceOf(address(this));
        // Claim happens 11h ago
        try inc.claim(posA, bmx, address(this)) {
            // ok
        } catch {
            // ignore if it reverts; we only need to proceed to the second claim
        }
        uint256 claimedA = MockERC20(address(bmx)).balanceOf(address(this)) - preBalA;
        console2.log("PosA BMX claimed (11h ago):", claimedA);

        // +1h08m08s: third poke triggered by the last swap on mainnet (Nov-05-2025 00:53:21 UTC)
        vm.warp(block.timestamp + 1 hours + 8 minutes + 8 seconds);
        vm.prank(address(hook));
        inc.pokePool(key);

        // Compute pending for posB and current gauge BMX balance
        uint256 pendingB = inc.pendingRewardsByTokenId(posB, bmx);
        uint256 balGauge = MockERC20(address(bmx)).balanceOf(address(inc));
        console2.log("Gauge BMX balance:", balGauge);
        console2.log("PosB BMX pending:", pendingB);

        // Post-fix expectation: pending should never exceed balance; claim must succeed
        assertLe(pendingB, balGauge, "pending must be <= gauge balance after fix");
        try inc.claim(posB, bmx, address(this)) {
            console2.log("Claimed PosB BMX");
        } catch {
            assertTrue(false, "Unexpected revert on second claim after fix");
        }
    }
}


