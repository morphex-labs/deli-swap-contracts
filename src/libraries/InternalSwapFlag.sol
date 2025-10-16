// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InternalSwapFlag
library InternalSwapFlag {
    /// @dev Marker inserted into `hookData` by FeeProcessor during its
    ///      internal buy-back swap.
    bytes4 internal constant INTERNAL_SWAP_FLAG = 0xDE1ABEEF;
}
