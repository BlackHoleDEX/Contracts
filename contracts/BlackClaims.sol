// SPDX-License-Identifier: GPL-3.0-or-later
// Black Hole Foundation 2025

pragma solidity 0.8.13;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBlackClaims} from "./interfaces/IBlackClaims.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

/// @title Manager for the seasonal player rewards program.
/// @author Chance Santana-Wees (Coelacanth/Coel.eth)
/// @custom:modified-by Mitesh
/// @dev Season rewards pulled from a treasury contract that must have a token allowance set for this contract.
/// @notice Allows System Admins to set up and report scores for Seasons.
contract BlackClaims is IBlackClaims {

    uint256 public MAX_PERIOD;

    ///@notice The address of the rewards token. (The BLACK token)
    IERC20 immutable token;

    ///@notice The traeasury from which Seasons pull their reward tokens.
    address treasury;

    address public owner;
    address public secondOwner;
    modifier onlyOwner {
        require(msg.sender == owner || msg.sender == secondOwner, 'not owner');
        _;
    }

    /// @notice The metagame staking pool
    IVotingEscrow public _ve;

    ///@notice A claim season period.
    IBlackClaims.Season public season;

    ///@notice A mapping of scores reported for each user by address.
    mapping(address => uint256) public season_rewards;

    ///@notice A mapping of quantity of tokens claimed for each user by address.
    mapping(address => uint256) public claimed_rewards;

    event TreasurySet(address treasury);
    event StakedRewards(address staker, uint256 rewards);

    ///@param treasury_ The address of the account/contract that the Seasons reward system pulls reward tokens from.
    /// @param __ve Address of the ve(3,3) system that will be locked into
    constructor(
        address treasury_,
        address __ve) 
    {
        owner = msg.sender;
        treasury = treasury_;
        _ve = IVotingEscrow(__ve);
        token = IERC20(_ve.token());
        MAX_PERIOD = BlackTimeLibrary.MAX_LOCK_DURATION;
    }

    ///@notice Updates the address of the account/contract that the Seasons reward system pulls reward tokens from.
    ///@dev Only callable by Global Admins.
    ///@param treasury_ The address of the new treasury.
    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    ///@notice Initializes a new Season of the rewards program.
    ///@dev Only callable by Systems Admins. It is permissable to create Seasons with overlapping times.
    ///@param start_time_ The start time of the new season.
    ///@return season_ IBlackClaims.Season The Season struct that was initialized.
    function startSeason(
        uint256 start_time_
    ) external onlyOwner returns(IBlackClaims.Season memory season_)
    {
        require(start_time_ > 0, "CANNOT START AT 0");
        require(season.start_time==0, "SEASON ALREADY STARTED");
        season_.start_time = start_time_;
        season = season_;
    }

    ///@notice Queries the finalized status of a season.
    ///@dev A season is finalized if its claim time is set.
    ///@return _finalized bool The finalized status of the provided season.
    function isSeasonFinalized() public view returns(bool _finalized) 
    {
        _finalized = season.claim_end_time > 0;
    }

    ///@notice Queries if a season has been finalized and can have rewards claimed from it.
    ///@return _active bool True if the season has ended at the provided timestamp
    function isSeasonClaimingActive() public view returns(bool _active) 
    {
        _active = isSeasonFinalized() && season.claim_end_time >= block.timestamp;
    }

    ///@notice Queries if a season has been finalized and the claim period has already elapsed.
    ///@return _ended bool True if the season's rewards claim period has elapsed.
    function isSeasonClaimingEnded() public view returns(bool _ended) 
    {
        _ended = isSeasonFinalized() && season.claim_end_time < block.timestamp;
    }

    ///@notice Revokes unclaimed reward tokens into the treasury.
    ///@dev Callable only by Systems Admins and only after the season's claim period has elapsed.
    function revokeUnclaimedReward() external onlyOwner
    {
        Season storage _season = season;
        uint256 _remaining_reward_amount = _season.remaining_reward_amount;
        require(_season.start_time > 0, "SEASON NOT FOUND");
        require(isSeasonClaimingEnded(), "SEASON_CLAIM_NOT_ENDED");
        require(_remaining_reward_amount > 0, "ZERO_REMAINING_AMOUNT");

        bool transfer_success = token.transfer(treasury, _remaining_reward_amount);
        require(transfer_success, "FAILED TRANSFER");
        _season.remaining_reward_amount -= uint128(_remaining_reward_amount);
    }

    ///@notice Finalizes a season, setting its rewards quantity and claim period.
    ///@dev Callable only by Systems Admins and only after the season has been ended by calling the endSeason(...) function.
    ///@param claim_duration_ The duration of the claim period.
    function finalize(
        uint256 claim_duration_
    ) external onlyOwner
    {
        Season storage _season = season;
        require(_season.start_time > 0, "SEASON NOT FOUND");
        require(!isSeasonFinalized(), "SEASON_FINALIZED");
        require(_season.reward_amount>0, "NO REWARD AMOUNT");
        require(claim_duration_ >= 1 days && claim_duration_ < 1000 days, "CLAIM DURATION OUT OF BOUNDS");

        bool transfer_success = token.transferFrom(treasury, address(this), _season.reward_amount);
        require(transfer_success, "FAILED TRANSFER");
        
        _season.remaining_reward_amount = _season.reward_amount;
        _season.claim_end_time = block.timestamp + claim_duration_;
    }

    ///@notice Extends a season claim end time, setting its rewards quantity and claim period.
    function extendClaimDuration(
        uint256 claim_duration_
    ) external onlyOwner
    {
        Season storage _season = season;
        require(_season.start_time > 0, "SEASON NOT FOUND");
        require(isSeasonFinalized(), "SEASON_NOT_FINALIZED");
        require(_season.reward_amount>0, "NO REWARD AMOUNT");
        _season.claim_end_time = _season.claim_end_time + claim_duration_;
    }

    ///@notice Reports an list of players' scores for the specified season.
    ///@dev Callable only by Systems Admins.
    ///@param players_ The list of player addresses.
    ///@param rewards_ The list of player's total current rewards.
    function reportRewards(
        address[] calldata players_,
        uint256[] calldata rewards_
    ) external onlyOwner
    {
        require(players_.length == rewards_.length, "ARRAYS  MISMATCH");

        Season storage _season = season;
        require(_season.start_time > 0, "SEASON NOT FOUND");
        require(!isSeasonFinalized(), "SEASON FINALIZED");
        
        uint256 _increase = 0;
        uint256 _decrease = 0;

        for (uint256 i = 0; i < players_.length; i++) {
            _increase += rewards_[i];
            _decrease += season_rewards[players_[i]];
            season_rewards[players_[i]] = rewards_[i];
        }

        _season.reward_amount += _increase;
        _season.reward_amount -= _decrease;
    }

    ///@notice Claim tokens rewarded to msg.sender in the specified season. Must have a verified Access Pass.
    ///@dev Callable only on seasons which have been finalized and whose claim duration has not elapsed.
    function _preClaim() internal 
        returns (uint256)
    {
        require(claimed_rewards[msg.sender] == 0, "REWARD CLAIMED");

        Season storage _season = season;
        require(isSeasonClaimingActive(), "SEASON_CLAIM_ENDED");

        uint256 _reward = season_rewards[msg.sender];
        require(_reward > 0, "MUST HAVE A NON ZERO REWARD");

        _season.remaining_reward_amount -= _reward;
        claimed_rewards[msg.sender] = _reward;

        return _reward;
    }

    ///@notice Stake tokens claimed.
    ///@dev Callable only on seasons which have been finalized and whose claim duration has not elapsed.
    function claimAndStakeReward(uint percent) external returns (uint)
    {
        require(percent>=50&&percent<=100, "Percent out of bounds");
        uint256 _reward = _preClaim();
        uint256 staked_reward = 0;
        Season storage _season = season;

        if(percent == 100) {
            staked_reward = _reward;
        } else {
            uint256 credit_amount = (_reward * 100)/110;
            uint256 forfeit_amount = _reward - credit_amount;

            _season.remaining_reward_amount += forfeit_amount;

            staked_reward = (credit_amount * percent)/100;
            uint256 claimed_reward = credit_amount - staked_reward;
            bool transfer_success = token.transfer(msg.sender, claimed_reward);
            require(transfer_success, "FAILED TRANSFER");
        }
        token.approve(address(_ve), staked_reward);
        uint _tokenId = _ve.create_lock_for(staked_reward, MAX_PERIOD, msg.sender, true);
        emit StakedRewards(msg.sender, staked_reward);
        return _tokenId;
    }

    ///@notice get reward tokens claimable by a player in the specified season.
    function getClaimableReward(address userAddress) public view returns(uint256 _reward) 
    {

        _reward = season_rewards[userAddress] - claimed_rewards[userAddress];
        if( !isSeasonClaimingActive() )
        {
            _reward = 0;
        }
    }

    /// @notice Transfer tokens that have been sent to this contract by mistake.
    /// @dev Only callable by address with Global Admin permissions. Cannot be called to withdraw emissions tokens.
    /// @param tokenAddress_ The address of the token to recover
    function recoverERC20(address tokenAddress_) external onlyOwner {
        require(tokenAddress_ != address(0));
        uint _balance = IERC20(tokenAddress_).balanceOf(address(this));
        IERC20(tokenAddress_).transfer(msg.sender, _balance);
    }

    function setOwner(address _owner) external onlyOwner {
        require(_owner != address(0));
        owner = _owner;
    }
    function setOwner2(address _owner) external onlyOwner {
        require(_owner != address(0));
        secondOwner = _owner;
    }
}