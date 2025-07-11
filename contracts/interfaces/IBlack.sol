// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IBlack {
    function totalSupply() external view returns (uint);
    function balanceOf(address) external view returns (uint);
    function approve(address spender, uint value) external returns (bool);
    function transfer(address, uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
    function mint(address, uint) external returns (bool);
    function minter() external returns (address);
    function burn(uint) external returns (bool);
    function burnFrom(address, uint) external returns (bool);
}
