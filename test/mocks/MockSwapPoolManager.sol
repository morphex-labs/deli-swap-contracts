// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockPoolManager} from "test/mocks/MockPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";

/// @notice Extended mock implementing the minimal subset of PoolManager behaviour used by FeeProcessor swap tests.
/// Inherits the extsload implementation from MockPoolManager to avoid duplication.
contract MockSwapPoolManager is MockPoolManager, IExttload {
    // configuration for swap behaviour
    uint16 public outputBps = 10_000; // linear 1:1 output by default
    bool public revertOnSwap;

    // slot constant copied from StateLibrary for slot0 access
    bytes32 public constant POOLS_SLOT = bytes32(uint256(6));
    
    // Track unlock state for TransientStateLibrary.isUnlocked() checks
    bool private _isUnlocked;

    // ---------------------------------------------------------------------
    // Helper setters
    // ---------------------------------------------------------------------

    /// @dev Writes the encoded sqrtPrice into the slot0 position for a given poolId.
    function setSqrtPrice(bytes32 poolId, uint160 sqrtPriceX96) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        _slotValue[stateSlot] = bytes32(uint256(sqrtPriceX96)); // keep other params zero
    }

    function setOutputBps(uint16 bps) external { outputBps = bps; }
    function setRevertOnSwap(bool flag) external { revertOnSwap = flag; }

    // ---------------------------------------------------------------------
    // Minimal PoolManager-like API used by FeeProcessor
    // ---------------------------------------------------------------------

    function unlock(bytes calldata data) external returns (bytes memory) {
        // mimic PoolManager.unlock by directly invoking the caller's callback
        _isUnlocked = true;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        _isUnlocked = false;
        return result;
    }

    function settle() external payable returns (uint256) { return 0; }
    function settleFor(address) external payable returns (uint256) { return 0; }
    function sync(Currency) external {}
    function take(Currency, address, uint256) external {}
    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256) external {}
    function clear(Currency, uint256) external {}
    function updateDynamicLPFee(PoolKey memory, uint24) external {}

    // swap logic – very simplified pricing
    function swap(PoolKey memory /*key*/, SwapParams memory params, bytes calldata /*hook*/)
        external
        view
        returns (BalanceDelta delta)
    {
        if (revertOnSwap) revert("swap fail");

        int128 amtIn = int128(-params.amountSpecified); // positive input magnitude
        int128 out = int128(int256(uint256(uint128(uint256(int256(amtIn))) * outputBps / 10_000)));

        if (params.zeroForOne) {
            // token0 in (BMX) → token1 out (wBLT)
            delta = toBalanceDelta(-amtIn, out);
        } else {
            // token1 in → token0 out
            delta = toBalanceDelta(out, -amtIn);
        }
    }

    // unused but required for interface parity with original tests
    function initialize(PoolKey memory, uint160) external pure returns (int24) { return 0; }
    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        pure
        returns (BalanceDelta, BalanceDelta)
    {
        return (toBalanceDelta(0, 0), toBalanceDelta(0, 0));
    }
    function donate(PoolKey memory, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    // ---------------------------------------------------------------------
    // IExttload implementation for TransientStateLibrary
    // ---------------------------------------------------------------------
    
    // Lock.IS_UNLOCKED_SLOT from v4-core
    bytes32 constant IS_UNLOCKED_SLOT = bytes32(uint256(keccak256("Lock")) - 1);
    
    function exttload(bytes32 slot) external view override returns (bytes32 value) {
        // Only handle the IS_UNLOCKED_SLOT for now
        if (slot == IS_UNLOCKED_SLOT) {
            return _isUnlocked ? bytes32(uint256(1)) : bytes32(0);
        }
        // For other slots, return 0
        return bytes32(0);
    }
    
    function exttload(bytes32[] calldata slots) external view override returns (bytes32[] memory values) {
        uint256 len = slots.length;
        values = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            if (slots[i] == IS_UNLOCKED_SLOT) {
                values[i] = _isUnlocked ? bytes32(uint256(1)) : bytes32(0);
            } else {
                values[i] = bytes32(0);
            }
        }
    }
} 