// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
            fee: 3000,
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
                        GAS: unsubscribe with multi-token incentives
    //////////////////////////////////////////////////////////////*/
    function testGasUnsubscribeMultiToken() public {
        // 1) Mint a fresh position and subscribe
        uint256 tokenId;
        (tokenId,) = EasyPosm.mint(
            positionManager,
            key,
            -1800,
            1800,
            1e22,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1 hours,
            bytes("")
        );
        positionManager.subscribe(tokenId, address(adapter), bytes(""));

        // 2) Activate daily stream and baseline incentive
        _activateStream();

        // 3) Add multiple concurrent incentive tokens
        uint256 NUM = 10;
        for (uint256 i; i < NUM; ++i) {
            MockERC20 t = new MockERC20(string(abi.encodePacked("INC", i)), string(abi.encodePacked("I", i)), 18);
            t.mint(address(this), 1e24);
            IERC20 it = IERC20(address(t));
            inc.setWhitelist(it, true);
            uint256 amt = 200 ether;
            t.approve(address(inc), amt);
            inc.createIncentive(key, it, amt);
        }

        // 4) Move some time forward and poke so accumulators reflect incentives
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(hook));
        inc.pokePool(key);

        // 5) Snapshot gas specifically for unsubscribe path (adapter.notifyUnsubscribe)
        vm.startSnapshotGas("adapter_unsubscribe_notify_multi");
        positionManager.unsubscribe(tokenId);
        vm.stopSnapshotGas();
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

        // 5. Position liquidity should now be zero and owner index cleaned
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "liq not zero");

        uint256 pendingAfter = gauge.pendingRewardsOwner(pid, address(this));
        assertEq(pendingAfter, 0, "owner index not cleaned after zero-liq");

        // Claim should transfer nothing
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        uint256 balBefore = bmx.balanceOf(address(this));
        gauge.claimAllForOwner(arr, address(this));
        uint256 balAfter = bmx.balanceOf(address(this));
        assertEq(balAfter - balBefore, 0, "unexpected claim after zero-liq");
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
        assertEq(afterPend, 0, "inc index not cleaned zero-liq");
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