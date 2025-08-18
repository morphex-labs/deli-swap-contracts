// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {EfficientHashLib} from "lib/solady/src/utils/EfficientHashLib.sol";

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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {MockFeeProcessor} from "test/mocks/MockFeeProcessor.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PositionLifecycleCleanup_IT is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                             CONTRACTS
    //////////////////////////////////////////////////////////////*/
    DeliHook hook;
    MockFeeProcessor fp;
    DailyEpochGauge gauge;
    IncentiveGauge inc;
    PositionManagerAdapter adapter;
    V4PositionHandler v4Handler;

    /*//////////////////////////////////////////////////////////////
                               TOKENS
    //////////////////////////////////////////////////////////////*/
    IERC20 wblt;
    IERC20 bmx;
    IERC20 rewardTok; // use wBLT as reward token

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/
    PoolKey key;
    PoolId pid;

    /*//////////////////////////////////////////////////////////////
                                SET-UP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        // 1. Deploy Uniswap-v4 core stack (PoolManager, PositionManager, Permit2, Router)
        deployArtifacts();

        // 2. Deploy two ERC-20 tokens to act as BMX (token0) and wBLT (token1)
        MockERC20 t0 = deployToken();
        MockERC20 t1 = deployToken();
        (MockERC20 bmxToken, MockERC20 wbltToken) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        bmx = IERC20(address(bmxToken));
        wblt = IERC20(address(wbltToken));

        // Grant PoolManager allowance for swap/lp operations
        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);

        // 3. Pre-compute deterministic hook address so the gauge can whitelist it in constructor
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

        // 4. Deploy IncentiveGauge first so DailyEpochGauge constructor can reference it
        inc = new IncentiveGauge(poolManager, IPositionManagerAdapter(address(0)), predictedHook);

        fp = new MockFeeProcessor();

        // Optional: whitelist reward token (wBLT) though currency1 already allowed
        inc.setWhitelist(IERC20(address(wblt)), true);

        // 5. Deploy DailyEpochGauge (feeProcessor set to address(this) for direct addRewards calls)
        gauge = new DailyEpochGauge(
            address(this),
            poolManager,
            IPositionManagerAdapter(address(0)),
            predictedHook,
            IERC20(address(bmx)),
            address(inc)
        );
        // 6. Deploy the hook at the pre-computed address
        hook = new DeliHook{salt: salt}(
            poolManager,
            IFeeProcessor(address(0)),
            IDailyEpochGauge(address(0)),
            IIncentiveGauge(address(0)),
            address(wblt),
            address(bmx),
            address(this)  // owner
        );

        // 7. Wire contracts together
        hook.setFeeProcessor(address(fp));
        hook.setDailyEpochGauge(address(gauge));
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(this)); // just needs to be non-zero & authorised
        // Deploy PositionManagerAdapter and V4PositionHandler
        adapter = new PositionManagerAdapter(address(gauge), address(inc), address(positionManager), address(poolManager));
        v4Handler = new V4PositionHandler(address(positionManager));
        
        // Register V4 handler and wire up the adapter
        adapter.addHandler(address(v4Handler));
        adapter.setAuthorizedCaller(address(positionManager), true);
        
        // Update gauges to use the adapter
        gauge.setPositionManagerAdapter(address(adapter));
        inc.setPositionManagerAdapter(address(adapter));

        // Authorize hook after deployment
        adapter.setAuthorizedCaller(address(hook), true);

        // 8. Prepare reward token allowance for incentive creation
        wblt.approve(address(inc), type(uint256).max);

        // 7. Create canonical BMX/wBLT pool using the hook
        key = PoolKey({
            currency0: Currency.wrap(address(bmx)),
            currency1: Currency.wrap(address(wblt)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        pid = key.toId();

        // Provide minimal liquidity so activeLiquidity > 0 for gauge math
        EasyPosm.mint(
            positionManager,
            key,
            -60000,
            60000,
            1e21,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _activateStream() internal {
        // Fund collect bucket with 1000 BMX and roll epochs so streaming starts
        uint256 bucket = 1000 ether;
        bmx.transfer(address(gauge), bucket);
        gauge.addRewards(PoolId.wrap(PoolId.unwrap(pid)), bucket);

        // Fund IncentiveGauge with 700 wBLT for 7-day stream
        uint256 incAmt = 700 ether;
        wblt.transfer(address(inc), incAmt);
        // Impersonate this contract to create incentive
        vm.prank(address(this));
        inc.createIncentive(key, IERC20(address(wblt)), incAmt);

        // Day 0 info
        uint256 day0End = TimeLibrary.dayNext(block.timestamp);

        // Fast-forward to Day2 so streamRate becomes active (N+2)
        vm.warp(uint256(day0End) + 1 days + 1);

        // Sanity: streamRate should now be > 0
        require(gauge.streamRate(pid) > 0, "stream not active");

        // Fast-forward one hour so incentive lastUpdate diff > 0
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(hook));
        inc.pokePool(key);
    }

    /* helper to compute total pending wBLT in incentive list */
    function _totalPendingInc() internal view returns (uint256 tot) {
        IncentiveGauge.Pending[] memory list = inc.pendingRewardsOwner(pid, address(this));
        for (uint256 i; i < list.length; ++i) {
            tot += list[i].amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            LOCAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mintAndSubscribe(int24 tickLower, int24 tickUpper, uint128 liqAmount) internal returns (uint256 tokenId) {
        (tokenId,) = EasyPosm.mint(
            positionManager,
            key,
            tickLower,
            tickUpper,
            liqAmount,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenId, address(adapter), bytes(""));
    }

    function _addIncentiveTokens(uint256 num) internal {
        for (uint256 i; i < num; ++i) {
            MockERC20 t = new MockERC20(string(abi.encodePacked("INC", i)), string(abi.encodePacked("I", i)), 18);
            t.mint(address(this), 1e24);
            IERC20 it = IERC20(address(t));
            inc.setWhitelist(it, true);
            uint256 amt = 200 ether;
            t.approve(address(inc), amt);
            inc.createIncentive(key, it, amt);
        }
    }

    function _prepareUnsubContext(uint256 tokenId) internal view returns (bytes memory) {
        (PoolKey memory k, PositionInfo info) = adapter.getPoolAndPositionInfo(tokenId);
        PoolId localPid = k.toId();
        uint128 liq = adapter.getPositionLiquidity(tokenId);
        bytes32 pidRaw = bytes32(PoolId.unwrap(localPid));
        bytes32 posKey = EfficientHashLib.hash(bytes32(tokenId), pidRaw);
        return abi.encode(
            posKey,
            pidRaw,
            info.tickLower(),
            info.tickUpper(),
            liq
        );
    }

    function _prepareUnsubArgs(uint256 tokenId)
        internal
        view
        returns (bytes32 posKey, bytes32 pidRaw, int24 lower, int24 upper, uint128 liq)
    {
        (PoolKey memory k, PositionInfo info) = adapter.getPoolAndPositionInfo(tokenId);
        PoolId localPid = k.toId();
        liq = adapter.getPositionLiquidity(tokenId);
        pidRaw = bytes32(PoolId.unwrap(localPid));
        posKey = EfficientHashLib.hash(bytes32(tokenId), pidRaw);
        lower = info.tickLower();
        upper = info.tickUpper();
    }

    function _gasUnsubscribeIncentiveOnly(uint256 numTokens, string memory label) internal {
        uint256 tokenId = _mintAndSubscribe(-1800, 1800, 1e22);
        _activateStream();
        if (numTokens == 3) {
            // Add 3 while base is active (2 active + 1 queued), then expire base and promote queued
            _addIncentiveTokens(3);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 2) {
            // Add two incentives first (one active, one queued), then expire base to promote queued
            _addIncentiveTokens(2);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 1) {
            // Expire base first so exactly one incentive remains active after adding one
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
            _addIncentiveTokens(1);
        } else {
            // numTokens == 0: ensure base expired to isolate daily-only elsewhere
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        }

        // Ensure dt > 0 for IncentiveGauge at unsubscribe
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(hook));
        inc.pokePool(key);
        vm.warp(block.timestamp + 60);

        (bytes32 posKey, bytes32 pidRaw, int24 lower, int24 upper, uint128 liq) = _prepareUnsubArgs(tokenId);

        // Sanity: ensure all incentive tokens are active and have non-zero dt
        {
            IERC20[] memory toks = inc.poolTokensOf(pid);
            uint256 activeCount;
            for (uint256 i; i < toks.length; ++i) {
                (uint256 rate, uint256 fin, ) = inc.incentiveData(pid, toks[i]);
                if (rate > 0 && fin > block.timestamp) {
                    ++activeCount;
                }
            }
            assertEq(activeCount, numTokens, "active incentive token count mismatch (incentive only)");
            // base must be inactive in all incentive-only cases after we expired it
            (uint256 baseRate,,) = inc.incentiveData(pid, wblt);
            assertEq(baseRate, 0, "base token should not be active (incentive only)");
        }

        vm.startPrank(address(adapter));
        vm.startSnapshotGas(label);
        inc.notifyUnsubscribeWithContext(tokenId, posKey, pidRaw, lower, upper, liq);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    function _gasUnsubscribeMultiToken(uint256 numTokens, string memory label) internal {
        uint256 tokenId = _mintAndSubscribe(-1800, 1800, 1e22);
        _activateStream();
        if (numTokens == 3) {
            _addIncentiveTokens(3);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 2) {
            _addIncentiveTokens(2);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 1) {
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
            _addIncentiveTokens(1);
        } else {
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        }
        
        // Ensure dt > 0 for IncentiveGauge at unsubscribe
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(address(hook));
        gauge.pokePool(key);
        inc.pokePool(key);
        vm.stopPrank();
        vm.warp(block.timestamp + 60);

        // Sanity: ensure all incentive tokens are active and have non-zero dt
        {
            IERC20[] memory toks = inc.poolTokensOf(pid);
            uint256 activeCount;
            for (uint256 i; i < toks.length; ++i) {
                (uint256 rate, uint256 fin, ) = inc.incentiveData(pid, toks[i]);
                if (rate > 0 && fin > block.timestamp) {
                    ++activeCount;
                }
            }
            assertEq(activeCount, numTokens, "active incentive token count mismatch (adapter path)");
            (uint256 baseRate,,) = inc.incentiveData(pid, wblt);
            assertEq(baseRate, 0, "base token should not be active (adapter path)");
        }

        vm.startSnapshotGas(label);
        positionManager.unsubscribe(tokenId);
        vm.stopSnapshotGas();
    }

    /*//////////////////////////////////////////////////////////////
                        GAS: unsubscribe with multi-token incentives
    //////////////////////////////////////////////////////////////*/
    function testGasUnsubscribeMultiTokenOne() public {
        _gasUnsubscribeMultiToken(1, "adapter_unsubscribe_notify_multi_1");
    }

    function testGasUnsubscribeMultiTokenTwo() public {
        _gasUnsubscribeMultiToken(2, "adapter_unsubscribe_notify_multi_2");
    }

    function testGasUnsubscribeMultiTokenThree() public {
        _gasUnsubscribeMultiToken(3, "adapter_unsubscribe_notify_multi_3");
    }

    /// Measure IncentiveGauge unsubscribe path only (bypassing Daily) to expose per-token gas sensitivity.
    function testGasUnsubscribeIncentiveOnly() public {
        _gasUnsubscribeIncentiveOnly(2, "incentive_only_unsubscribe_2");
    }

    /// Same as above but with a single extra incentive token to compare gas deltas.
    function testGasUnsubscribeIncentiveOnly_OneToken() public {
        _gasUnsubscribeIncentiveOnly(1, "incentive_only_unsubscribe_1");
    }

    function testGasUnsubscribeIncentiveOnly_ThreeTokens() public {
        _gasUnsubscribeIncentiveOnly(3, "incentive_only_unsubscribe_3");
    }

    /// Measure DailyEpochGauge unsubscribe path only (bypassing Incentive) to expose daily gas cost.
    function testGasUnsubscribeDailyOnly() public {
        uint256 tokenId = _mintAndSubscribe(-1800, 1800, 1e22);
        _activateStream();

        // Ensure dt > 0 for DailyEpochGauge at unsubscribe
        vm.warp(block.timestamp + 1 days);
        vm.warp(block.timestamp + 60);

        (bytes32 posKey, bytes32 pidRaw, int24 lower, int24 upper, uint128 liq) = _prepareUnsubArgs(tokenId);

        vm.startPrank(address(adapter));
        vm.startSnapshotGas("daily_only_unsubscribe_no_poke");
        gauge.notifyUnsubscribeWithContext(tokenId, posKey, pidRaw, lower, upper, liq);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        GAS: adapter segments (daily vs incentive)
    //////////////////////////////////////////////////////////////*/
    function _gasAdapterSegments(uint256 numTokens, string memory labelDaily, string memory labelIncentive) internal {
        uint256 tokenId = _mintAndSubscribe(-1800, 1800, 1e22);
        _activateStream();
        if (numTokens == 3) {
            _addIncentiveTokens(3);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 2) {
            _addIncentiveTokens(2);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 1) {
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
            _addIncentiveTokens(1);
        } else {
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        }

        // Ensure dt > 0 for unsubscribe
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(address(hook));
        gauge.pokePool(key);
        inc.pokePool(key);
        vm.stopPrank();
        vm.warp(block.timestamp + 60);

        // Prepare shared args via adapter
        (bytes32 posKey, bytes32 pidRaw, int24 lower, int24 upper, uint128 liq) = _prepareUnsubArgs(tokenId);

        // Sanity: ensure all incentive tokens are active
        {
            IERC20[] memory toks = inc.poolTokensOf(pid);
            uint256 activeCount;
            for (uint256 i; i < toks.length; ++i) {
                (uint256 rate, uint256 fin, ) = inc.incentiveData(pid, toks[i]);
                if (rate > 0 && fin > block.timestamp) {
                    ++activeCount;
                }
            }
            assertEq(activeCount, numTokens, "active incentive token count mismatch (adapter segments)");
            (uint256 baseRate,,) = inc.incentiveData(pid, wblt);
            assertEq(baseRate, 0, "base token should not be active (adapter segments)");
        }

        // Measure daily segment
        vm.startPrank(address(adapter));
        vm.startSnapshotGas(labelDaily);
        gauge.notifyUnsubscribeWithContext(tokenId, posKey, pidRaw, lower, upper, liq);
        vm.stopSnapshotGas();
        vm.stopPrank();

        // Reconstruct context (unchanged) and measure incentive segment
        vm.startPrank(address(adapter));
        vm.startSnapshotGas(labelIncentive);
        inc.notifyUnsubscribeWithContext(tokenId, posKey, pidRaw, lower, upper, liq);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    function testGasAdapterSegmentsOne() public {
        _gasAdapterSegments(1, "adapter_segments_daily_1", "adapter_segments_incentive_1");
    }

    function testGasAdapterSegmentsTwo() public {
        _gasAdapterSegments(2, "adapter_segments_daily_2", "adapter_segments_incentive_2");
    }

    function testGasAdapterSegmentsThree() public {
        _gasAdapterSegments(3, "adapter_segments_daily_3", "adapter_segments_incentive_3");
    }

    /*//////////////////////////////////////////////////////////////
                        GAS: adapter.notifyUnsubscribe direct
    //////////////////////////////////////////////////////////////*/
    function _gasAdapterNotifyUnsub(uint256 numTokens, string memory label) internal {
        uint256 tokenId = _mintAndSubscribe(-1800, 1800, 1e22);
        _activateStream();
        if (numTokens == 3) {
            _addIncentiveTokens(3);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 2) {
            _addIncentiveTokens(2);
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        } else if (numTokens == 1) {
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
            _addIncentiveTokens(1);
        } else {
            (, uint256 finish, ) = inc.incentiveData(pid, wblt);
            if (finish > block.timestamp) vm.warp(finish + 1);
            vm.prank(address(hook));
            inc.pokePool(key);
        }

        // Ensure dt > 0 for IncentiveGauge/DailyEpochGauge at unsubscribe
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(address(hook));
        inc.pokePool(key);
        gauge.pokePool(key);
        vm.stopPrank();
        vm.warp(block.timestamp + 60);

        // Sanity: ensure all incentive tokens are active
        {
            IERC20[] memory toks = inc.poolTokensOf(pid);
            uint256 activeCount;
            for (uint256 i; i < toks.length; ++i) {
                (uint256 rate, uint256 fin, ) = inc.incentiveData(pid, toks[i]);
                if (rate > 0 && fin > block.timestamp) {
                    ++activeCount;
                }
            }
            assertEq(activeCount, numTokens, "active incentive token count mismatch (adapter notify)");
            (uint256 baseRate,,) = inc.incentiveData(pid, wblt);
            assertEq(baseRate, 0, "base token should not be active (adapter notify)");
        }

        vm.startPrank(address(positionManager));
        vm.startSnapshotGas(label);
        adapter.notifyUnsubscribe(tokenId);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    function testGasAdapterNotifyUnsubOne() public {
        _gasAdapterNotifyUnsub(1, "adapter_notify_unsub_1");
    }

    function testGasAdapterNotifyUnsubTwo() public {
        _gasAdapterNotifyUnsub(2, "adapter_notify_unsub_2");
    }

    function testGasAdapterNotifyUnsubThree() public {
        _gasAdapterNotifyUnsub(3, "adapter_notify_unsub_3");
    }

    /// Worst-case parameters for unsubscribe gas: two extra incentive tokens (plus base wBLT from _activateStream),
    /// large elapsed time without prior syncs to force Daily's multi-day integration and maximize cold reads.
    /// to force Daily's multi-day integration during unsubscribe and maximize cold reads.
    function testGasAdapterNotifyUnsubTwoWorst() public {
        // 1) Mint and subscribe
        uint256 tokenId = _mintAndSubscribe(-1800, 1800, 1e22);

        // 2) Activate Daily stream and base incentive, then add two extra incentive tokens (3 total incentives)
        _activateStream();
        _addIncentiveTokens(3);

        // 3) Warp many days ahead to force DailyEpochGauge._amountOverWindow to iterate across many day boundaries
        //    and ensure significant elapsed time for incentive calculations, without additional pokes.
        vm.warp(block.timestamp + 6 days);

        // 4) Measure only the adapter.notifyUnsubscribe path
        vm.startPrank(address(positionManager));
        vm.startSnapshotGas("adapter_notify_unsub_3_worst");
        adapter.notifyUnsubscribe(tokenId);
        vm.stopSnapshotGas();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    TEST: unsubscribe cleans indices
    //////////////////////////////////////////////////////////////*/
    function testUnsubscribeCleansOwnerIndices() public {
        // 1. Mint a position and subscribe to the gauge
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(
            positionManager,
            key,
            -1200,
            1200,
            1e22,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        // 2. Activate daily stream and accrue some rewards
        _activateStream();
        // move 6 hours into streaming day and update pool accumulator
        vm.warp(block.timestamp + 6 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // 3. Ensure owner has pending rewards > 0
        uint256 pendingBefore = gauge.pendingRewardsOwner(pid, address(this));
        assertGt(pendingBefore, 0, "no pending before unsubscribe");

        // 4. Unsubscribe position – should trigger accumulator accrual & removal
        // Capture gas for the unsubscribe path (adapter.notifyUnsubscribe) via section snapshot
        vm.startSnapshotGas("adapter_unsubscribe_notify");
        positionManager.unsubscribe(tokenId);
        vm.stopSnapshotGas();

        // 5. After unsubscribe owner aggregate should be zero (index cleaned)
        uint256 pendingAfter = gauge.pendingRewardsOwner(pid, address(this));
        // With deferred claims, pending should still exist immediately after unsubscribe
        assertGt(pendingAfter, 0, "no pending after unsubscribe");

        // Claim should now transfer BMX and prune indices
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 balBefore = bmx.balanceOf(address(this));
        gauge.claimAllForOwner(arr, address(this));
        uint256 balAfter = bmx.balanceOf(address(this));
        assertGt(balAfter - balBefore, 0, "expected BMX claimed after deferred unsubscribe");
        // Pending should now be zero and indices pruned
        assertEq(gauge.pendingRewardsOwner(pid, address(this)), 0, "pending not cleaned after claim");
    }

    /*//////////////////////////////////////////////////////////////
                    TEST: burn cleans indices
    //////////////////////////////////////////////////////////////*/
    function testBurnCleansOwnerIndices() public {
        // 1. Mint a second position (narrow range) and subscribe
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(
            positionManager,
            key,
            -300,
            300,
            1e22,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        // 2. Activate stream and accrue some rewards
        _activateStream();
        
        vm.warp(block.timestamp + 4 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // 3. Confirm pending > 0 pre-burn
        uint256 pendingBefore = gauge.pendingRewardsOwner(pid, address(this));
        assertGt(pendingBefore, 0, "no pending before burn");

        // 4. Burn the position – this triggers gauge.notifyBurn and cleanup
        EasyPosm.burn(
            positionManager,
            tokenId,
            0,
            0,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );

        // 5. Verify owner aggregate pending is now zero
        uint256 pendingAfter = gauge.pendingRewardsOwner(pid, address(this));
        assertEq(pendingAfter, 0, "owner index not cleaned after burn");
    }

    /*//////////////////////////////////////////////////////////////
                    TEST: zero-liquidity cleans indices
    //////////////////////////////////////////////////////////////*/
    function testDecreaseLiquidityZeroCleansOwnerIndices() public {
        // 1. Mint position and subscribe
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(
            positionManager,
            key,
            -900,
            900,
            1e22,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        // 2. Activate stream and accrue some rewards
        _activateStream();
        
        vm.warp(block.timestamp + 3 hours);
        vm.prank(address(hook));
        gauge.pokePool(key);

        // 3. Ensure pending rewards > 0 before liquidity removal
        uint256 pendingBefore = gauge.pendingRewardsOwner(pid, address(this));
        assertGt(pendingBefore, 0, "no pending before zero-out");

        // 4. Fetch current liquidity and decrease the full amount (sets liquidity to zero)
        uint128 liq = positionManager.getPositionLiquidity(tokenId);
        assertGt(liq, 0, "liquidity already zero");
        EasyPosm.decreaseLiquidity(
            positionManager,
            tokenId,
            uint256(liq),
            0,
            0,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );

        // 5. Position liquidity should now be zero
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "liq not zero");

        // With deferred cleanup, pending may remain until claim; verify > 0 then claim to clean
        uint256 pendingAfter = gauge.pendingRewardsOwner(pid, address(this));
        assertGt(pendingAfter, 0, "unexpected zero pending after zero-liq before claim");

        // Claim should transfer all and then pending becomes zero
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 balBefore = bmx.balanceOf(address(this));
        gauge.claimAllForOwner(arr, address(this));
        uint256 balAfter = bmx.balanceOf(address(this));
        assertGt(balAfter - balBefore, 0, "expected claim after zero-liq");
        assertEq(gauge.pendingRewardsOwner(pid, address(this)), 0, "pending not cleaned after claim");
    }

    /*//////////////////////////////////////////////////////////////
                   INCENTIVE GAUGE PARITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testIncUnsubscribeCleansOwnerIndices() public {
        // Mint and subscribe
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(positionManager, key, -1800, 1800, 1e22, type(uint256).max, type(uint256).max, address(this), block.timestamp + 1 hours, bytes(""));
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        _activateStream();
        vm.prank(address(hook));
        inc.pokePool(key);

        uint256 pendingBefore = _totalPendingInc();
        assertGt(pendingBefore, 0, "no inc pending before unsubscribe");

        positionManager.unsubscribe(tokenId);

        // Deferred claims: still pending until claimed
        uint256 pendingAfter = _totalPendingInc();
        assertGt(pendingAfter, 0, "inc pending unexpectedly zero after unsubscribe");

        // Claim and expect payout, then cleanup
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 balBefore = wblt.balanceOf(address(this));
        inc.claimAllForOwner(arr, address(this));
        assertGt(wblt.balanceOf(address(this)) - balBefore, 0, "no inc payout after claim");
        assertEq(_totalPendingInc(), 0, "inc pending not zero after claim");
    }

    function testIncBurnCleansOwnerIndices() public {
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(positionManager, key, -2400, 2400, 1e22, type(uint256).max, type(uint256).max, address(this), block.timestamp + 1 hours, bytes(""));
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        _activateStream();
        vm.prank(address(hook));
        inc.pokePool(key);

        uint256 beforePend = _totalPendingInc();
        assertGt(beforePend, 0, "no inc pending before burn");

        EasyPosm.burn(positionManager, tokenId, 0, 0, address(this), block.timestamp + 1 hours, bytes(""));

        uint256 afterPend = _totalPendingInc();
        assertEq(afterPend, 0, "inc index not cleaned burn");
    }

    function testIncZeroLiquidityCleansOwnerIndices() public {
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(positionManager, key, -3000, 3000, 1e22, type(uint256).max, type(uint256).max, address(this), block.timestamp + 1 hours, bytes(""));
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        _activateStream();
        vm.prank(address(hook));
        inc.pokePool(key);

        uint256 beforePend = _totalPendingInc();
        assertGt(beforePend, 0, "no inc pending before zero-liq");

        uint128 liq = positionManager.getPositionLiquidity(tokenId);
        EasyPosm.decreaseLiquidity(positionManager, tokenId, uint256(liq), 0, 0, address(this), block.timestamp + 1 hours, bytes(""));

        uint256 afterPend = _totalPendingInc();
        // With deferred cleanup, pending remains until claim
        assertGt(afterPend, 0, "inc pending unexpectedly zero after zero-liq");
        // Claim to clean
        PoolId[] memory arr2 = new PoolId[](1);
        arr2[0] = pid;
        uint256 incBalBefore = wblt.balanceOf(address(this));
        inc.claimAllForOwner(arr2, address(this));
        assertGt(wblt.balanceOf(address(this)) - incBalBefore, 0, "no inc payout after zero-liq claim");
        assertEq(_totalPendingInc(), 0, "inc pending not zero after claim");
    }

    /*//////////////////////////////////////////////////////////////
                       FUZZ / INVARIANT STYLE
    //////////////////////////////////////////////////////////////*/

    function testFuzzIncCleanup(uint128 amt) public {
        amt = uint128(bound(amt, 1e20, 1e25)); // between ~100 and large

        // random ticks derived from amt
        int24 tl = int24(int256(uint256(amt % 5000)));
        tl -= 2500; // roughly within [-2500,2500]
        tl = tl / 60 * 60; // align to 60
        int24 tu = tl + 60;

        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(positionManager, key, tl, tu, 1e22, type(uint256).max, type(uint256).max, address(this), block.timestamp + 1 hours, bytes(""));
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        _activateStream();
        vm.prank(address(hook));
        inc.pokePool(key);

        uint256 choose = uint256(amt) % 3;
        if (choose == 0) {
            positionManager.unsubscribe(tokenId);
        } else if (choose == 1) {
            EasyPosm.burn(positionManager, tokenId, 0, 0, address(this), block.timestamp + 1 hours, bytes(""));
        } else {
            uint128 liq = positionManager.getPositionLiquidity(tokenId);
            EasyPosm.decreaseLiquidity(positionManager, tokenId, uint256(liq), 0, 0, address(this), block.timestamp + 1 hours, bytes(""));
        }
        // After action, claim to finalize and prune if needed
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        inc.claimAllForOwner(arr, address(this));
        assertEq(_totalPendingInc(), 0, "inc pending not zero after cleanup");
    }
} 