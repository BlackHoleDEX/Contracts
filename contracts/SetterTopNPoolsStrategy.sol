// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./interfaces/IVoter.sol";
import "./interfaces/ITopNPoolsStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IAutoVotingEscrowManager} from "./AVM/interfaces/IAutoVotingEscrowManager.sol";

contract SetterTopNPoolsStrategy is ITopNPoolsStrategy, Ownable {
    IVoter public voterV3;
    IAutoVotingEscrowManager public avm;

    address[] public topNPools;
    uint256 public topN;
    address public executor;

    event TopNPoolsUpdated(address[] poolAddresses);
    event TopNUpdated(uint256 newTopN);
    event AVMSet(address avm);

    constructor(address _voterV3, address _avm) {
        require(_voterV3 != address(0), "Voter cannot be zero");
        require(_avm != address(0), "AVM cannot be zero");
        voterV3 = IVoter(_voterV3);
        avm = IAutoVotingEscrowManager(_avm);
        topN = avm.topN();
        executor = avm.executor();
    }

    modifier onlyAVM() {
        require(msg.sender == address(avm), "Only AVM can call");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "Only AVM can call");
        _;
    }

    modifier onlyOwnerOrExecutor() {
        require(msg.sender == owner() || msg.sender == executor, "Unauthorized");
        _;
    }

    // Allows either the owner or the AVM to update top pools
    function setTopNPools(address[] memory _poolAddresses) external onlyExecutor {
        uint poolAddressesLen = _poolAddresses.length;
        require(poolAddressesLen <= topN, "Exceeds topN");

        delete topNPools;

        for (uint256 i = 0; i < poolAddressesLen; i++) {
            require(_poolAddresses[i] != address(0), "Zero address not allowed");
            topNPools.push(_poolAddresses[i]);
        }

        emit TopNPoolsUpdated(_poolAddresses);
    }

    function setTopN() external onlyAVM {
        topN = avm.topN();
        emit TopNUpdated(topN);
    }

    function getTopNPools() external view returns (address[] memory) {
        return topNPools;
    }

    function setAVM(address _avm) external onlyOwner {
        require(_avm != address(0), "ZA");
        avm = IAutoVotingEscrowManager(_avm);
        emit AVMSet(_avm);
    }

    // the address of executor of top n pools may be different than the executor of executeVotes
    function setExecutor(address _executor) external onlyOwnerOrExecutor {
        require(_executor != address(0), "ZA");
        executor = _executor;
    }
}
