// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "../interfaces/IVotingEscrow.sol";
import "./interfaces/IAutoVotingEscrow.sol";
import "../interfaces/IRewardsDistributor.sol";
import "./interfaces/IAutoVotingEscrowManager.sol";
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";
import "../interfaces/IVoter.sol";

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract AutoVotingEscrow is IAutoVotingEscrow {
    address public manager;
    uint256 public constant MAX_LOCKS = 1024;
    address public voter;

    address public votingEscrow;
    LockInfo[] public locks;
    address public rewardsDistributor;
    mapping(uint256 => uint256) public tokenIdIndex; // tokenId => index in `locks`

    modifier onlyManager() {
        require(msg.sender == manager, "Only manager");
        _;
    }

    constructor(address _manager, address _voter, address _votingEscrow, address _rewardsDistributor) {
        manager = _manager;
        voter = _voter;
        rewardsDistributor = _rewardsDistributor;
        votingEscrow = _votingEscrow;
    }

    function acceptLock(address _owner, uint256 _tokenId) external onlyManager {
        require(locks.length < MAX_LOCKS, "AVM full");
        tokenIdIndex[_tokenId] = locks.length;
        locks.push(LockInfo({ owner: _owner, tokenId: _tokenId }));
    }

    function releaseLock(uint256 _tokenId) external onlyManager {
        require(!BlackTimeLibrary.isLastHour(block.timestamp), "Cannot disable in last hour before voting");

        uint256 index = tokenIdIndex[_tokenId];
        uint256 lastIndex = locks.length - 1;

        if (index != lastIndex) {
            LockInfo memory lastLock = locks[lastIndex];
            locks[index] = lastLock;
            tokenIdIndex[lastLock.tokenId] = index;
        }

        locks.pop();
        delete tokenIdIndex[_tokenId];

        IVotingEscrow(votingEscrow).approve(msg.sender, _tokenId);
    }

    function lockOwner(uint256 _tokenId) external view override returns (address) {
        uint256 index = tokenIdIndex[_tokenId];
        require(index < locks.length, "Token not found");
        return locks[index].owner;
    }

    function isFull() external view override returns (bool) {
        return locks.length >= MAX_LOCKS;
    }

    function getLockCount() external view override returns (uint256) {
        return locks.length;
    }

    function voteLocks(uint256 start, uint256 length) external override onlyManager {
        require(start + length <= locks.length, "Out of bounds");
        address[] memory pools = IAutoVotingEscrowManager(manager).getTopPools();
        uint[] memory weights = IAutoVotingEscrowManager(manager).getVoteWeights();

        for (uint256 i = start; i < start + length; i++) {
            IVotingEscrow.LockedBalance memory _locked = IVotingEscrow(votingEscrow).locked(locks[i].tokenId);
            if (_locked.end > block.timestamp || _locked.isPermanent) {
                _vote(locks[i].tokenId, pools, weights);
            }
        }
    }

    function resetLocks(uint256 start, uint256 length) external override onlyManager {
        require(start + length <= locks.length, "Out of bounds");

        for (uint256 i = start; i < start + length; i++) {
            IVotingEscrow.LockedBalance memory _locked = IVotingEscrow(votingEscrow).locked(locks[i].tokenId);
            if (_locked.end > block.timestamp || _locked.isPermanent) {
                _reset(locks[i].tokenId);
            }
        }
    }

    function _vote(uint256 tokenId, address[] memory pools, uint[] memory weights) internal {
        IRewardsDistributor(rewardsDistributor).claim(tokenId);
        IVoter(voter).vote(tokenId, pools, weights);
    }

    function _reset(uint256 tokenId) internal {
        IVoter(voter).reset(tokenId);
    }

    function getTotalVotingPower() external view returns (uint256) {
        uint256 votingBalance = 0;
        uint locksLen = locks.length;
        for(uint i=0; i<locksLen; i++) {
            votingBalance += IVotingEscrow(votingEscrow).balanceOfNFT(locks[i].tokenId);
        }
        return votingBalance;
    }

    function getLocks() external view returns (LockInfo[] memory) {
        return locks;
    }

}
