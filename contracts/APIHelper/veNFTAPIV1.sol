// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;


import '../libraries/Math.sol';
import '../interfaces/IBribeAPI.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IPair.sol';
import '../interfaces/IPairFactory.sol';
import '../interfaces/IVoter.sol';
import '../interfaces/IGaugeManager.sol';
import '../interfaces/IVotingEscrow.sol';
import '../interfaces/IRewardsDistributor.sol';
import '../interfaces/IGaugeFactory.sol';
import '../interfaces/IGaugeFactoryCL.sol';


import "../AVM/interfaces/IAutoVotingEscrowManager.sol";
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";

import "hardhat/console.sol";

interface IPairAPI {
    struct Bribes {
        address bribeAddress;
        address[] tokens;
        string[] symbols;
        uint[] decimals;
        uint[] amounts;
    }

    struct Rewards {
        Bribes[] bribes;
    }

    function pair_factory() external view returns(address);
}

contract veNFTAPIV1 {

    struct LockInfo {
        address owner;
        uint256 tokenId;
    }

    struct pairVotes {
        address pair;
        uint256 weight;
    }

    struct InternalBribeInputs {
        uint id;
        address bribe_address;
        address t0;
        address t1;
        address pair;
    }

    struct ExternalBribeInputs {
        uint id;
        address bribe_address;
        uint tokens;
        address pair;
    }

    struct veNFT {
        uint8 decimals;
        
        bool voted;
        bool hasVotedForEpoch;
        uint256 attachments;

        uint256 id;
        uint128 amount;
        uint256 voting_amount;
        uint256 rebase_amount;
        uint256 lockEnd;
        uint256 vote_ts;
        pairVotes[] votes;        
        
        address account;
        
        bool isSMNFT;
        bool isPermanent;

        address token;
        string tokenSymbol;
        uint256 tokenDecimals;
    }

    struct Reward {
        
        uint256 id;
        uint256 amount;  
        uint8 decimals;
        
        address pair;
        address token;
        address bribe;

        string symbol;
    }

    struct PairReward {
        address pair;
        Reward[] votingRewards;
    }

    struct LockReward {
        uint256 id;
        uint128 lockedAmount;
        PairReward[] pairRewards;
    }
   
    uint256 constant public MAX_RESULTS = 1000;
    uint256 constant public MAX_PAIRS = 30;
    uint256 public immutable WEEK;

    IVoter public voter;
    IGaugeManager public gaugeManager;
    IGaugeFactory public gaugeFactory;
    IGaugeFactoryCL public gaugeFactoryCL;
    address public underlyingToken;
    

    IVotingEscrow public ve;
    IRewardsDistributor public rewardDisitributor;

    address public pairAPI;
    IPairFactory public pairFactory;
    

    address public owner;
    IAutoVotingEscrowManager public avm;
    event Owner(address oldOwner, address newOwner);

    struct AllPairRewards {
        Reward[] rewards;
    }

    constructor(address _voter, address _rewarddistro, address _gaugeFactory, address _gaugeFactoryCL, address _gaugeManager) {
        owner = msg.sender;
        voter = IVoter(_voter);
        rewardDisitributor = IRewardsDistributor(_rewarddistro);
        gaugeFactory = IGaugeFactory(_gaugeFactory);
        gaugeManager = IGaugeManager(_gaugeManager);
        gaugeFactoryCL = IGaugeFactoryCL(_gaugeFactoryCL);

        require(rewardDisitributor.voting_escrow() == voter._ve(), 've!=ve');
        
        ve = IVotingEscrow( rewardDisitributor.voting_escrow() );
        underlyingToken = IVotingEscrow(ve).token();

        WEEK = BlackTimeLibrary.WEEK;
    }

    function getAllNFT(uint256 _amounts, uint256 _offset) external view returns(veNFT[] memory _veNFT){

        require(_amounts <= MAX_RESULTS, 'TOO_MANY');
        _veNFT = new veNFT[](_amounts);

        uint i = _offset;
        address _owner;

        for(i; i < _offset + _amounts; i++){
            _owner = ve.ownerOf(i);
            // if id_i has owner read data
            if(_owner != address(0)){
                _veNFT[i-_offset] = _getNFTFromId(i, _owner);
            }
        }
    }

    function getNFTFromId(uint256 id) external view returns(veNFT memory){
        return _getNFTFromId(id,ve.ownerOf(id));
    }

    function getNFTFromAddress(address _user) external view returns(veNFT[] memory venft){

        uint256 totNFTs = (_user != address(0)) ? ve.balanceOf(_user) : 0;

        venft = new veNFT[](totNFTs);
        uint256 i=0;
        uint256 _id;

        for(i; i < totNFTs; i++){
            _id = ve.tokenOfOwnerByIndex(_user, i);
            if(_id != 0){
                venft[i] = _getNFTFromId(_id, _user);
            }
        }

        return venft;
    }

    function getAVMNFTFromAddress(address _user) public view returns (veNFT[] memory) {
        IAutoVotingEscrow[] memory avms = avm.getAVMs(); // assuming avms() is a function
        veNFT[] memory temp = new veNFT[](1000) ; // ✅ DECLARATION — fixed-size temporary memory array
        uint count = 0;

        for (uint256 i = 0; i < avms.length; i++) {
            IAutoVotingEscrow.LockInfo[] memory locks = avms[i].getLocks(); // assuming locks() is a function
            for (uint256 j = 0; j < locks.length; j++) {
                IAutoVotingEscrow.LockInfo memory _lock = locks[j];
                if (_lock.owner == _user) {
                    temp[count] = _getNFTFromId(_lock.tokenId, address(avms[i]));
                    count++;
                }
            }
        }

        // Final array trimmed to correct size
        veNFT[] memory venft = new veNFT[](count);
        for (uint256 i = 0; i < count; i++) {
            venft[i] = temp[i];
        }

        return venft;
    }

    function _getNFTFromId(uint256 id, address _owner) internal view returns(veNFT memory venft){

        if(_owner == address(0)){
            return venft;
        }

        uint _totalPoolVotes = voter.poolVoteLength(id);
        pairVotes[] memory votes = new pairVotes[](_totalPoolVotes);

        IVotingEscrow.LockedBalance memory _lockedBalance;
        _lockedBalance = ve.locked(id);

        uint k;
        uint256 _poolWeight;
        address _votedPair;

        for(k = 0; k < _totalPoolVotes; k++){

            _votedPair = voter.poolVote(id, k);
            if(_votedPair == address(0)){
                break;
            }
            _poolWeight = voter.votes(id, _votedPair);
            votes[k].pair = _votedPair;
            votes[k].weight = _poolWeight;
        }

        venft.id = id;
        venft.account = _owner;
        venft.decimals = ve.decimals();
        venft.amount = _lockedBalance.isSMNFT ? uint128(ve.calculate_original_sm_nft_amount(uint256(int256(_lockedBalance.amount)))) : uint128(_lockedBalance.amount); // this is 10% extra for super massive
        venft.voting_amount = ve.balanceOfNFT(id);
        venft.rebase_amount = rewardDisitributor.claimable(id);
        venft.lockEnd = _lockedBalance.end;
        venft.vote_ts = voter.lastVotedTimestamp(id);
        venft.votes = votes;
        venft.token = ve.token();
        venft.tokenSymbol =  IERC20( ve.token() ).symbol();
        venft.tokenDecimals = IERC20( ve.token() ).decimals();
        venft.attachments = ve.attachments(id);
        venft.isSMNFT = _lockedBalance.isSMNFT;
        venft.isPermanent = _lockedBalance.isPermanent;
        
        venft.voted = ve.voted(id);
        venft.hasVotedForEpoch = (BlackTimeLibrary.epochStart(block.timestamp) < venft.vote_ts) && (venft.vote_ts < BlackTimeLibrary.epochNext(block.timestamp));
    }

    // used only for sAMM and vAMM    
    // function allPairRewards(uint256 _amount, uint256 _offset, uint256 id) external view returns(AllPairRewards[] memory rewards){
        
    //     rewards = new AllPairRewards[](MAX_PAIRS);

    //     uint256 totalPairs = pairFactory.allPairsLength();
        
    //     uint i = _offset;
    //     address _pair;
    //     address _gaugeAddress;
    //     for(i; i < _offset + _amount; i++){
    //         if(i >= totalPairs){
    //             break;
    //         }
    //         _pair = pairFactory.allPairs(i);
    //         _gaugeAddress = IVoter(voter).gauges(_pair);
    //         rewards[i].rewards = _pairReward(_pair, id, _gaugeAddress);
    //     }
    // }

   function getAllPairRewards(address _user, uint _lockBatchSize, uint _lockOffset, uint _gaugeBatchSize, uint _gaugeOffset) external view returns(LockReward[] memory _lockReward){

        if(_user == address(0)){

            return (_lockReward);
        }
        uint startLockIndex = _lockOffset;
        uint endLockIndex = _lockOffset + _lockBatchSize;
        uint totNFTs = ve.balanceOf(_user);
        endLockIndex = (endLockIndex < totNFTs) ? endLockIndex : totNFTs;

        _lockReward = new LockReward[](endLockIndex - startLockIndex);

        uint256 nftId;

        for(uint i = startLockIndex; i < endLockIndex; i++){
            nftId = ve.tokenOfOwnerByIndex(_user, i);   
            _lockReward[i-startLockIndex].id = nftId;
            _lockReward[i-startLockIndex].lockedAmount = uint128(ve.locked(nftId).amount);
            (_lockReward[i-startLockIndex].pairRewards) = _getRewardsForNft(nftId, _gaugeBatchSize, _gaugeOffset);
        }
    }
    function _getRewardsForNft(uint nftId, uint _gaugeBatchSize, uint _gaugeOffset) internal view returns (PairReward[] memory pairReward) {
        uint basicPoolGaugeLength = gaugeFactory.length();
        uint clPoolGaugeLength = gaugeFactoryCL.length();
        
        // Calculate the actual range to process
        uint startIdx = _gaugeOffset;
        uint endIdx = _gaugeOffset + _gaugeBatchSize;
        
        // Check if there are more gauges beyond this batch and cap endIdx
        endIdx = (endIdx < basicPoolGaugeLength + clPoolGaugeLength) ? endIdx : (basicPoolGaugeLength + clPoolGaugeLength);
        uint maxPairRewardCount = 0;
        PairReward[] memory _pairRewards = new PairReward[](endIdx - startIdx);
        Reward[] memory _rewardData;
        bool hasReward;
        address poolAddress;

        for(uint i = startIdx; i < endIdx; i++){
            if(i >= basicPoolGaugeLength){
                poolAddress = IGaugeManager(gaugeManager).poolForGauge(gaugeFactoryCL.gauges(i-basicPoolGaugeLength));
                (_rewardData, hasReward) = _pairReward(poolAddress, nftId, gaugeFactoryCL.gauges(i-basicPoolGaugeLength));
            }
            else{
                poolAddress = IGaugeManager(gaugeManager).poolForGauge(gaugeFactory.gauges(i));
                (_rewardData, hasReward) = _pairReward(poolAddress, nftId, gaugeFactory.gauges(i));
            }

            if(hasReward)
            {
                _pairRewards[maxPairRewardCount].pair = poolAddress;
                _pairRewards[maxPairRewardCount].votingRewards = _rewardData;
                maxPairRewardCount++;
            }
        }

        pairReward = new PairReward[](maxPairRewardCount);

        for(uint i=0; i<maxPairRewardCount; i++){
            pairReward[i].pair = _pairRewards[i].pair;
            pairReward[i].votingRewards = _pairRewards[i].votingRewards;
        }
    }

    function _pairReward(address _pair, uint256 id,  address _gauge) internal view returns (Reward[] memory _reward, bool) {

        if (_gauge == address(0)) {
            return (_reward, false);
        }

        address external_bribe = gaugeManager.external_bribes(_gauge);
        address internal_bribe = gaugeManager.internal_bribes(_gauge);

        uint256 totBribeTokens = (external_bribe == address(0)) ? 0 : IBribeAPI(external_bribe).rewardsListLength();
        _reward = new Reward[](2 + totBribeTokens);

        // Fetch pair contract once
        IPair ipair = IPair(_pair);
        (address t0, address t1) = (ipair.token0(), ipair.token1());

        InternalBribeInputs memory internal_bribes_input = InternalBribeInputs({
            id: id,
            t0: t0,
            t1: t1,
            bribe_address: internal_bribe,
            pair: _pair
        });

        ExternalBribeInputs memory external_bribes_input = ExternalBribeInputs({
            id: id,
            bribe_address: external_bribe,
            tokens: totBribeTokens,
            pair: _pair
        });

        // Fetch earned fees
        bool internalRewards = _addInternalBribeRewards(_reward, internal_bribes_input);
        bool externalRewards = _addExternalBribeRewards(_reward, external_bribes_input);

        return (_reward, internalRewards || externalRewards);
    }

    function _addInternalBribeRewards(Reward[] memory _reward, InternalBribeInputs memory internal_bribes_inputs) internal view returns (bool) {
        uint256 _feeToken0 = IBribeAPI(internal_bribes_inputs.bribe_address).earned(internal_bribes_inputs.id, internal_bribes_inputs.t0);
        uint256 _feeToken1 = IBribeAPI(internal_bribes_inputs.bribe_address).earned(internal_bribes_inputs.id, internal_bribes_inputs.t1);
        bool hasReward = false;
        if (_feeToken0 > 0) {
            _reward[0] = _createReward(internal_bribes_inputs.id, _feeToken0, internal_bribes_inputs.t0, internal_bribes_inputs.bribe_address, internal_bribes_inputs.pair);
            hasReward = true;
        }
        if (_feeToken1 > 0) {
            _reward[1] = _createReward(internal_bribes_inputs.id, _feeToken1, internal_bribes_inputs.t1, internal_bribes_inputs.bribe_address, internal_bribes_inputs.pair);
            hasReward = true;
        }

        return hasReward;
    }

    function _addExternalBribeRewards(Reward[] memory _reward, ExternalBribeInputs memory external_bribes_input) internal view returns (bool) {
        bool hasReward = false;
        for (uint256 k = 0; k < external_bribes_input.tokens; k++) {
            address _token = IBribeAPI(external_bribes_input.bribe_address).bribeTokens(k);
            uint256 bribeAmount = IBribeAPI(external_bribes_input.bribe_address).earned(external_bribes_input.id, _token);
            if(bribeAmount > 0){
                hasReward = true;
                _reward[2 + k] = _createReward(external_bribes_input.id, bribeAmount, _token, external_bribes_input.bribe_address, external_bribes_input.pair);
            }
        }

        return hasReward;
    }

    function _createReward(uint256 id, uint256 amount, address token, address bribe, address _pair) internal view returns (Reward memory) {
        return Reward({
            id: id,
            pair: _pair,
            amount: amount,
            token: token,
            symbol: IERC20(token).symbol(),
            decimals: IERC20(token).decimals(),
            bribe: bribe
        });
    }
    

    function setOwner(address _owner) external {
        require(msg.sender == owner, 'NA');
        require(_owner != address(0), 'ZA');
        owner = _owner;
        emit Owner(msg.sender, _owner);
    }

    
    function setVoter(address _voter) external  {
        require(msg.sender == owner);

        voter = IVoter(_voter);
    }

    function setAVM(address _avm) external {
        require(msg.sender == owner && _avm!=address(0));
        avm = IAutoVotingEscrowManager(_avm);
    }
    
    function setGaugeManager(address _gaugeManager) external  {
        require(msg.sender == owner);
        gaugeManager = IGaugeManager(_gaugeManager);
    }

    function setGaugeFactory(address _gaugeFactory) external  {
        require(msg.sender == owner);
        gaugeFactory = IGaugeFactory(_gaugeFactory);
    }

    function setGaugeFactoryCL(address _gaugeFactoryCL) external  {
        require(msg.sender == owner);
        gaugeFactoryCL = IGaugeFactoryCL(_gaugeFactoryCL);
    }


    function setRewardDistro(address _rewarddistro) external {
        require(msg.sender == owner);
        
        rewardDisitributor = IRewardsDistributor(_rewarddistro);
        require(rewardDisitributor.voting_escrow() == voter._ve(), 've!=ve');

        ve = IVotingEscrow( rewardDisitributor.voting_escrow() );
        underlyingToken = IVotingEscrow(ve).token();
    }
    
    function setPairAPI(address _pairApi) external {
        require(msg.sender == owner);
        
        pairAPI = _pairApi;
    }


    function setPairFactory(address _pairFactory) external {
        require(msg.sender == owner);  
        pairFactory = IPairFactory(_pairFactory);
    }

}

