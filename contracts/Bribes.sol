// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "./interfaces/IMinter.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/ITokenHandler.sol";
import {IAutomatedVotingManager} from "./interfaces/IAutomatedVotingManager.sol";
import {IAutoVotingEscrowManager} from "./AVM/interfaces/IAutoVotingEscrowManager.sol";
import {IAutoVotingEscrow} from "./AVM/interfaces/IAutoVotingEscrow.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract Bribe is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public WEEK; 

    /* ========== STATE VARIABLES ========== */

    struct VotingRewardsPlot {
        uint128 balanceOf;
        uint32 timestamp;
    }

    struct VotingSupplyPlot {
        uint128 supply;
        uint32 timestamp;
    }

    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;
    address public voter;
    address public gaugeManager;
    address public immutable bribeFactory;
    address public minter;
    address public immutable ve;
    address public owner;
    address public avm; // does it need to be immutable?
    ITokenHandler public tokenHandler;

    string public TYPE;

    uint256 public totalSupply;
    mapping(uint256 => uint256) public balanceOf;

    mapping(address => mapping(uint256 => uint256)) public lastEarn;

    mapping(uint256 => mapping(uint256 => VotingRewardsPlot)) public votingRewardsPlots;
    mapping(uint256 => uint256) public numVotingRewardsPlots;

    mapping(uint256 => VotingSupplyPlot) public votingSupplyPlots;
    uint256 public numVotingSupplyPlots;

    mapping(address => bool) internal isBribeToken;
    address[] public bribeTokens;


    /* ========== CONSTRUCTOR ========== */

    constructor(address _owner,address _voter,address _gaugeManager, address _bribeFactory, address _tokenHandler, address _token0, address _token1, string memory _type)  {
        require(_bribeFactory != address(0) && _voter != address(0) && _gaugeManager != address(0) && _owner != address(0), "ZA");
        WEEK = BlackTimeLibrary.WEEK;
        voter = _voter;
        gaugeManager = _gaugeManager;
        bribeFactory = _bribeFactory;
        tokenHandler = ITokenHandler(_tokenHandler);
        ve = IVoter(_voter)._ve();
        minter = IGaugeManager(_gaugeManager).minter();
        avm = IVotingEscrow(ve).avm();
        require(minter != address(0), "ZA");
        owner = _owner;
        TYPE = _type;

        bribeTokens.push(_token0);
        bribeTokens.push(_token1);
        isBribeToken[_token0] = true;
        isBribeToken[_token1] = true;
    }

    function getEpochStart() public view returns(uint256){
        return IMinter(minter).active_period();
    }

    /// @notice get next epoch (where bribes are saved)
    function getNextEpochStart() public view returns(uint256){
        return BlackTimeLibrary.epochNext(block.timestamp);
    }

    /* ========== VIEWS ========== */

    /// @notice get the length of the reward tokens
    function rewardsListLength() external view returns(uint256) {
        return bribeTokens.length;
    }

    /// @notice Read earned amount given a tokenID and _rewardToken
    function earned(uint256 tokenId, address _rewardToken) public view returns(uint256){
        if (numVotingRewardsPlots[tokenId] == 0) {
            return 0;
        }
        
        uint256 reward = 0;
        uint256 _supply = 1;
        uint256 _currTs = BlackTimeLibrary.epochStart(lastEarn[_rewardToken][tokenId]); // take epoch last claimed in as starting point
        uint256 _index = getPriorVotingRewardsIndex(tokenId, _currTs);
        VotingRewardsPlot memory cp0 = votingRewardsPlots[tokenId][_index];
        
        
        _currTs = Math.max(_currTs, BlackTimeLibrary.epochStart(cp0.timestamp));

        uint256 numEpochs = (BlackTimeLibrary.epochStart(block.timestamp) - _currTs) / WEEK;

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                _index = getPriorVotingRewardsIndex(tokenId, _currTs + WEEK - 1);
                cp0 = votingRewardsPlots[tokenId][_index];
                _supply = Math.max(votingSupplyPlots[getPriorVotingSupplyIndex(_currTs + WEEK - 1)].supply, 1);
                reward += (cp0.balanceOf * tokenRewardsPerEpoch[_rewardToken][_currTs]) / _supply;
                _currTs += WEEK;
            }
        } 
        return reward;  
    }


    function getPriorVotingRewardsIndex(uint256 tokenId, uint256 timestamp) public view returns (uint256) {
        uint256 nPlots = numVotingRewardsPlots[tokenId];
        if (nPlots == 0) {
            return 0;
        }
        if (votingRewardsPlots[tokenId][nPlots - 1].timestamp <= timestamp) {
            return (nPlots - 1);
        }
        if (votingRewardsPlots[tokenId][0].timestamp > timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nPlots - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            VotingRewardsPlot memory plot = votingRewardsPlots[tokenId][center];
            if (plot.timestamp == timestamp) {
                return center;
            } else if (plot.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorVotingSupplyIndex(uint256 timestamp) public view returns (uint256) {
        uint256 nPlots = numVotingSupplyPlots;
        if (nPlots == 0) {
            return 0;
        }

        if (votingSupplyPlots[nPlots - 1].timestamp <= timestamp) {
            return nPlots - 1;
        }

        if (votingSupplyPlots[0].timestamp > timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nPlots - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            VotingSupplyPlot memory plot = votingSupplyPlots[center];
            if (plot.timestamp == timestamp) return center;
            else if (plot.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function isRewardToken(address _rewardToken) external view returns (bool) {
        return _isRewardToken(_rewardToken);
    }

    function _isRewardToken(address _rewardToken) internal view returns (bool) {
        return isBribeToken[_rewardToken] || tokenHandler.isConnector(_rewardToken);
    }
 
    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice User votes deposit
    /// @dev    called on voter.vote() or voter.poke()
    ///         we save into owner "address" and not "tokenID". 
    ///         Owner must reset before transferring token
    function deposit(uint256 amount, uint256 tokenId) external nonReentrant {
        require(amount > 0, "ZV");
        require(msg.sender == voter, "NA");
        totalSupply = totalSupply + amount;
        balanceOf[tokenId] = balanceOf[tokenId] + amount;

        _writeVotingRewardsPlot(tokenId, balanceOf[tokenId]);
        _writeVotingSupplyPlot();
        
        emit Staked(tokenId, amount);
    }

    function _writeVotingRewardsPlot(uint256 tokenId, uint256 balance) internal {
        uint256 nPlots = numVotingRewardsPlots[tokenId];
        uint32 ts = uint32(block.timestamp);

        if (
            nPlots > 0 &&
            BlackTimeLibrary.epochStart(votingRewardsPlots[tokenId][nPlots - 1].timestamp) ==
            BlackTimeLibrary.epochStart(ts)
        ) {
            votingRewardsPlots[tokenId][nPlots - 1] = VotingRewardsPlot(uint128(balance), ts);
        } else {
            votingRewardsPlots[tokenId][nPlots] = VotingRewardsPlot(uint128(balance), ts);
            numVotingRewardsPlots[tokenId] = nPlots + 1;
        }
    }

    function _writeVotingSupplyPlot() internal {
        uint256 nPlots = numVotingSupplyPlots;
        uint32 ts = uint32(block.timestamp);

        if (
            nPlots > 0 &&
            BlackTimeLibrary.epochStart(votingSupplyPlots[nPlots - 1].timestamp) ==
            BlackTimeLibrary.epochStart(ts)
        ) {
            votingSupplyPlots[nPlots - 1] = VotingSupplyPlot(uint128(totalSupply), ts);
        } else {
            votingSupplyPlots[nPlots] = VotingSupplyPlot(uint128(totalSupply), ts);
            numVotingSupplyPlots = nPlots + 1;
        }
    }

    /// @notice User votes withdrawal 
    /// @dev    called on voter.reset()
    function withdraw(uint256 amount, uint256 tokenId) external nonReentrant {
        require(amount > 0, "ZV");
        require(msg.sender == voter, "NA");
        if (amount <= balanceOf[tokenId]) {
            totalSupply -= amount;
            balanceOf[tokenId] -= amount;

            _writeVotingRewardsPlot(tokenId, balanceOf[tokenId]);
            _writeVotingSupplyPlot();
            emit Withdrawn(tokenId, amount);
        }
    }

    /// @notice Claim the TOKENID rewards
    function getReward(uint256 tokenId, address[] memory tokens) external nonReentrant  {
        address _owner = IVotingEscrow(ve).ownerOf(tokenId);
        if(_isAValidAutoVotingEscrow(_owner)) {
            _owner = IAutoVotingEscrowManager(avm).getOriginalOwner(tokenId);
        }
        require(msg.sender == gaugeManager, "NA");
        uint256 _length = tokens.length;
        for (uint256 i = 0; i < _length; i++) {
            uint256 _reward = earned(tokenId, tokens[i]);
            lastEarn[tokens[i]][tokenId] = block.timestamp;
            if (_reward > 0) {
                IERC20(tokens[i]).safeTransfer(_owner, _reward);
            }
        }
    }

    function _isAValidAutoVotingEscrow(address _addr) public view returns (bool) {
        IAutoVotingEscrow[] memory avmList = IAutoVotingEscrowManager(avm).getAVMs();
        for (uint i = 0; i < avmList.length; i++) {
            if (address(avmList[i]) == _addr) return true;
        }
        return false;
    }
    /// @dev Rewards are saved into Current EPOCH mapping. 
    function notifyRewardAmount(address _rewardsToken, uint256 reward) external nonReentrant {
        require(_isRewardToken(_rewardsToken), "!VERIFIED");

        if(!isBribeToken[_rewardsToken]){
            isBribeToken[_rewardsToken] = true;
            bribeTokens.push(_rewardsToken);
        }

        IERC20(_rewardsToken).safeTransferFrom(msg.sender,address(this),reward);
        uint256 epochStart = BlackTimeLibrary.epochStart(block.timestamp);
        tokenRewardsPerEpoch[_rewardsToken][epochStart] += reward;
        emit RewardAdded(_rewardsToken, reward, epochStart);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Recover some ERC20 from the contract and updated given bribe
    function recoverERC20AndUpdateData(address tokenAddress, uint256 tokenAmount) external onlyAllowed {
        require(tokenAmount <= IERC20(tokenAddress).balanceOf(address(this)), "TOO_MUCH");
        
        uint256 _startTimestamp = IMinter(minter).active_period();
        uint256 _lastReward = tokenRewardsPerEpoch[tokenAddress][_startTimestamp];
        tokenRewardsPerEpoch[tokenAddress][_startTimestamp] = _lastReward - tokenAmount;
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /// @notice Recover some ERC20 from the contract.
    /// @dev    Be careful --> if called then getReward() at last epoch will fail because some reward are missing! 
    ///         Think about calling recoverERC20AndUpdateData()
    function emergencyRecoverERC20(address tokenAddress, uint256 tokenAmount) external onlyAllowed {
        require(tokenAmount <= IERC20(tokenAddress).balanceOf(address(this)), "TOO_MUCH");
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /// @notice Set a new voter
    function setVoter(address _Voter) external onlyAllowed {
        require(_Voter != address(0), "ZA");
        voter = _Voter;
    }

    /// @notice Set a new gaugeManager
    function setGaugeManager(address _gaugeManager) external onlyAllowed {
        require(_gaugeManager != address(0));
        gaugeManager = _gaugeManager;
    }

    /// @notice Set a new minter
    function setMinter(address _minter) external onlyAllowed {
        require(_minter != address(0), "ZA");
        minter = _minter;
    }

    /// @notice Set a new AVM 
    function setAVM(address _avm) external onlyAllowed {
        require(_avm!=address(0), "ZA");
        avm = _avm;
    }

    /// @notice Set a new Owner
    event SetOwner(address indexed _owner);
    function setOwner(address _owner) external onlyAllowed {
        require(_owner != address(0), "ZA");
        owner = _owner;
        emit SetOwner(_owner);
    }


    /* ========== MODIFIERS ========== */

    modifier onlyAllowed() {
        require( (msg.sender == owner || msg.sender == bribeFactory), "NA" );
        _;
    }


    /* ========== EVENTS ========== */

    event RewardAdded(address indexed rewardToken, uint256 reward, uint256 startTimestamp);
    event Staked(uint256 indexed tokenId, uint256 amount);
    event Withdrawn(uint256 indexed tokenId, uint256 amount);
    event RewardPaid(address indexed user,address indexed rewardsToken,uint256 reward);
    event Recovered(address indexed token, uint256 amount);
}
