// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Simple ERC20 that burns 1% on every transfer to mimic fee-on-transfer behaviour.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * FEE_BPS / 10_000;
        uint256 sendAmt = amount - fee;
        bool ok = super.transfer(to, sendAmt);
        _burn(msg.sender, fee);
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * FEE_BPS / 10_000;
        uint256 sendAmt = amount - fee;
        bool ok = super.transferFrom(from, to, sendAmt);
        _burn(from, fee);
        return ok;
    }
} 