// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./interfaces/IVotingEscrow.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingEscrowSplitHelper
contract VotingEscrowSplitHelper is Ownable {
    address public immutable votingEscrowAddress;
    
    /// @notice Maximum value for int128 (2^127 - 1)
    /// @dev This is the maximum positive value that can fit in int128
    uint256 public constant MAX_INT128_UINT = uint256(2**127 - 1);

    /// @notice Maximum amount that can be split
    uint256 public maxSplitAmount;

    /// @notice Mapping to track canSplit permissions (maintained locally)
    mapping(address => bool) public canSplit;
    
    /// @notice Emitted when canSplit permission is updated
    event CanSplitUpdated(address indexed account, bool enabled);


    /// @notice Constructor
    /// @param _votingEscrow Address of the VotingEscrow contract
    constructor(address _votingEscrow) {
        require(_votingEscrow != address(0), "ZA");
        votingEscrowAddress = _votingEscrow;
        maxSplitAmount = 10_000_000 * 1e18;
    }


    /// @notice Manage canSplit permission (team only)
    /// @param _account Address to grant/revoke canSplit permission
    /// @param _bool True to grant, false to revoke
    function toggleSplit(address _account, bool _bool) external onlyOwner {
        canSplit[_account] = _bool;
        emit CanSplitUpdated(_account, _bool);
    }

    /*//////////////////////////////////////////////////////////////
                         SPLIT FUNCTION WITH PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Split a veNFT with overflow protection
    /// @param _from Token ID to split from
    /// @param _amount Amount to split (raw amount, bonus calculated internally)
    /// @return _tokenId1 Token ID of the remaining lock
    /// @return _tokenId2 Token ID of the split lock
    function split(
        uint _from,
        uint _amount
    ) external returns (uint256 _tokenId1, uint256 _tokenId2) {
        require(canSplit[msg.sender] || canSplit[address(0)], "!SPLIT");
        // Check: ensure amount doesn't exceed int128 max (2^127 - 1)
        // This prevents overflow when casting to int128 in the original split function
        require(_amount <= maxSplitAmount, "BIGVAL");
        require(IVotingEscrow(votingEscrowAddress).isApprovedOrOwner(msg.sender, _from), "NAO");
        // Call the original split function through votingEscrow
        (_tokenId1, _tokenId2) = IVotingEscrow(votingEscrowAddress).split(_from, _amount);
    }

    function setMaxSplitAmount(uint256 _maxSplitAmount) external onlyOwner {
        require(_maxSplitAmount <= MAX_INT128_UINT, "OVERFLOW");
        maxSplitAmount = _maxSplitAmount;
    }
}