// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

contract WAVAX {
    string public name     = "Wrapped AVAX";
    string public symbol   = "WAVAX";
    uint8  public decimals = 18;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256)                   public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // allow plain AVAX into deposit()
    receive() external payable {
        deposit();
    }
    // reject any other non-deposit calls
    fallback() external payable {
        revert("WAVAX: invalid call");
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
        // ERC-20 mint style event
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "WAVAX: insufficient balance");
        balanceOf[msg.sender] -= wad;
        emit Withdrawal(msg.sender, wad);
        // ERC-20 burn style event
        emit Transfer(msg.sender, address(0), wad);
        payable(msg.sender).transfer(wad);
    }

    function totalSupply() public view returns (uint256) {
        // total WAVAX minted == AVAX held by this contract
        return address(this).balance;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        return transferFrom(msg.sender, to, value);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public returns (bool) {
        require(to != address(0), "WAVAX: transfer to zero address");
        require(balanceOf[from] >= value, "WAVAX: insufficient balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "WAVAX: allowance exceeded");
                allowance[from][msg.sender] = allowed - value;
            }
        }

        balanceOf[from] -= value;
        balanceOf[to]   += value;
        emit Transfer(from, to, value);
        return true;
    }
}
