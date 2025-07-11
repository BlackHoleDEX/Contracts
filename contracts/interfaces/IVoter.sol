// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IVoter {

    function _ve() external view returns (address);
    function factories() external view returns(address[] memory);
    function usedWeights(uint id) external view returns(uint);
    function lastVoted(uint id) external view returns(uint);
    function poolVote(uint id, uint _index) external view returns(address _pair);
    function votes(uint id, address _pool) external view returns(uint votes);
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;
    function poolVoteLength(uint tokenId) external view returns(uint);
    function lastVotedTimestamp(uint id) external view returns(uint);
    function length() external view returns (uint);
    function weights(address _pool) external view returns(uint);
    function poke(uint256 _tokenId) external;
    function getEpochGovernor() external view returns (address);
    function setEpochGovernor(address _epochGovernor) external;
    function reset(uint256 _tokenId) external;
    function totalWeight() external returns (uint256);
}
