// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IExtsload} from "lib/uniswap-hooks/lib/v4-core/src/interfaces/IExtsload.sol";

/// @title MockPoolManager
/// @notice Minimal pool manager mock that supports extsload for liquidity slot used by StateLibrary.
contract MockPoolManager is IExtsload {
    // mapping(poolId => liquidity)
    mapping(bytes25 => uint128) internal _liquidity;
    mapping(bytes32 => bytes32) internal _slotValue;

    // Record latest slot requested for debug
    bytes32 public lastSlot;
    
    // Default sqrtPriceX96 for 1:1 price
    uint160 constant DEFAULT_SQRT_PRICE = 79228162514264337593543950336; // sqrt(1) * 2^96

    function setLiquidity(bytes32 poolId, uint128 liq) external {
        // compute slot same as StateLibrary
        bytes32 poolsSlot = bytes32(uint256(6));
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, poolsSlot));
        bytes32 slot = bytes32(uint256(stateSlot) + 3);
        _slotValue[slot] = bytes32(uint256(liq));
        
        // Also set slot0 with default sqrtPriceX96
        setPoolSlot0(poolId, DEFAULT_SQRT_PRICE, 0);
    }
    
    function setPoolSlot0(bytes32 poolId, uint160 sqrtPriceX96, int24 tick) public {
        bytes32 poolsSlot = bytes32(uint256(6));
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, poolsSlot));
        // slot0 is at offset 0
        bytes32 slot0Data = bytes32(uint256(sqrtPriceX96)) | (bytes32(uint256(int256(tick))) << 160);
        _slotValue[stateSlot] = slot0Data;
    }

    // internal helper to compute storage slot identical to v4-core layout
    function _liquiditySlot(bytes25 poolId) internal pure returns (bytes32) {
        bytes32 poolsSlot = bytes32(uint256(6));
        bytes32 stateSlot = keccak256(abi.encode(poolId, poolsSlot));
        return bytes32(uint256(stateSlot) + 3); // LIQUIDITY_OFFSET = 3
    }

    /*//////////////////////////////////////////////////////////////
                          IExtsload implementation
    //////////////////////////////////////////////////////////////*/

    function extsload(bytes32 slot) external view override returns (bytes32 value) {
        value = _slotValue[slot];
    }

    // multi-slot version not used but must exist in interface
    function extsload(bytes32 slot, uint256 nSlots) external view override returns (bytes32[] memory words) {
        words = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; ++i) {
            words[i] = _slotValue[bytes32(uint256(slot) + i)];
        }
    }

    function extsload(bytes32[] calldata slots) external view override returns (bytes32[] memory values) {
        uint256 len = slots.length;
        values = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            values[i] = _slotValue[slots[i]];
        }
    }
} 