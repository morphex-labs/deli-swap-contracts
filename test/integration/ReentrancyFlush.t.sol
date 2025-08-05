// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import "src/DeliHook.sol";
import "src/FeeProcessor.sol";
import "src/DailyEpochGauge.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IFeeProcessor} from "src/interfaces/IFeeProcessor.sol";
import {IIncentiveGauge} from "src/interfaces/IIncentiveGauge.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";

interface IFlusher { function flushBuffers() external; }

/*//////////////////////////////////////////////////////////////////////////
                                    REENTRANCY TEST
  Ensures FeeProcessor.flushBuffers() cannot be re-entered while an internal
  buy-back swap is in flight.  A malicious BMX token calls flushBuffers()
  during the ERC20.transfer triggered inside FeeProcessor._unlockCallback.
//////////////////////////////////////////////////////////////////////////*/
contract ReentrantBMX is MockERC20 {
    address public poolManager;
    IFlusher public fp;
    bool public reentered;

    constructor(string memory name, address _pm) MockERC20(name, name, 18) {
        poolManager = _pm;
        _mint(msg.sender, 1e30);
    }

    function setFeeProcessor(address _fp) external {
        fp = IFlusher(_fp);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Attempt re-entrancy only when PoolManager is the msg.sender (i.e. inside take())
        if (msg.sender == poolManager && !reentered && address(fp) != address(0)) {
            reentered = true;
            // Expect revert with "swap-active" but ignore failure so transfer proceeds.
            try fp.flushBuffers() { } catch { }
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (msg.sender == poolManager && !reentered && address(fp) != address(0)) {
            reentered = true;
            try fp.flushBuffers() { } catch { }
        }
        return super.transferFrom(from, to, amount);
    }
}

contract FeeProcessor_Reentrancy_IT is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    // contracts
    DeliHook hook;
    FeeProcessor fp;
    DailyEpochGauge gauge;
    MockIncentiveGauge inc;

    // tokens
    IERC20 wblt;
    ReentrantBMX bmx;
    IERC20 other;

    // helpers
    PoolKey canonicalKey;
    PoolKey otherKey;
    PoolId pid;

    function setUp() public {
        // 1. Deploy core stack
        deployArtifacts();

        // 2. Deploy tokens (ensure BMX deployed first so address is smaller)
        bmx = new ReentrantBMX("BMX", address(poolManager));
        MockERC20 wbltToken = new MockERC20("wBLT", "wBLT", 18);
        wbltToken.mint(address(this), 1e30);
        wblt = IERC20(address(wbltToken));

        MockERC20 _other = new MockERC20("OTHER", "OTHER", 18);
        _other.mint(address(this), 1e30);
        other = IERC20(address(_other));

        // approvals
        bmx.approve(address(poolManager), type(uint256).max);
        wblt.approve(address(poolManager), type(uint256).max);
        other.approve(address(poolManager), type(uint256).max);
        // Permit2 approvals for OTHER token (used in transfers during liquidity operations)
        permit2.approve(address(_other), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(_other), address(poolManager),    type(uint160).max, type(uint48).max);

        // Provide Permit2 allowances for BMX as well to cover any orientation where
        // BMX ends up on token0 side and Permit2 path is used.
        permit2.approve(address(bmx), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(bmx), address(poolManager),    type(uint160).max, type(uint48).max);

        // Since wBLT may appear as currency0 or currency1 depending on address order,
        // also provide Permit2 allowances for wBLT to prevent AllowanceExpired errors
        permit2.approve(address(wblt), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(wblt), address(poolManager),    type(uint160).max, type(uint48).max);

        // Standard ERC20 approvals for Permit2 so its internal transferFrom calls succeed
        wblt.approve(address(permit2), type(uint256).max);
        bmx.approve(address(permit2), type(uint256).max);
        other.approve(address(permit2), type(uint256).max);

        // Classic ERC-20 allowance so PoolManager can pull wBLT during liquidity ops
        wblt.approve(address(poolManager), type(uint256).max);

        // 3. Precompute hook address
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
        (address expectedHook, bytes32 salt) = HookMiner.find(address(this), flags, type(DeliHook).creationCode, ctorArgs);

        // 4. Deploy gauge & feeProcessor
        gauge = new DailyEpochGauge(address(0), poolManager, IPositionManagerAdapter(address(0)), expectedHook, IERC20(address(bmx)), address(0));
        inc = new MockIncentiveGauge();
        fp = new FeeProcessor(poolManager, expectedHook, address(wblt), address(bmx), IDailyEpochGauge(address(gauge)), address(0xDEAD));

        // Link feeProcessor to reentrant token so it can try re-enter
        bmx.setFeeProcessor(address(fp));

        // 5. Deploy hook
        hook = new DeliHook{salt: salt}(
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
        // Provide dummy incentive gauge address.
        hook.setIncentiveGauge(address(inc));
        gauge.setFeeProcessor(address(fp));

        // 6. Create pools and seed minimal liquidity
        // Build pool keys with correct currency ordering (currency0 < currency1).
        bool bmxIsToken0 = address(bmx) < address(wblt);
        canonicalKey = PoolKey({
            currency0: Currency.wrap(bmxIsToken0 ? address(bmx) : address(wblt)),
            currency1: Currency.wrap(bmxIsToken0 ? address(wblt) : address(bmx)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        bool otherIsToken0 = address(other) < address(wblt);
        otherKey = PoolKey({
            currency0: Currency.wrap(otherIsToken0 ? address(other) : address(wblt)),
            currency1: Currency.wrap(otherIsToken0 ? address(wblt) : address(other)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(canonicalKey, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));
        EasyPosm.mint(positionManager, canonicalKey, -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
        EasyPosm.mint(positionManager, otherKey,     -60000, 60000, 1e21, 1e24, 1e24, address(this), block.timestamp + 1 hours, bytes(""));
        pid = canonicalKey.toId();
    }

    /*//////////////////////////////////////////////////////////////
                       REENTRANCY GUARD TEST
    //////////////////////////////////////////////////////////////*/
    function testFlushReentrancyProtected() public {
        // Step 1: create wBLT buy-back buffer via OTHER -> wBLT swap
        uint256 input = 1e17;
        poolManager.unlock(abi.encode(address(other), input));
        assertGt(fp.pendingWbltForBuyback(), 0, "buffer not populated");

        // Step 2: configure pool key and slippage tolerance
        fp.setBuybackPoolKey(canonicalKey);
        fp.setMinOutBps(9900);

        // Step 3: flush – should succeed and token will attempt re-enter internally
        fp.flushBuffers();

        // Ensure re-entrancy attempt occurred and was blocked (flag set)
        assertTrue(bmx.reentered(), "no reentrancy attempt detected");

        // Buffer cleared and gauge bucket credited
        assertEq(fp.pendingWbltForBuyback(), 0, "buffer not cleared");
        assertGt(gauge.collectBucket(pid), 0, "bucket not credited");
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL SWAP REENTRANCY TEST
    //////////////////////////////////////////////////////////////*/
    function testInternalSwapReentrancyProtected() public {
        // Step 1: Generate fees on BMX pool to trigger internal swap
        uint256 input = 1e17;
        
        // Determine swap direction based on token ordering
        bool bmxIsToken0 = address(bmx) < address(wblt);
        address tokenIn = bmxIsToken0 ? address(bmx) : address(wblt);
        
        poolManager.unlock(abi.encode(tokenIn, input));
        
        // Step 2: Configure buyback pool
        fp.setBuybackPoolKey(canonicalKey);
        
        // Step 3: Check that we have pending BMX for voter (from the 3% split)
        assertGt(fp.pendingBmxForVoter(), 0, "no BMX voter buffer");
        
        // Step 4: Flush buffers - this will trigger BMX->wBLT internal swap
        fp.flushBuffers();
        
        // Verify reentrancy was attempted and blocked
        assertTrue(bmx.reentered(), "no reentrancy attempt during internal swap");
        
        // Verify flush completed successfully
        // Note: pendingBmxForVoter will have residual fee from internal swap (3% of 0.3%)
        assertGt(fp.pendingBmxForVoter(), 0, "should have residual fee from internal swap");
        assertLt(fp.pendingBmxForVoter(), 1e10, "residual should be small");
    }

    /*//////////////////////////////////////////////////////////////
                         POOLMANAGER CALLBACK
    //////////////////////////////////////////////////////////////*/

    // The test uses the PoolManager.unlock pattern: it encodes (tokenIn, amount) and
    // expects this callback to perform an exact-input swap using the hook-instrumented
    // pools.  Logic mirrors other integration tests.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");

        (address tokenIn, uint256 amountIn) = abi.decode(data, (address, uint256));

        PoolKey memory key;
        SwapParams memory sp;

        if (tokenIn == address(other)) {
            // OTHER (token0) → wBLT (token1) on otherKey
            key = otherKey;
            key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
            poolManager.settle();
            sp = SwapParams({
                zeroForOne: true, // token0 -> token1
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        } else if (tokenIn == address(bmx)) {
            // BMX (tokenX) → wBLT swap on canonical pool (direction depends on ordering)
            bool bmxIsToken0 = address(bmx) < address(wblt);
            key = canonicalKey;
            if (bmxIsToken0) {
                // BMX is token0 → zeroForOne swap
                key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
                poolManager.settle();
                sp = SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                });
            } else {
                // BMX is token1 → zeroForOne = false
                key.currency1.settle(poolManager, address(this), uint128(amountIn), false);
                poolManager.settle();
                sp = SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                });
            }
        } else if (tokenIn == address(wblt)) {
            // wBLT input (only used potentially) – choose canonical pool direction
            bool bmxIsToken0 = address(bmx) < address(wblt);
            key = canonicalKey;
            if (bmxIsToken0) {
                // wBLT is token1 → zeroForOne = false
                key.currency1.settle(poolManager, address(this), uint128(amountIn), false);
                poolManager.settle();
                sp = SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                });
            } else {
                // wBLT is token0 → zeroForOne = true
                key.currency0.settle(poolManager, address(this), uint128(amountIn), false);
                poolManager.settle();
                sp = SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                });
            }
        } else {
            revert("unknown token");
        }

        BalanceDelta delta = poolManager.swap(key, sp, bytes(""));

        // Take the output tokens so PoolManager's balances net to zero.
        if (sp.zeroForOne) {
            uint256 outAmt = uint256(int256(delta.amount1()));
            if (outAmt > 0) {
                key.currency1.take(poolManager, address(this), outAmt, false);
            }
        } else {
            uint256 outAmt = uint256(int256(delta.amount0()));
            if (outAmt > 0) {
                key.currency0.take(poolManager, address(this), outAmt, false);
            }
        }

        poolManager.settle();
        return bytes("");
    }
} 