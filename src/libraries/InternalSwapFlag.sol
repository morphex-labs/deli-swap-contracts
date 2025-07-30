// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InternalSwapFlag
library InternalSwapFlag {
    /// @dev Marker inserted into `hookData` by FeeProcessor during its
    ///      internal buy-back swap. When the hook detects this flag it skips
    ///      all fee-collection logic to avoid recursive fee charging.
    bytes4 internal constant INTERNAL_SWAP_FLAG = 0xDE1ABEEF;
}
