// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import './Pair.sol';
import './interfaces/IPairGenerator.sol';

contract PairGenerator is IPairGenerator {

    event PairCreated(address indexed token0, address indexed token1, bool stable, address pair);
    
    constructor(){}

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(Pair).creationCode);
    }

    function createPair(address token0, address token1, bool stable) external returns (address pair) {
        address factory = msg.sender;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable)); // notice salt includes stable as well, 3 parameters
        pair = address(new Pair{salt: salt}(factory, token0, token1, stable));
        emit PairCreated(token0, token1, stable, pair);
    }
}
