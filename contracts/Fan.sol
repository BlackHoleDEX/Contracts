// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenFour is ERC20, Ownable {
    // Initial supply is set in the constructor
    uint256 private constant _initialSupply = 1000000 * 10 ** 18; // 1,000,000 tokens with 18 decimals

    constructor() ERC20("TokenEleven", "TELV") Ownable () {
        // Mint the initial supply to the contract deployer
        _mint(msg.sender, _initialSupply);
    }

    /**
     * @dev Mint new tokens. Only the owner can call this function.
     * @param account Address to receive the minted tokens.
     * @param amount Amount of tokens to be minted.
     */
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    /**
     * @dev Burn tokens from an account. Only the owner can call this function.
     * @param account Address whose tokens will be burned.
     * @param amount Amount of tokens to be burned.
     */
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }
}
