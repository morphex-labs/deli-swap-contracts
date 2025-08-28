// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {DeliHook} from "src/DeliHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MintableERC20} from "test/mocks/MintableERC20.sol";

/// @notice Simple mock that records sync/settle/take calls, used by DeliHook tests.
contract MockHookPoolManager {
    Currency public lastSyncCurrency;
    uint256 public settleCalls;
    struct TakeCall { Currency currency; address to; uint256 amount; }
    TakeCall public lastTake;
    
    // Store pool fees for testing
    mapping(bytes32 => uint24) public poolFees;
    // Optional override for sqrtPriceX96 (global for tests)
    uint160 public sqrtPriceX96Override;
    
    // Pools slot from StateLibrary
    bytes32 constant POOLS_SLOT = bytes32(uint256(6));

    // --------------- IPoolManager minimal ----------------
    function sync(Currency currency) external {
        lastSyncCurrency = currency;
    }

    function settle() external payable returns (uint256) {
        settleCalls += 1;
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        lastTake = TakeCall(currency, to, amount);
        address token = Currency.unwrap(currency);
        if (token != address(0) && amount > 0) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal < amount) {
                // attempt to mint missing tokens (MintableERC20 is used in unit tests)
                try MintableERC20(token).mintExternal(address(this), amount - bal) {} catch {}
            }
            IERC20(token).transfer(to, amount);
        }
    }

    /// @notice Test helper to override the simulated sqrtPriceX96 returned by extsload
    function setSqrtPriceX96(uint160 v) external {
        sqrtPriceX96Override = v;
    }

    // ------------------------------------------------------------------
    // Minimal ERC-6909 balance query used by DeliHookV2Curve._refreshReserves.
    // The real PoolManager tracks per-account token balances internally; our
    // tests only need the call to succeed (any value is acceptable).
    // ------------------------------------------------------------------

    function balanceOf(address /*account*/, uint256 /*id*/) external view returns (uint256) {
        // Simply return 0 – unit-tests don’t inspect the value, they only
        // require the function not to revert.
        return 0;
    }

    /// @notice Lightweight swap simulation that directly calls beforeSwap and afterSwap on the hook
    ///         This is **not** a full swap implementation – it is only sufficient for the FeeProcessor
    ///         integration test which relies on the hook side-effects (fee forwarding & gauge pokes).
    function simulateHookSwap(
        address trader,
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external {
        // The hook must be the contract specified in the pool key.
        address hookAddr = address(key.hooks);
        if (hookAddr == address(0)) return;

        DeliHook h = DeliHook(hookAddr);
        // Call before/after swap with poolManager context (this contract).
        h.beforeSwap(trader, key, params, hookData);
        h.afterSwap(trader, key, params, toBalanceDelta(0, 0), hookData);
    }

    // Unused functions --------------------------------------------------
    // For tests that rely on PoolManager's reentrant unlock flow, forward the callback to the caller.
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }
    function settleFor(address) external payable returns (uint256) { return 0; }
    function initialize(PoolKey memory, uint160) external returns (int24) { return 0; }
    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata) external returns (BalanceDelta, BalanceDelta) { return (toBalanceDelta(0,0), toBalanceDelta(0,0)); }
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (BalanceDelta) { return toBalanceDelta(0,0); }
    function donate(PoolKey memory, uint256, uint256, bytes calldata) external returns (BalanceDelta) { return toBalanceDelta(0,0); }
    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256) external {}
    function clear(Currency, uint256) external {}
    function updateDynamicLPFee(PoolKey memory key, uint24 fee) external {
        bytes32 poolId = keccak256(abi.encode(key));
        poolFees[poolId] = fee;
    }

    // ------------------------------------------------------------------
    // extsload helpers (unused by our mock but required by libraries)
    // ------------------------------------------------------------------
    function extsload(bytes32 slot) external view returns (bytes32) {
        // StateLibrary.getSlot0 expects slot0 data packed as:
        // Bits 0-159: sqrtPriceX96 (160 bits)
        // Bits 160-183: tick (24 bits)  
        // Bits 184-207: protocolFee (24 bits)
        // Bits 208-231: lpFee (24 bits)
        // Bits 232-255: empty (24 bits)
        
        // Return a slot0 with fee of 3000 (0.3%) and configurable sqrtPriceX96
        uint256 sqrtPriceX96 = sqrtPriceX96Override != 0 ? sqrtPriceX96Override : (1 << 96); // price = 1 by default
        int256 tick = 0;
        uint256 protocolFee = 0;
        uint256 lpFee = 3000; // 0.3%
        
        uint256 packedSlot = sqrtPriceX96 | 
                            (uint256(uint24(int24(tick))) << 160) |
                            (protocolFee << 184) |
                            (lpFee << 208);
        
        return bytes32(packedSlot);
    }
    function extsload(bytes32, uint256 nSlots) external view returns (bytes32[] memory arr) {
        arr = new bytes32[](nSlots);
    }
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory arr) {
        arr = new bytes32[](slots.length);
    }
} 