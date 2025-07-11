// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;


import '../libraries/Math.sol';
import '../interfaces/IBribeAPI.sol';
import '../interfaces/IWrappedBribeFactory.sol';
import '../interfaces/IGaugeAPI.sol';
import '../interfaces/IGaugeFactory.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IMinter.sol';
import '../interfaces/IPair.sol';
import '../interfaces/IPairFactory.sol';
import '../interfaces/IVoter.sol';
import '../interfaces/IGaugeManager.sol';
import '../interfaces/IVotingEscrow.sol';

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "hardhat/console.sol";

contract RewardAPI is Initializable {

 

    IPairFactory public pairFactory;
    IVoter public voter;
    IGaugeManager public gaugeManager;
    address public underlyingToken;
    address public owner;


    
    constructor() {}

    function initialize(address _voter, address _gaugeManager) initializer public {
        owner = msg.sender;
        voter = IVoter(_voter);
        gaugeManager = IGaugeManager(_gaugeManager);
        pairFactory = IPairFactory(voter.factories()[0]);
        underlyingToken = IVotingEscrow(voter._ve()).token();
    }


    struct Bribes {
        address[] tokens;
        string[] symbols;
        uint[] decimals;
        uint[] amounts;
    }

    struct Rewards {
        Bribes[] bribes;
    }

    /// @notice Get the rewards available the next epoch.
    function getExpectedClaimForNextEpoch(uint tokenId, address[] memory pairs) external view returns(Rewards[] memory){
        uint i;
        uint len = pairs.length;
        address _gauge;
        address _bribe;

        Bribes[] memory _tempReward = new Bribes[](2);
        Rewards[] memory _rewards = new Rewards[](len);

        //external
        for(i=0; i < len; i++){
            _gauge = gaugeManager.gauges(pairs[i]);

            // get external
            _bribe = gaugeManager.external_bribes(_gauge);
            // _tempReward[0] = _getEpochRewards(tokenId, _bribe);
            
            // get internal
            _bribe = gaugeManager.internal_bribes(_gauge);
            // _tempReward[1] = _getEpochRewards(tokenId, _bribe);
            _rewards[i].bribes = _tempReward;
        }      

        return _rewards;  
    }
   
    // function _getEpochRewards(uint tokenId, address _bribe) internal view returns(Bribes memory _rewards){
    //     uint totTokens = IBribeAPI(_bribe).rewardsListLength();
    //     uint[] memory _amounts = new uint[](totTokens);
    //     address[] memory _tokens = new address[](totTokens);
    //     string[] memory _symbol = new string[](totTokens);
    //     uint[] memory _decimals = new uint[](totTokens);
    //     uint ts = IBribeAPI(_bribe).getEpochStart();
    //     uint i = 0;
    //     //uint _supply = IBribeAPI(_bribe).totalSupplyAt(ts);
    //     uint _balance = IBribeAPI(_bribe).balanceOfAt(tokenId, ts);
    //     address _token;
    //     IBribeAPI.Reward memory _reward;

    //     for(i; i < totTokens; i++){
    //         _token = IBribeAPI(_bribe).bribeTokens(i);
    //         _tokens[i] = _token;
    //         if(_balance == 0){
    //             _amounts[i] = 0;
    //             _symbol[i] = '';
    //             _decimals[i] = 0;
    //         } else {
    //             _symbol[i] = IERC20(_token).symbol();
    //             _decimals[i] = IERC20(_token).decimals();
    //             _reward = IBribeAPI(_bribe).rewardData(_token, ts);
    //             _amounts[i] = (_reward.rewardsPerEpoch * 1e18 / _supply) * _balance / 1e18;
    //         }
    //     }

    //     _rewards.tokens = _tokens;
    //     _rewards.amounts = _amounts;
    //     _rewards.symbols = _symbol;
    //     _rewards.decimals = _decimals;
    // }


    
    // read all the bribe available for a pair
    function getPairBribe(address pair) external view returns(Bribes[] memory){

        address _gauge;
        address _bribe;

        Bribes[] memory _tempReward = new Bribes[](2);

        // get external
        _gauge = gaugeManager.gauges(pair);
        _bribe = gaugeManager.external_bribes(_gauge);
        _tempReward[0] = _getNextEpochRewards(_bribe);
        
        // get internal
        _bribe = gaugeManager.internal_bribes(_gauge);
        _tempReward[1] = _getNextEpochRewards(_bribe);
        return _tempReward;
            
    }

    function _getNextEpochRewards(address _bribe) internal view returns(Bribes memory _rewards){
        uint totTokens = IBribeAPI(_bribe).rewardsListLength();
        uint[] memory _amounts = new uint[](totTokens);
        address[] memory _tokens = new address[](totTokens);
        string[] memory _symbol = new string[](totTokens);
        uint[] memory _decimals = new uint[](totTokens);
        uint ts = IBribeAPI(_bribe).getNextEpochStart();
        uint i = 0;
        address _token;

        for(i; i < totTokens; i++){
            _token = IBribeAPI(_bribe).bribeTokens(i);
            _tokens[i] = _token;
            _symbol[i] = IERC20(_token).symbol();
            _decimals[i] = IERC20(_token).decimals();
            _amounts[i] = IBribeAPI(_bribe).tokenRewardsPerEpoch(_token, ts);
        }

        _rewards.tokens = _tokens;
        _rewards.amounts = _amounts;
        _rewards.symbols = _symbol;
        _rewards.decimals = _decimals;
    }

 
    function setOwner(address _owner) external {
        require(msg.sender == owner, 'not owner');
        require(_owner != address(0), 'zeroAddr');
        owner = _owner;
    }

    function setVoter(address _voter) external {
        require(msg.sender == owner, 'not owner');
        require(_voter != address(0), 'zeroAddr');
        voter = IVoter(_voter);
        // update variable depending on voter
        pairFactory = IPairFactory(voter.factories()[0]);
        underlyingToken = IVotingEscrow(voter._ve()).token();
    }

    function setGaugeManager(address _gaugeManager) external {
        require(msg.sender == owner, 'not owner');
        require(_gaugeManager != address(0), 'zeroAddr');
        gaugeManager = IGaugeManager(_gaugeManager);
    }

}