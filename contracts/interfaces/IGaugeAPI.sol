// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IGaugeAPI {
    function notifyRewardAmount(address token, uint amount) external;
    function getReward(address account, address[] memory tokens) external;
    function claimFees() external returns (uint claimed0, uint claimed1);
    function left(address token) external view returns (uint);
    function rewardRate() external view returns (uint);
    function balanceOf(address _account) external view returns (uint);
    function isForPair() external view returns (bool);
    function totalSupply() external view returns (uint);
    function earned(address account) external view returns (uint);
    function setGenesisPool(address genesisPool) external;
    function depositsForGenesis(address tokenOwner, uint256 timestamp, uint256 liquidity) external;
    function rewardForDuration() external view returns (uint256);
    function maturityTime(address _account) external view returns (uint256);
}
