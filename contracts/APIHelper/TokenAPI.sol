// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/ITokenHandler.sol"; 
import '../interfaces/IERC20.sol';
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";

contract TokenAPI is Initializable {

    struct Token {
        address tokenAddress;
        string ticker;
        uint decimal; 	
    }

    ITokenHandler public tokenHandler;

    constructor() {}

    function initialize(address _tokenHandler) initializer public {
        tokenHandler = ITokenHandler(_tokenHandler);
    }

    function getWhiteListedTokens() external view returns (Token[] memory tokens) {
        address[] memory whitelistedTokens = tokenHandler.whiteListedTokens();
        uint i;
        uint length = whitelistedTokens.length;
        tokens = new Token[](length);

        for(i = 0; i < length; i++){
            tokens[i].tokenAddress = whitelistedTokens[i];
            tokens[i].decimal =  IERC20(whitelistedTokens[i]).decimals();
            tokens[i].ticker = IERC20(whitelistedTokens[i]).symbol();
        }

        return tokens;
    }

    function getConnectorTokens() external view returns (Token[] memory tokens) {
        address[] memory connectorTokens = tokenHandler.connectorTokens();
        uint i;
        uint length = connectorTokens.length;
        tokens = new Token[](length);

        for(i = 0; i < length; i++){
            tokens[i].tokenAddress = connectorTokens[i];
            tokens[i].decimal =  IERC20(connectorTokens[i]).decimals();
            tokens[i].ticker = IERC20(connectorTokens[i]).symbol();
        }

        return tokens;
    }

    function getTokenBalances(address _user, address[] memory tokenAddresses) external view returns (uint256[] memory amounts){
        uint256 length = tokenAddresses.length;
        amounts = new uint256[](length);

        if(_user == address(0)) return amounts;
        
        uint256 i;
        for(i = 0; i < length; i++){
            amounts[i] = tokenAddresses[i] != address(0) ? IERC20(tokenAddresses[i]).balanceOf(_user) : 0;
        }
        return amounts;
    }


}