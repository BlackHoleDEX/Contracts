

// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IBribeFull {

    function _deposit(uint amount, uint tokenId) external;
    function _withdraw(uint amount, uint tokenId) external;
    function getRewardForOwner(uint tokenId, address[] memory tokens) external;
    function notifyRewardAmount(address token, uint amount) external;
    function left(address token) external view returns (uint);
    function rewardsListLength() external view returns (uint);
    function supplyNumCheckpoints() external view returns (uint);
    function getEpochStart(uint timestamp) external pure returns (uint);
    function getPriorSupplyIndex(uint timestamp) external view returns (uint);
    function bribeTokens(uint index) external view returns (address);
    function rewardsPerEpoch(address token,uint ts) external view returns (uint);
    function supplyCheckpoints(uint _index) external view returns(uint timestamp, uint supplyd);
    function earned(address token, uint tokenId) external view returns (uint);
    function earned(uint tokenId, address token) external view returns (uint);
    function firstBribeTimestamp() external view returns(uint);
    function totalSupplyAt(uint256 _timestamp) external view returns (uint256);

}