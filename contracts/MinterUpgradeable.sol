// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./libraries/Math.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IRewardsDistributor.sol";
import "./interfaces/IBlack.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/IVotingEscrow.sol";

import { IBlackGovernor } from "./interfaces/IBlackGovernor.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

// codifies the minting rules as per ve(3,3), abstracted from the token to support any token that allows minting
// 14 increment epochs followed by 52 decrement epochs after which we wil have vote based epochs

contract MinterUpgradeable is IMinter, OwnableUpgradeable {
    
    bool public isFirstMint;

    uint public teamRate;  //EMISSION that goes to protocol
    uint public constant MAX_TEAM_RATE = 500; // 5%
    uint256 public constant TAIL_START = 67; //TAIL EMISSIONS
    uint256 public tailEmissionRate; 
    uint256 public constant NUDGE = 1; //delta added in tail emissions rate after voting
    uint256 public constant MAXIMUM_TAIL_RATE = 100; //maximum tail emissions rate after voting
    uint256 public constant MINIMUM_TAIL_RATE = 1; //maximum tail emissions rate after voting
    uint256 public constant MAX_BPS = 10_000; 
    uint256 public constant WEEKLY_DECAY = 9_900; //for epoch 15 to 66 growth
    uint256 public constant WEEKLY_GROWTH = 10_300; //for epoch 1 to 14 growth
    uint256 public constant PROPOSAL_INCREASE = 10_100; // 1% increment after the 67th epoch based on proposal
    uint256 public constant PROPOSAL_DECREASE = 9_900; // 1% increment after the 67th epoch based on proposal

    uint public WEEK; // allows minting once per week (reset every Thursday 00:00 UTC)
    uint public weekly; // represents a starting weekly emission of 2.6M BLACK (BLACK has 18 decimals)
    uint public active_period;
    uint public LOCK;
    uint256 public epochCount;

    address internal _initializer;
    address public team;
    address public pendingTeam;
    
    IBlack public _black;
    IGaugeManager public _gaugeManager;
    IVotingEscrow public _ve;
    IRewardsDistributor public _rewards_distributor;
    address private burnTokenAddress;

    mapping(uint256 => bool) public proposals;

    event Mint(address indexed sender, uint weekly, uint circulating_supply, uint circulating_emission);

    constructor() {}

    function initialize(    
        address __gaugeManager, // distribution system
        address __ve, // the ve(3,3) system that will be locked into
        address __rewards_distributor // the distribution system that ensures users aren't diluted
    ) initializer public {
        __Ownable_init();

        _initializer = msg.sender;
        team = msg.sender;
        tailEmissionRate = MAX_BPS;
        teamRate = 500; // 500 bps = 5%
        WEEK = BlackTimeLibrary.WEEK;
        LOCK = BlackTimeLibrary.MAX_LOCK_DURATION;
        _black = IBlack(IVotingEscrow(__ve).token());
        _gaugeManager = IGaugeManager(__gaugeManager);
        _ve = IVotingEscrow(__ve);
        _rewards_distributor = IRewardsDistributor(__rewards_distributor);

        active_period = ((block.timestamp + (2 * WEEK)) / WEEK) * WEEK;
        weekly = 10_000_000 * 1e18; // represents a starting weekly emission of 10M BLACK (BLACK has 18 decimals)
        isFirstMint = true;

        burnTokenAddress=0x000000000000000000000000000000000000dEaD;
    }

    function _initialize(
        address[] memory claimants,
        uint[] memory amounts,
        uint max // sum amounts / max = % ownership of top protocols, so if initial 20m is distributed, and target is 25% protocol ownership, then max - 4 x 20m = 80m
    ) external {
        require(_initializer == msg.sender);
        if(max > 0){
            _black.mint(address(this), max);
            _black.approve(address(_ve), type(uint).max);
            for (uint i = 0; i < claimants.length; i++) {
                _ve.create_lock_for(amounts[i], LOCK, claimants[i], false);
            }
        }

        _initializer = address(0);
        active_period = ((block.timestamp) / WEEK) * WEEK; // allow minter.update_period() to mint new emissions THIS Thursday
    }

    function setTeam(address _team) external {
        require(msg.sender == team);
        pendingTeam = _team;
    }

    function acceptTeam() external {
        require(msg.sender == pendingTeam, "not pending team");
        team = pendingTeam;
    }

    function setGaugeManager(address __gaugeManager) external {
        require(__gaugeManager != address(0));
        require(msg.sender == team, "not team");
        _gaugeManager = IGaugeManager(__gaugeManager);
    }

    function setTeamRate(uint _teamRate) external {
        require(msg.sender == team, "not team");
        require(_teamRate <= MAX_TEAM_RATE, "rate too high");
        teamRate = _teamRate;
    }

    // calculate inflation and adjust ve balances accordingly
    function calculate_rebase(uint _weeklyMint) public view returns (uint) {
        uint _veTotal = IVotingEscrow(_ve).totalSupplyAtT(active_period - 1);
        uint _blackTotal = _black.totalSupply();
        uint _smNFTBalance = IVotingEscrow(_ve).smNFTBalance();
        uint _superMassiveBonus = IVotingEscrow(_ve).calculate_sm_nft_bonus(_smNFTBalance);

        uint blackSupply = _blackTotal + _smNFTBalance + _superMassiveBonus;
        uint256 rebaseAmount =  (((_weeklyMint * (blackSupply - _veTotal)) / blackSupply) * (blackSupply - _veTotal)) / blackSupply / 2;
        return rebaseAmount;
    }
    
    function nudge() external {
        address _epochGovernor = _gaugeManager.getBlackGovernor();
        require (msg.sender == _epochGovernor, "NA");
        IBlackGovernor.ProposalState _state = IBlackGovernor(_epochGovernor).status();
        require (epochCount >= TAIL_START);
        uint256 _period = active_period;
        require (!proposals[_period]);

        if (_state == IBlackGovernor.ProposalState.Succeeded) {
            tailEmissionRate = PROPOSAL_INCREASE;
        }
        else if(_state == IBlackGovernor.ProposalState.Defeated) {
            tailEmissionRate = PROPOSAL_DECREASE;
        } else  {
            tailEmissionRate = 10000;
        }
        proposals[_period] = true;
    }


    // update period can only be called once per cycle (1 week)
    function update_period() external returns (uint) {
        uint _period = active_period;
        if (block.timestamp >= _period + WEEK && _initializer == address(0)) { // only trigger if new week
            epochCount++;
            _period = (block.timestamp / WEEK) * WEEK;
            active_period = _period;
            uint256 _weekly = weekly;
            uint256 _emission;
            bool _tail = epochCount > TAIL_START;

            if (_tail) {
                _emission = (_weekly * tailEmissionRate) / MAX_BPS;
                weekly = _emission;
            } else {
                _emission = _weekly;
                if (epochCount < 15) {
                    _weekly = (_weekly * WEEKLY_GROWTH) / MAX_BPS;
                } else {
                    _weekly = (_weekly * WEEKLY_DECAY) / MAX_BPS;
                }
                weekly = _weekly;
            }

            tailEmissionRate = MAX_BPS;

            uint _rebase = calculate_rebase(_emission);

            uint _teamEmissions = _emission * teamRate / MAX_BPS;

            uint _gauge = _emission - _rebase - _teamEmissions;

            uint _balanceOf = _black.balanceOf(address(this));
            if (_balanceOf < _emission) {
                _black.mint(address(this), _emission - _balanceOf);
            }

            require(_black.transfer(team, _teamEmissions));
            
            require(_black.transfer(address(_rewards_distributor), _rebase));
            _rewards_distributor.checkpoint_token(); // checkpoint token balance that was just minted in rewards distributor

            _black.approve(address(_gaugeManager), _gauge);
            _gaugeManager.notifyRewardAmount(_gauge);

            emit Mint(msg.sender, _emission, _rebase, circulating_supply());
        }
        return _period;
    }

    function circulating_supply() public view returns (uint) {
        return _black.totalSupply() - _black.balanceOf(address(_ve)) - _black.balanceOf(address(burnTokenAddress));
    }

    function check() external view returns(bool){
        uint _period = active_period;
        return (block.timestamp >= _period + WEEK && _initializer == address(0));
    }

    function period() external view returns(uint){
        return(block.timestamp / WEEK) * WEEK;
    }
    function setRewardDistributor(address _rewardDistro) external {
        require(msg.sender == team);
        _rewards_distributor = IRewardsDistributor(_rewardDistro);
    }

    function version() external view returns (string memory version) {
        version  = "MinterUpgradable v1.1.2";
    }
}
