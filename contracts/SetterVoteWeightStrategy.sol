// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./interfaces/IVoteWeightStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IAutoVotingEscrowManager} from "./AVM/interfaces/IAutoVotingEscrowManager.sol";

contract SetterVoteWeightStrategy is IVoteWeightStrategy, Ownable {
    uint256 public topN;
    uint256[] public voteWeights;
    IAutoVotingEscrowManager public avm;
    address public executor;

    event TopNUpdated(uint256 newTopN);
    event VoteWeightsUpdated(uint256[] newWeights);
    event AVMSet(address newAVM);
    event ExecutorUpdated(address newExecutor);

    constructor(address _avm) {
        require(_avm != address(0), "AVM address cannot be zero");
        avm = IAutoVotingEscrowManager(_avm);
        topN = avm.topN();
        executor = avm.executor();
    }

    modifier onlyAVM() {
        require(msg.sender == address(avm), "Only AVM can call");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "Only executor can call");
        _;
    }

    modifier onlyOwnerOrExecutor() {
        require(msg.sender == owner() || msg.sender == executor, "Unauthorized");
        _;
    }

    function getVoteWeights() external view returns (uint256[] memory) {
        return voteWeights;
    }

    function setVoteWeights(uint256[] calldata _weights) external onlyExecutor {
        uint weightsLen = _weights.length;
        require(weightsLen <= topN, "Vote weight array exceeds topN");

        voteWeights = new uint256[](weightsLen);
        for (uint256 i = 0; i < weightsLen; i++) {
            voteWeights[i] = _weights[i];
        }
        emit VoteWeightsUpdated(_weights);
    }

    function setAVM(address _avm) external onlyOwner {
        require(_avm != address(0), "ZA");
        avm = IAutoVotingEscrowManager(_avm);
        emit AVMSet(_avm);
    }

    function setTopN() external onlyAVM {
        topN = avm.topN();
        emit TopNUpdated(topN);
    }

    function setExecutor(address _executor) external onlyOwnerOrExecutor {
        require(_executor != address(0), "ZA");
        executor = _executor;
        emit ExecutorUpdated(_executor);
    }
}
