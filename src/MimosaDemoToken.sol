// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Simple mintable ERC20 for Sepolia demos.
contract MimosaDemoToken is ERC20 {
    address public immutable owner;

    error Unauthorized();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        _mint(to, amount);
    }
}
