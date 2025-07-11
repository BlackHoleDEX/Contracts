// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;
import '@cryptoalgebra/integral-farming/contracts/base/IncentiveKey.sol';

interface IGaugeCL {
    function notifyRewardAmount(address token, uint amount) external returns (IncentiveKey memory incentivekey, uint256 rewardRate, uint128 bonusRewardRate);
    function getReward(uint256 tokenId, bool isBonusReward) external;
    function claimFees() external returns (uint claimed0, uint claimed1);
    function balanceOf(uint256 tokenId) external view returns (uint256); 
    function emergency() external returns (bool);

    function earned(uint256 tokenId) external view returns (uint256 reward, uint256 bonusReward);   
    function totalSupply() external view returns (uint);
    function rewardRate() external view returns (uint);
    function rewardForDuration() external view returns (uint256);
    function stakedFees() external view returns (uint256, uint256);
}