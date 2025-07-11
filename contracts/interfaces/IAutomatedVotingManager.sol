// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IAutomatedVotingManager {
    function originalOwner(uint256 tokenId) external view returns(address);
    function setOriginalOwner(uint256 tokenId, address owner) external;
    function topN() external view returns(uint256);
    function tokenIndexes(uint256 _index) external view returns (uint256);
    function tokenIdsLength() external view returns(uint256);
    function tokenIds(uint256 _index) external view returns (uint256);
    function getTotalVotingPower() external view returns (uint256 _totalAVMVotingPower);
    function executor() external view returns (address);
}
