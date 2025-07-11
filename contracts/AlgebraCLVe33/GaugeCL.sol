// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';

import '../interfaces/IAlgebraEternalFarmingCustom.sol';

import '../interfaces/IAlgebraCustomCommunityVault.sol';
import '../interfaces/IGaugeFactoryCL.sol';
import '../interfaces/IGaugeManager.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IAlgebraEternalFarming.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IAlgebraEternalVirtualPool.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IFarmingCenter.sol';
import '@cryptoalgebra/integral-farming/contracts/base/IncentiveKey.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/IERC20Minimal.sol';

import '../interfaces/IBribe.sol';
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";
import {IncentiveId} from '@cryptoalgebra/integral-farming/contracts/libraries/IncentiveId.sol';

contract GaugeCL is ReentrancyGuard, Ownable {

    using SafeERC20 for IERC20;
    
    IERC20 public immutable rewardToken;
    IERC20 public immutable bonusRewardToken;
    address public VE;
    address public DISTRIBUTION;
    address public internal_bribe;
    address public external_bribe;

    uint256 public DURATION;
    uint256 internal _periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    IFarmingCenter public farmingCenter;
    IGaugeManager.FarmingParam farmingParam;
    IAlgebraEternalFarming public algebraEternalFarming;
    IAlgebraPool public algebraPool;
    address public poolAddress;
    IAlgebraCustomCommunityVault public communityVault;
    INonfungiblePositionManager public nonfungiblePositionManager;


    bool public emergency;
    bool public immutable isForPair;
    address immutable factory;
    uint16 private constant ALGEBRA_FEE_DENOMINATOR = 1000;
    uint16 private constant REFERRAL_FEE_DENOMINATOR = 1000;

    event RewardAdded(uint256 reward);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 reward);
    event ClaimFees(address indexed from, uint256 claimed0, uint256 claimed1);
    event EmergencyActivated(address indexed gauge, uint256 timestamp);
    event EmergencyDeactivated(address indexed gauge, uint256 timestamp);

    constructor(address _rewardToken, address _ve, address _pool, address _distribution, address _internal_bribe, 
        address _external_bribe, bool _isForPair, IGaugeManager.FarmingParam memory _farmingParam, address _bonusRewardToken, address _factory) {
        factory = _factory;
        rewardToken = IERC20(_rewardToken);     // main reward
        bonusRewardToken = IERC20(_bonusRewardToken);
        VE = _ve;                               // vested
        poolAddress = _pool;
        algebraPool = IAlgebraPool(_pool);
        DISTRIBUTION = _distribution;           // distro address (GaugeManager)
        DURATION = BlackTimeLibrary.WEEK;                   

        internal_bribe = _internal_bribe;       // lp fees goes here
        external_bribe = _external_bribe;       // bribe fees goes here
        isForPair = _isForPair;
        farmingParam = _farmingParam;
        farmingCenter = IFarmingCenter(farmingParam.farmingCenter);
        communityVault = IAlgebraCustomCommunityVault(algebraPool.communityVault());
        algebraEternalFarming = IAlgebraEternalFarming(farmingParam.algebraEternalFarming);
        nonfungiblePositionManager = INonfungiblePositionManager(farmingParam.nfpm);
        emergency = false;
    }

    modifier onlyDistribution() {
        require(msg.sender == DISTRIBUTION, "Caller is not RewardsDistribution contract");
        _;
    }

    modifier isNotEmergency() {
        require(emergency == false, "emergency");
        _;
    }

    function activateEmergencyMode() external onlyOwner {
        require(emergency == false, "emergency");
        emergency = true;
        emit EmergencyActivated(address(this), block.timestamp);
    }

    function stopEmergencyMode() external onlyOwner {

        require(emergency == true,"emergency");

        emergency = false;
        emit EmergencyDeactivated(address(this), block.timestamp);
    }

    function balanceOf(uint256 tokenId) external view returns (uint256) {
        (,,,,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
        return liquidity;
    }

    function earned(uint256 tokenId) external view returns (uint256 reward, uint256 bonusReward) {

        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        (reward, bonusReward) = IAlgebraEternalFarmingCustom(address(algebraEternalFarming)).getRewardInfo(incentivekey, tokenId);
        return (reward, bonusReward);
    }

    function deposit(uint256 tokenId) external nonReentrant isNotEmergency {
        require(msg.sender == nonfungiblePositionManager.ownerOf(tokenId));
        
        nonfungiblePositionManager.approveForFarming(tokenId, true, farmingParam.farmingCenter);

        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        farmingCenter.enterFarming(incentivekey, tokenId);
        emit Deposit(msg.sender, tokenId);
    }

    function withdraw(uint256 tokenId) external nonReentrant isNotEmergency {
        require(msg.sender == nonfungiblePositionManager.ownerOf(tokenId));
        
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        farmingCenter.exitFarming(incentivekey, tokenId);
        emit Withdraw(msg.sender, tokenId);
    }

    function getReward(uint256 tokenId, bool isBonusReward) public nonReentrant onlyDistribution {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = algebraEternalFarming.incentiveKeys(poolAddress);
        // add collectReward Flow...
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        (uint256 reward, uint256 bonusReward) = farmingCenter.collectRewards(incentivekey, tokenId);
        uint256 amountRequested = isBonusReward == false ? reward: bonusReward;
        farmingCenter.claimReward(isBonusReward == false ? rewardTokenAdd : bonusRewardTokenAdd , owner, amountRequested);
        emit Harvest(owner, amountRequested);
    }

    function notifyRewardAmount(address token, uint256 reward) external nonReentrant 
        isNotEmergency onlyDistribution returns (IncentiveKey memory, uint256, uint128) {
        require(token == address(rewardToken), "not rew token");
        // Transfer emission to Farming Virtual Pool address
        if (block.timestamp >= _periodFinish) {
            rewardRate = reward / DURATION;
        } else {
            uint256 remaining = _periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / DURATION;
        }
        _periodFinish = block.timestamp + DURATION;
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        bytes32 incentiveId = IncentiveId.compute(incentivekey);
        
        // set RewardRate to AlgebraVirtual Pool
        (,,address virtualPoolAddress,,,) = algebraEternalFarming.incentives(incentiveId);
        (,uint128 bonusRewardRate) = IAlgebraEternalVirtualPool(virtualPoolAddress).rewardRates();
        
        rewardToken.safeTransferFrom(DISTRIBUTION, address(this), reward);
        IERC20(token).safeApprove(farmingParam.algebraEternalFarming, reward);
        // transfer emission Reward to Algebra Virtual Pool
        algebraEternalFarming.addRewards(incentivekey, uint128(reward), 0);
        emit RewardAdded(reward);
        return(incentivekey, rewardRate, bonusRewardRate);
    }

    function gaugeBalances() external view returns (uint256 token0, uint256 token1){
        address _token0 = algebraPool.token0();
        address _token1 = algebraPool.token1();
        token0 = IERC20(_token0).balanceOf(address(this));
        token1 = IERC20(_token1).balanceOf(address(this));

        // IAlgebraCommunityVault(communityVault).
    }

    // function _getTokenBalancesFromCommunityVault() internal view returns (uint256 token0, uint256 token1){
    //     address _token0 = algebraPool.token0();
    //     address _token1 = algebraPool.token1();
    //     token0 = IERC20(_token0).balanceOf(communityVault);
    //     token1 = IERC20(_token1).balanceOf(communityVault);
    //     uint256 withdrawAmount = amount;
    //     if (_algebraFee != 0) {
    //     uint256 algebraFeeAmount = FullMath.mulDivRoundingUp(withdrawAmount, _algebraFee, ALGEBRA_FEE_DENOMINATOR);
    //     withdrawAmount -= algebraFeeAmount;
    //     }
    // }

    function claimFees() external nonReentrant returns (uint256 claimed0, uint256 claimed1) {
        return _claimFees();
    }

    function _claimFees() internal returns (uint256 claimed0, uint256 claimed1) {
        if (!isForPair) {
            return (0, 0);
        }
        
        address _token0 = algebraPool.token0();
        address _token1 = algebraPool.token1();
        // Fetch fee from the whole epoch which just eneded and transfer it to internal Bribe address.
        claimed0 = IERC20(_token0).balanceOf(address(this));
        claimed1 = IERC20(_token1).balanceOf(address(this));

        if (claimed0 > 0 || claimed1 > 0) {
            // Deduct dibsPercentage from fee accrued and transfer to dibs address(Foundation address)
            
            uint256 referralFee = IGaugeFactoryCL(factory).dibsPercentage();
            address dibs = IGaugeFactoryCL(factory).dibs();
            uint256 _dibsFeeToken0 = (dibs != address(0)) ? (claimed0 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;
            uint256 _dibsFeeToken1 = (dibs != address(0)) ? (claimed1 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;

            if (_dibsFeeToken0 > 0) {
                _safeTransfer(_token0, dibs, _dibsFeeToken0); // Transfer dibs fees
                claimed0 -= _dibsFeeToken0;
            }

            if (_dibsFeeToken1 > 0) {
                _safeTransfer(_token1, dibs, _dibsFeeToken1); // Transfer dibs fees
                claimed1 -= _dibsFeeToken1;
            }   

            uint256 _fees0 = claimed0;
            uint256 _fees1 = claimed1;

            if (_fees0  > 0) {
                IERC20(_token0).safeApprove(internal_bribe, 0);
                IERC20(_token0).safeApprove(internal_bribe, _fees0);
                IBribe(internal_bribe).notifyRewardAmount(_token0, _fees0);
            } 
            if (_fees1  > 0) {
                IERC20(_token1).safeApprove(internal_bribe, 0);
                IERC20(_token1).safeApprove(internal_bribe, _fees1);
                IBribe(internal_bribe).notifyRewardAmount(_token1, _fees1);
            } 
            emit ClaimFees(msg.sender, claimed0, claimed1);
        }
    }

    ///@notice get total reward for the duration
    function rewardForDuration() external view returns (uint256) {
        return rewardRate * DURATION;
    }

    ///@notice set new internal bribe contract (where to send fees)
    function setInternalBribe(address _int) external onlyOwner {
        require(_int >= address(0), "zero");
        internal_bribe = _int;
    }

    function _safeTransfer(address token,address to,uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function stakedFees() external view returns (uint256 totalFeeToken0, uint256 totalFeeToken1) {
        // Balance of token1/token1 at Gauge Address and AlgebraCommunityVault address.
        
        uint256 gaugeAccruedFeeToken0 = IERC20(algebraPool.token0()).balanceOf(address(this));
        uint256 gaugeAccruedFeeToken1 = IERC20(algebraPool.token1()).balanceOf(address(this));
        (uint256 communityVaultAccruedFeeToken0, uint256 communityVaultAccruedFeeToken1) 
                = getCommunityVaultAccruedFee();

        totalFeeToken0 = gaugeAccruedFeeToken0 + communityVaultAccruedFeeToken0;
        totalFeeToken1 = gaugeAccruedFeeToken1 + communityVaultAccruedFeeToken1;
        
        uint256 referralFee = IGaugeFactoryCL(factory).dibsPercentage();
        address dibs = IGaugeFactoryCL(factory).dibs();
        uint256 _dibsFeeToken0 = (dibs != address(0)) ? (totalFeeToken0 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;
        uint256 _dibsFeeToken1 = (dibs != address(0)) ? (totalFeeToken1 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;
        
        totalFeeToken0 -= _dibsFeeToken0;
        totalFeeToken1 -= _dibsFeeToken1;
    }

    function getCommunityVaultAccruedFee() internal view returns (uint256 communityVaultAccruedFeeToken0, uint256 communityVaultAccruedFeeToken1) {
        address communityVault = algebraPool.communityVault();
        communityVaultAccruedFeeToken0 = IERC20(algebraPool.token0()).balanceOf(communityVault);
        communityVaultAccruedFeeToken1 = IERC20(algebraPool.token1()).balanceOf(communityVault);

        (uint128 communityFeePending0, uint128 communityFeePending1) = algebraPool.getCommunityFeePending();
        communityVaultAccruedFeeToken0 += communityFeePending0;
        communityVaultAccruedFeeToken1 += communityFeePending1;

        uint16 algebraFee = IAlgebraCustomCommunityVault(communityVault).algebraFee();
        uint256 algebraFeeToken0 = communityVaultAccruedFeeToken0 * algebraFee / ALGEBRA_FEE_DENOMINATOR;
        uint256 algebraFeeToken1 = communityVaultAccruedFeeToken1 * algebraFee / ALGEBRA_FEE_DENOMINATOR;
        communityVaultAccruedFeeToken0 -= algebraFeeToken0;
        communityVaultAccruedFeeToken1 -= algebraFeeToken1;
    }

    ///@notice total supply held
    function totalSupply() public view returns (uint256 _totalSupply) {
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
            algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        bytes32 incentiveId = IncentiveId.compute(incentivekey);
        
        // set RewardRate to AlgebraVirtual Pool
        (,,address virtualPoolAddress,,,) = algebraEternalFarming.incentives(incentiveId);
        _totalSupply = IAlgebraEternalVirtualPool(virtualPoolAddress).currentLiquidity();    
    }

}


