// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "./IAutoVotingEscrow.sol";

interface IAutoVotingEscrowManager {
    function getTopPools() external view returns (address[] memory);
    function getVoteWeights() external view returns (uint[] memory);
    function topN() external view returns(uint256);
    function getTotalVotingPower() external view returns (uint256 _totalAVMVotingPower);
    function executor() external view returns (address);
    function getAVMs() external view returns (IAutoVotingEscrow[] memory);
    function tokenIdToAVMId(uint256 tokenId) external returns(uint256 avmIdx);
    function getOriginalOwner(uint256 tokenId) external view returns(address);
}
