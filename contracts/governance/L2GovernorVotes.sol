// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
// OpenZeppelin Contracts (last updated v4.6.0) (governance/extensions/GovernorVotes.sol)

pragma solidity ^0.8.0;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {L2Governor} from "contracts/governance/L2Governor.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

/**
 * @author Modified from RollCall (https://github.com/withtally/rollcall/blob/main/src/standards/L2GovernorVotes.sol)
 *
 * @dev Extension of {Governor} for voting weight extraction from an {ERC20Votes} token, or since v4.5 an {ERC721Votes} token.
 *
 * _Available since v4.3._
 */
abstract contract L2GovernorVotes is L2Governor {
    IVotes public immutable token;

    constructor(IVotes tokenAddress) {
        token = tokenAddress;
    }

    /**
     * Read the voting weight from the token's built in snapshot mechanism (see {Governor-_getVotes}).
     */
    function _getVotes(
        address account,
        uint256 tokenId,
        uint256 blockTimestamp,
        bytes memory /*params*/
    ) internal view virtual override returns (uint256) {
        IVotingEscrow votingEscrow = IVotingEscrow(address(token));
        address owner = votingEscrow.ownerOf(tokenId);
        if (owner != account) {
            return 0;
        }
        return getSMNFTBalance(tokenId, blockTimestamp, votingEscrow);
    }

    function getSMNFTBalance(uint tokenId, uint _t, IVotingEscrow votingEscrow) internal view returns (uint256) {
        uint256 epoch = votingEscrow.user_point_epoch(tokenId);
        
        // If no checkpoints exist, return 0
        if (epoch == 0) {
            return 0;
        }

        // Get the first checkpoint
        IVotingEscrow.Point memory firstPoint = votingEscrow.user_point_history(tokenId, 0);
        
        // If the requested time is before the first checkpoint, return 0
        if (firstPoint.ts > _t) {
            return 0;
        }

        // If the requested time is after the last checkpoint, return the last checkpoint's balance
        IVotingEscrow.Point memory lastPoint = votingEscrow.user_point_history(tokenId, epoch - 1);
        if (lastPoint.ts <= _t) {
            return lastPoint.smNFT + lastPoint.smNFTBonus;
        }

        // Binary search for the checkpoint
        uint256 lower = 0;
        uint256 upper = epoch - 1;
        
        while (upper > lower) {
            uint256 center = lower + (upper - lower + 1) / 2; // Avoid overflow
            IVotingEscrow.Point memory userPoint = votingEscrow.user_point_history(tokenId, center);
            
            if (userPoint.ts <= _t) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }

        // Get the found checkpoint
        IVotingEscrow.Point memory userPoint = votingEscrow.user_point_history(tokenId, lower);
        return userPoint.smNFT + userPoint.smNFTBonus;
    }
}
