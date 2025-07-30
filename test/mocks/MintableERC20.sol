// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "lib/uniswap-hooks/lib/v4-core/lib/forge-std/src/mocks/MockERC20.sol";

contract MintableERC20 is MockERC20 {
    function mintExternal(address to, uint256 amount) external {
        _mint(to, amount);
    }
} 