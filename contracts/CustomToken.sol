// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CustomToken is ERC20, Ownable {
    uint8 private immutable _customDecimals;
    uint256 private immutable _initialSupply;

    /**
     * @dev Constructor to initialize token name, symbol, decimals, and initial supply.
     * @param name_ Name of the token.
     * @param symbol_ Symbol of the token.
     * @param decimals_ Number of decimal places.
     * @param initialSupply_ Initial supply (in whole tokens, converted to smallest unit).
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) Ownable() {
        _customDecimals = decimals_;
        _initialSupply = initialSupply_ * 10 ** decimals_;
        _mint(msg.sender, _initialSupply);
    }

    /**
     * @dev Override the decimals function to return custom decimals.
     */
    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /**
     * @dev Mint new tokens. Only the owner can call this function.
     * @param account Address to receive the minted tokens.
     * @param amount Amount of tokens to be minted (in smallest unit).
     */
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    /**
     * @dev Burn tokens from an account. Only the owner can call this function.
     * @param account Address whose tokens will be burned.
     * @param amount Amount of tokens to be burned (in smallest unit).
     */
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }
}