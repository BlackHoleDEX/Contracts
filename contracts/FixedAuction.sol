// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import  "./interfaces/IAuction.sol";
import "./interfaces/IGenesisPoolBase.sol";
import "./interfaces/IGenesisPool.sol";

contract FixedAuction is IGenesisPoolBase, IAuction, OwnableUpgradeable {

    constructor() {}

    function initialize() initializer  public {
        __Ownable_init();
    }

    function getNativePrice() external view returns (uint256){
        address genesisPool = msg.sender;
        uint256 startPrice = IGenesisPool(genesisPool).getGenesisInfo().startPrice;
        return startPrice;
    }

    function getNativeTokenAmount(uint256 depositAmount) external view returns (uint256){
        address genesisPool = msg.sender;
        TokenAllocation memory tokenAllocation = IGenesisPool(genesisPool).getAllocationInfo();
        return (depositAmount * tokenAllocation.proposedNativeAmount) / tokenAllocation.proposedFundingAmount;
    }

    function getFundingTokenAmount(uint256 depositAmount) external view returns (uint256){
        address genesisPool = msg.sender;
        TokenAllocation memory tokenAllocation = IGenesisPool(genesisPool).getAllocationInfo();
        return (depositAmount * tokenAllocation.proposedFundingAmount) / tokenAllocation.proposedNativeAmount;
    }

    // populate
    function purchased(uint256 amount) external {

    }
}