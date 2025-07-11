// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IPairFactory {
    function allPairsLength() external view returns (uint);
    function isPair(address pair) external view returns (bool);
    function allPairs(uint index) external view returns (address);
    function pairCodeHash() external view returns (bytes32);
    function getPair(address tokenA, address token, bool stable) external view returns (address);
    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);
    function isGenesis(address pair) external view returns (bool);
    function getFee(address _pairAddress, bool _stable) external view returns(uint256);
}
