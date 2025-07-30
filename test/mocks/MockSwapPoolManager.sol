// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockPoolManager} from "test/mocks/MockPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Extended mock implementing the minimal subset of PoolManager behaviour used by FeeProcessor swap tests.
/// Inherits the extsload implementation from MockPoolManager to avoid duplication.
contract MockSwapPoolManager is MockPoolManager {
    // configuration for swap behaviour
    uint16 public outputBps = 10_000; // linear 1:1 output by default
    bool public revertOnSwap;

    // slot constant copied from StateLibrary for slot0 access
    bytes32 public constant POOLS_SLOT = bytes32(uint256(6));

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
        return IUnlockCallback(msg.sender).unlockCallback(data);
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
    function initialize(PoolKey memory, uint160) external returns (int24) { return 0; }
    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        returns (BalanceDelta, BalanceDelta)
    {
        return (toBalanceDelta(0, 0), toBalanceDelta(0, 0));
    }
    function donate(PoolKey memory, uint256, uint256, bytes calldata) external returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }
} 