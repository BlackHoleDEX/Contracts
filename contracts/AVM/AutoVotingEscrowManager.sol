// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "./AutoVotingEscrow.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../interfaces/IVotingEscrow.sol";
import "./interfaces/IAutoVotingEscrow.sol";
import "../interfaces/ITopNPoolsStrategy.sol";
import "../interfaces/IVoteWeightStrategy.sol";
import "../interfaces/IVoter.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IAutoVotingEscrowManager} from "./interfaces/IAutoVotingEscrowManager.sol";

// change name of contract
contract AutoVotingEscrowManager is IAutoVotingEscrowManager, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable  {
    ITopNPoolsStrategy public topPoolsStrategy;
    IVoteWeightStrategy public voteWeightStrategy;

    IVotingEscrow public votingEscrow;
    address public voter;
    uint256 public topN;

    uint256 public constant MAX_TOP_N = 100; // can be changed but has to be assigned on the instantiation

    mapping(uint256 => uint256) public tokenIdToAVMId;
    mapping(uint256 => address) public originalOwner;
    IAutoVotingEscrow[] public avms;

    uint256 public nextAvailableAVMIndex;
    address public rewardsDistributor;
    uint public minBalanceForAutovoting;
    address public executor;

    modifier validAVMIndex(uint256 index) {
        require(index < avms.length, "Invalid AVM index");
        _;
    }

    modifier onlyVotingEscrow {
        require(msg.sender == address(votingEscrow), '!VE');
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "Only executor");
        _;
    }

    uint256 public MAX_LOCKS;

    function initialize(address _votingEscrow, address _voter, address _rewardsDistributor) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        votingEscrow = IVotingEscrow(_votingEscrow);
        voter = _voter;
        executor = msg.sender;
        minBalanceForAutovoting = 100_000*1e18; // decimals in black
        rewardsDistributor = _rewardsDistributor;
        _transferOwnership(msg.sender);
        MAX_LOCKS = 200;
    }

    function enableAutoVoting(uint256 tokenId) external {
        require(votingEscrow.isApprovedOrOwner(msg.sender, tokenId), "NAO");
        require(!BlackTimeLibrary.isLastHour(block.timestamp), "LH");
        
        // Extract locked balance into separate variable
        IVotingEscrow.LockedBalance memory lockedBalance = votingEscrow.locked(tokenId);
        uint256 lockedAmount = uint256(int256(lockedBalance.amount));
        
        // Check minimum balance requirement
        require(lockedAmount >= minBalanceForAutovoting, "IB");
        
        // Check that the token is not an SMNFT
        require(lockedBalance.isSMNFT, "only_SMNFT");
        
        uint avmsLength = avms.length;
        // Search for a non-full AVM using while loop
        IAutoVotingEscrow target;
        while (nextAvailableAVMIndex < avmsLength) {
            if (!isFull(avms[nextAvailableAVMIndex])) {
                target = avms[nextAvailableAVMIndex];
                break;
            }
            nextAvailableAVMIndex++;
        }

        // If none found, create a new AVM
        if (address(target) == address(0)) {
            AutoVotingEscrow newAVM = new AutoVotingEscrow(address(this), voter, address(votingEscrow), rewardsDistributor);
            target = IAutoVotingEscrow(address(newAVM));
            avms.push(target);
        }

        votingEscrow.transferFrom(msg.sender, address(target), tokenId);
        target.acceptLock(msg.sender, tokenId); // insert to token Ids here
        tokenIdToAVMId[tokenId] = nextAvailableAVMIndex + 1;
    }

    function disableAutoVoting(uint256 tokenId) external {
        uint256 avmIdxOneBased = tokenIdToAVMId[tokenId];
        require(avmIdxOneBased > 0 && avmIdxOneBased - 1 < avms.length, "out of range"); // is this necessary
        require(!BlackTimeLibrary.isLastHour(block.timestamp), "LH");
        IAutoVotingEscrow avm = avms[avmIdxOneBased - 1];
        require(avm.lockOwner(tokenId) == msg.sender, "Not owner");

        // Release lock
        avm.releaseLock(tokenId); // replace with last element and pop here 
        IVoter(voter).reset(tokenId); // wrote it here as the autovoting escrow itself isnt upgradeable
        votingEscrow.transferFrom(address(avm), msg.sender, tokenId);

        delete tokenIdToAVMId[tokenId];

        // If AVM became non-full, track it
        if ((!isFull(avm)) && (avmIdxOneBased - 1 < nextAvailableAVMIndex)) {
            nextAvailableAVMIndex = avmIdxOneBased - 1;
        }
    }
    // instead of avm addresses how about avm indexes
    function getAVMIndex(address avmAddr) internal view returns (uint256) {
        uint avmsLength = avms.length;
        for (uint256 i = 0; i < avmsLength; i++) {
            if (address(avms[i]) == avmAddr) {
                return i;
            }
        }
        revert("AVM not found");
    }

    function performLockAction(
        uint256 avmIndex,
        uint256 localStart,
        uint256 localEnd,
        bool isVote
    ) external onlyExecutor {
        require(avmIndex < avms.length, "Invalid AVM index");
        require(localEnd > localStart, "Invalid range");
        require(!isVote || BlackTimeLibrary.isLastHour(block.timestamp), "!LH");

        uint256 avmLockCount = avms[avmIndex].getLockCount();
        require(localEnd <= avmLockCount, "End exceeds available locks");

        if (isVote) {
            avms[avmIndex].voteLocks(localStart, localEnd - localStart);
        } else {
            avms[avmIndex].resetLocks(localStart, localEnd - localStart);
        }
    }

    function getAVMs() external view returns (IAutoVotingEscrow[] memory) {
        return avms;
    }

    function setVoter(address _voter) external onlyOwner {
        require(_voter != address(0), "ZA");
        voter = _voter;
        return;
    }

    function setExecutor(address _executor) external {
        require(msg.sender == executor || msg.sender == owner(), "NA");
        require(_executor != address(0), "ZA");
        executor = _executor;
    }

    function setTopPoolsStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "ZA");
        topPoolsStrategy = ITopNPoolsStrategy(strategy);
    }

    function setVoteWeightStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "ZA");
        voteWeightStrategy = IVoteWeightStrategy(strategy);
    }

    function getTopPools() external view returns (address[] memory) {
        require(address(topPoolsStrategy) != address(0), "ZA");
        address[] memory pools = topPoolsStrategy.getTopNPools();
        return pools;
    }

    function getVoteWeights() external view returns (uint256[] memory) {
        require(address(voteWeightStrategy) != address(0), "ZA");
        return voteWeightStrategy.getVoteWeights(); // need to change interface
    }

    function getTotalVotingPower() external view returns (uint256) {
        uint256 totalVotingPower = 0;
        uint avmsLength = avms.length;
        for(uint i=0; i<avmsLength; i++) {
            totalVotingPower+=avms[i].getTotalVotingPower();
        }
        return totalVotingPower;
    }

    function setTopN(uint256 _topN) public onlyOwner {
        require(_topN > 0 && _topN < MAX_TOP_N, "OUT_RANG");
        topN = _topN;
        if(address(topPoolsStrategy) != address(0)) {
            topPoolsStrategy.setTopN();
        }

        if(address(voteWeightStrategy) != address(0)) {
            voteWeightStrategy.setTopN();
        }
    }

    function setOriginalOwner(uint256 _tokenId, address _user) external onlyVotingEscrow {} // implement this

    function getOriginalOwner(uint256 _tokenId) external view returns (address) {
        uint256 avmIdxOneBased = tokenIdToAVMId[_tokenId];
        require(avmIdxOneBased > 0 && avmIdxOneBased - 1 < avms.length, "OUT_RANG");

        IAutoVotingEscrow avm = avms[avmIdxOneBased - 1];
        return avm.lockOwner(_tokenId);
    }

    function setMinBalanceForAutovoting(uint _minBalance) external onlyOwner {
        minBalanceForAutovoting = _minBalance;
    }

    function isFull(IAutoVotingEscrow _avm) internal view returns (bool) {
        uint lockCount = _avm.getLockCount();
        return lockCount >= MAX_LOCKS;
    }

    function setMaxLockCount(uint _maxLockCount) external onlyOwner {
        MAX_LOCKS = _maxLockCount;
    }

}
