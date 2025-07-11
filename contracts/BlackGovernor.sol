// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import {IGovernor} from "./governance/IGovernor.sol";
import {IBlackHoleVotes} from "./interfaces/IBlackHoleVotes.sol";
import {L2Governor, L2GovernorCountingSimple, L2GovernorVotes, L2GovernorVotesQuorumFraction} from "./governance/Governor.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

contract BlackGovernor is
    L2Governor,
    L2GovernorCountingSimple,
    L2GovernorVotes,
    L2GovernorVotesQuorumFraction
{
    address public team;
    uint256 public constant MAX_PROPOSAL_NUMERATOR = 100; // max 10%
    uint256 public constant PROPOSAL_DENOMINATOR = 1000;
    uint256 private VOTING_DELAY = 3600;
    uint256 public proposalNumerator = 2; // start at 0.02%
    address public minter;

    constructor(
        IBlackHoleVotes _ve,
        address _minter
    )
        L2Governor("Black Governor")
        L2GovernorVotes(_ve)
        L2GovernorVotesQuorumFraction(4) // 4%
    {
        minter = _minter;
        team = msg.sender;
    }

    function votingDelay() public view override(IGovernor) returns (uint256) {
        return VOTING_DELAY; // 1 block
    }

    function votingPeriod() public view override(IGovernor) returns (uint256) {
        return BlackTimeLibrary.epochVoteEnd(block.timestamp);
    }

    function setTeam(address newTeam) external {
        require(msg.sender == team, "not team");
        team = newTeam;
    }

    function setVotingDelay(uint256 delay) external {
        require(msg.sender == team, "not team");
        VOTING_DELAY = delay;
    }

    function setProposalNumerator(uint256 numerator) external {
        require(msg.sender == team, "not team");
        require(numerator <= MAX_PROPOSAL_NUMERATOR, "numerator too high");
        proposalNumerator = numerator;
    }

    function proposalThreshold()
        public
        view
        override(L2Governor)
        returns (uint256)
    {
        uint totalSMNftVote = token.getsmNFTPastTotalSupply();
        uint totalSMNftVotePlusBonus = totalSMNftVote + token.calculate_sm_nft_bonus(totalSMNftVote);
        return
            ( totalSMNftVotePlusBonus * proposalNumerator) /
            PROPOSAL_DENOMINATOR;
    }

    function clock() public view override returns (uint48) {}

    function CLOCK_MODE() public view override returns (string memory) {}

    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 epochTimeHash
    ) public virtual override returns (uint256 proposalId) {
        address proposer = msg.sender;
        uint256 _proposalId = hashProposal(
            targets,
            values,
            calldatas,
            epochTimeHash
        );
        require(
            state(_proposalId) == ProposalState.Pending,
            "Governor: too late to cancel"
        );
        require(
            proposer == _proposals[_proposalId].proposer,
            "Governor: only proposer can cancel"
        );
        return _cancel(targets, values, calldatas, epochTimeHash);
    }

    function quorum(uint256 blockTimestamp) public view override (L2GovernorVotesQuorumFraction, IGovernor) returns (uint256) {
        uint totalSMNftVote = token.getsmNFTPastTotalSupply();
        uint totalSMNftVotePlusBonus = totalSMNftVote + token.calculate_sm_nft_bonus(totalSMNftVote);
        return (totalSMNftVotePlusBonus * quorumNumerator()) / quorumDenominator();
    }

    function propose(
        uint256 tokenId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {

        require(targets.length == 1, "GovernorSimple: only one target allowed");
        require(address(targets[0]) == minter, "GovernorSimple: only minter allowed");
        require(calldatas.length == 1, "GovernorSimple: only one calldata allowed");
        require(bytes4(calldatas[0]) == IMinter.nudge.selector, "GovernorSimple: only nudge allowed");
        return _proposal(tokenId, targets, values, calldatas, description);
    }

}
