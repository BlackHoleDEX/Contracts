// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

interface IAutoVotingEscrow {
    struct LockInfo {
        address owner;
        uint256 tokenId;
    }

    function acceptLock(address user, uint256 tokenId) external;
    function releaseLock(uint256 tokenId) external;
    function isFull() external view returns (bool);
    function lockOwner(uint256 tokenId) external view returns (address);
    function getLockCount() external view returns (uint256);
    function voteLocks (uint start, uint end) external;
    function resetLocks(uint start, uint end) external;
    function getTotalVotingPower() external view returns (uint256);
    function getLocks() external view returns (LockInfo[] memory);
}
