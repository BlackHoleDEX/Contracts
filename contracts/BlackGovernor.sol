// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import {IGovernor} from "./governance/IGovernor.sol";
import {IBlackHoleVotes} from "./interfaces/IBlackHoleVotes.sol";
import {IBlackGovernor} from "./interfaces/IBlackGovernor.sol";
import {L2Governor, L2GovernorCountingSimple, L2GovernorVotes, L2GovernorVotesQuorumFraction} from "./governance/Governor.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract BlackGovernor is
    L2Governor,
    L2GovernorCountingSimple,
    L2GovernorVotes,
    L2GovernorVotesQuorumFraction
{
    bytes4 public constant NUDGE_SELECTOR = IMinter.nudge.selector;
    bytes4 public constant NUDGE_OPTIONS_SELECTOR = bytes4(keccak256("nudge(int256,int256)"));
    bytes4 public constant SET_GOVERNANCE_PARAMETERS_SELECTOR =
        bytes4(keccak256("setGovernanceParameters(uint256,uint256,int256,int256,uint256)"));
    int256 public constant DEFAULT_MIN_NUDGE_DELTA_BPS = -500; // -5%
    int256 public constant DEFAULT_MAX_NUDGE_DELTA_BPS = 500; // +5%
    int256 public constant MIN_NUDGE_DELTA_BPS_LIMIT = -10_000; // -100%
    int256 public constant MAX_NUDGE_DELTA_BPS_LIMIT = 10_000; // +100%

    uint256 public constant MAX_PROPOSAL_NUMERATOR = 100; // max 10%
    uint256 public constant MAX_QUORUM_NUMERATOR = 50; // max 50%
    uint256 public constant PROPOSAL_DENOMINATOR = 1000;
    uint256 public constant MAX_ALLOWED_PROPOSAL_EPOCHS_AHEAD = 3;
    uint256 public constant MIN_VOTING_DELAY = 1 minutes;
    uint256 public constant MAX_VOTING_DELAY = 1 days;
    uint256 public constant ACTIVE_CANCEL_MAX_QUORUM_FRACTION_DENOMINATOR = 4;
    uint256 private VOTING_DELAY = 1 minutes;
    uint256 public proposalNumerator = 2; // start at 0.2%
    address public minter;
    int256 public minNudgeDeltaBps;
    int256 public maxNudgeDeltaBps;
    IBlackGovernor.ProposalResult public result;

    // Cached per proposal because _winningOption only receives proposalId and needs deltas for tie resolution.
    mapping(uint256 => bool) private _isNudgeProposal;
    mapping(uint256 => int256) private _proposalOption1DeltaBps;
    mapping(uint256 => int256) private _proposalOption2DeltaBps;

    constructor(
        IBlackHoleVotes _ve,
        address _minter
    )
        L2Governor("Black Governor")
        L2GovernorVotes(_ve)
        L2GovernorVotesQuorumFraction(4) // 4%
    {
        minter = _minter;
        minNudgeDeltaBps = DEFAULT_MIN_NUDGE_DELTA_BPS;
        maxNudgeDeltaBps = DEFAULT_MAX_NUDGE_DELTA_BPS;
    }

    function votingDelay() public view override(IGovernor) returns (uint256) {
        return VOTING_DELAY; // 1 block
    }

    function votingPeriod() public view override(IGovernor) returns (uint256) {
        return BlackTimeLibrary.epochVoteEnd(block.timestamp);
    }

    /// @inheritdoc L2Governor
    /// @dev Vote ends at `epochVoteEnd` in the epoch before the target. {propose} requires `epochStart >= nextEpochStart`,
    ///      so `targetEpochStart - 1` is always valid for `_execute`'s `active_period < targetEpoch`.
    function _proposalVoteEnd(bytes32 epochTimeHash) internal pure override returns (uint256) {
        uint256 targetEpochTimestamp = uint256(epochTimeHash);
        uint256 targetEpochStart = BlackTimeLibrary.epochStart(targetEpochTimestamp);
        return BlackTimeLibrary.epochVoteEnd(targetEpochStart - 1);
    }

    /// @dev Unified governance-controlled parameters update path.
    ///      Must be executed via a successful governance proposal targeting this contract.
    function setGovernanceParameters(
        uint256 proposalNumeratorValue,
        uint256 quorumNumeratorValue,
        int256 minDeltaBps,
        int256 maxDeltaBps,
        uint256 votingDelayValue
    ) external onlyGovernance {
        _validateGovernanceParameters(
            proposalNumeratorValue,
            quorumNumeratorValue,
            minDeltaBps,
            maxDeltaBps,
            votingDelayValue
        );
        proposalNumerator = proposalNumeratorValue;
        _updateQuorumNumerator(quorumNumeratorValue);
        minNudgeDeltaBps = minDeltaBps;
        maxNudgeDeltaBps = maxDeltaBps;
        VOTING_DELAY = votingDelayValue;
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

    /// @dev `epochTimeHash` is the start of the target epoch from which this proposal's effect
    ///      (e.g. an emission nudge) becomes active — the same normalized `epochStart` value used
    ///      to identify the proposal in `propose`/`hashProposal`, not the epoch voting happens in.
    ///      Voting always closes 1 hour before this epoch starts (see `_proposalVoteEnd`), so a
    ///      proposal can only be `Active` while `epochStart(block.timestamp)` is strictly before
    ///      `epochTimeHash`; by the time the target epoch actually begins the proposal has already
    ///      moved to `Succeeded`/`Expired`, which the `Pending || Active` check below rejects.
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes32 epochTimeHash
    ) public virtual override returns (uint256 proposalId) {
        address proposer = msg.sender;
        uint256 _proposalId = hashProposal(
            targets,
            values,
            epochTimeHash
        );
        ProposalState proposalState = state(_proposalId);
        require(
            proposalState == ProposalState.Pending || proposalState == ProposalState.Active,
            "Governor: too late to cancel"
        );
        require(
            proposer == _proposals[_proposalId].proposer,
            "Governor: only proposer can cancel"
        );

        // During Active, proposer cancellation is allowed only with strictly less than 1/4 quorum participation.
        if (proposalState == ProposalState.Active) {
            (uint256 option1Votes, uint256 option2Votes, uint256 option3Votes) = proposalVotes(_proposalId);
            uint256 votesCast = option1Votes + option2Votes + option3Votes;

            uint256 requiredQuorum = quorum(proposalSnapshot(_proposalId));
            require(
                votesCast * ACTIVE_CANCEL_MAX_QUORUM_FRACTION_DENOMINATOR < requiredQuorum,
                "GovernorSimple: cancel threshold exceeded"
            );
        }

        return _cancel(targets, values, epochTimeHash);
    }

    /// @dev `blockTimestamp` is ignored — unlike OpenZeppelin's Governor, quorum here is not
    ///      snapshotted at proposal creation. `getsmNFTPastTotalSupply`/`calculate_sm_nft_bonus`
    ///      always read current on-chain state, so this always returns the quorum as of
    ///      `block.timestamp`, regardless of which timepoint (e.g. `proposalSnapshot`) is passed in.
    function quorum(uint256 blockTimestamp) public view override (L2GovernorVotesQuorumFraction, IGovernor) returns (uint256) {
        uint totalSMNftVote = token.getsmNFTPastTotalSupply();
        uint totalSMNftVotePlusBonus = totalSMNftVote + token.calculate_sm_nft_bonus(totalSMNftVote);
        return (totalSMNftVotePlusBonus * quorumNumerator()) / quorumDenominator();
    }

    /// @dev `epochTime` identifies the epoch in which this proposal's effect (e.g. a nudge or
    ///      governance parameter change) should take effect once executed, so it must be
    ///      resolved by governance before that epoch begins. It is normalized to `epochStart`
    ///      and must be at least `nextEpochStart` (can't target the current epoch) and no more
    ///      than `MAX_ALLOWED_PROPOSAL_EPOCHS_AHEAD` epochs out. Voting therefore closes at
    ///      `_proposalVoteEnd`, 1 hour before the target epoch starts (i.e. the vote-end of the
    ///      epoch immediately preceding it), leaving the full target epoch to act on the outcome.
    function propose(
        uint256 tokenId,
        uint256 epochTime,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual returns (uint256) {
        uint256 currentEpochStart = BlackTimeLibrary.epochStart(block.timestamp);
        uint256 nextEpochStart = BlackTimeLibrary.epochNext(currentEpochStart);
        uint256 epochLength = nextEpochStart - currentEpochStart;
        bytes32 epochStart = bytes32(BlackTimeLibrary.epochStart(epochTime));
        require(uint256(epochStart) >= nextEpochStart, "GovernorSimple: epoch before next");
        require(
            uint256(epochStart) <= currentEpochStart + (epochLength * MAX_ALLOWED_PROPOSAL_EPOCHS_AHEAD),
            "GovernorSimple: epoch too far"
        );

        require(targets.length == 1, "GovernorSimple: only one target allowed");
        require(values.length == 1, "GovernorSimple: only one value allowed");
        require(values[0] == 0, "GovernorSimple: value must be 0");
        require(calldatas.length == 1, "GovernorSimple: only one calldata allowed");
        address target = targets[0];
        require(target == minter || target == address(this), "GovernorSimple: only minter or governor allowed");

        int256 option1DeltaBps;
        int256 option2DeltaBps;
        if (target == minter) {
            (option1DeltaBps, option2DeltaBps) = _validateNudgeAndDecode(calldatas[0]);
        } else {
            _validateGovernanceParamsCalldata(calldatas[0]);
        }

        uint256 proposalId = hashProposal(targets, values, epochStart);
        // Allow re-proposal for the same epoch hash after explicit cancellation.
        // Core governor keeps canceled proposals "locked"; this local reset restores
        // the one-proposal-per-epoch lane for a fresh attempt.
        if (_proposals[proposalId].canceled) {
            delete _proposals[proposalId];
        }

        proposalId = _proposal(tokenId, targets, values, calldatas, description, epochStart);
        if (target == minter) {
            _isNudgeProposal[proposalId] = true;
            _proposalOption1DeltaBps[proposalId] = option1DeltaBps;
            _proposalOption2DeltaBps[proposalId] = option2DeltaBps;
        }
        return proposalId;
    }

    function propose(
        uint256 tokenId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {
        uint256 epochTime = BlackTimeLibrary.epochNext(block.timestamp);
        return propose(tokenId, epochTime, targets, values, calldatas, description);
    }

    /// @dev Validates that a nudge proposal's calldata is the `nudge(int256,int256)` options
    ///      container (68 bytes: 4-byte selector + two int256 deltas), decodes the two candidate
    ///      deltas, and enforces both fall within the current [minNudgeDeltaBps, maxNudgeDeltaBps]
    ///      guardrail so neither ballot option can exceed what governance currently allows.
    function _validateNudgeAndDecode(
        bytes memory payload
    ) internal view returns (int256 option1DeltaBps, int256 option2DeltaBps) {
        require(bytes4(payload) == NUDGE_OPTIONS_SELECTOR, "GovernorSimple: only nudge allowed");
        require(payload.length == 68, "GovernorSimple: invalid nudge calldata");
        (option1DeltaBps, option2DeltaBps) = _decodeNudgeOptions(payload);
        require(option1DeltaBps >= minNudgeDeltaBps, "GovernorSimple: option1 too low");
        require(option1DeltaBps <= maxNudgeDeltaBps, "GovernorSimple: option1 too high");
        require(option2DeltaBps >= minNudgeDeltaBps, "GovernorSimple: option2 too low");
        require(option2DeltaBps <= maxNudgeDeltaBps, "GovernorSimple: option2 too high");
    }

    /// @dev Validates that a governance-params proposal's calldata is the
    ///      `setGovernanceParameters(uint256,uint256,int256,int256,uint256)` call (164 bytes:
    ///      4-byte selector + five 32-byte words), decodes the five values via raw `mload`
    ///      (offsets step by 0x20 after skipping the 0x20 length word + 0x04 selector:
    ///      0x24 proposalNumerator, 0x44 quorumNumerator, 0x64 minDeltaBps, 0x84 maxDeltaBps,
    ///      0xA4 votingDelay), and forwards them to `_validateGovernanceParameters` for bounds checks.
    function _validateGovernanceParamsCalldata(
        bytes memory payload
    ) internal pure {
        require(
            bytes4(payload) == SET_GOVERNANCE_PARAMETERS_SELECTOR,
            "GovernorSimple: only params update allowed"
        );
        require(payload.length == 164, "GovernorSimple: invalid params calldata");

        uint256 proposalNumeratorValue;
        uint256 quorumNumeratorValue;
        int256 minDeltaBps;
        int256 maxDeltaBps;
        uint256 votingDelayValue;
        assembly {
            proposalNumeratorValue := mload(add(payload, 0x24))
            quorumNumeratorValue := mload(add(payload, 0x44))
            minDeltaBps := mload(add(payload, 0x64))
            maxDeltaBps := mload(add(payload, 0x84))
            votingDelayValue := mload(add(payload, 0xA4))
        }

        _validateGovernanceParameters(
            proposalNumeratorValue,
            quorumNumeratorValue,
            minDeltaBps,
            maxDeltaBps,
            votingDelayValue
        );
    }

    function _validateGovernanceParameters(
        uint256 proposalNumeratorValue,
        uint256 quorumNumeratorValue,
        int256 minDeltaBps,
        int256 maxDeltaBps,
        uint256 votingDelayValue
    ) internal pure {
        require(proposalNumeratorValue <= MAX_PROPOSAL_NUMERATOR, "numerator too high");
        require(quorumNumeratorValue <= MAX_QUORUM_NUMERATOR, "quorum too high");
        require(votingDelayValue >= MIN_VOTING_DELAY, "voting delay too low");
        require(votingDelayValue <= MAX_VOTING_DELAY, "voting delay too high");
        require(minDeltaBps >= MIN_NUDGE_DELTA_BPS_LIMIT, "min delta too low");
        require(maxDeltaBps <= MAX_NUDGE_DELTA_BPS_LIMIT, "max delta too high");
        // require(minDeltaBps <= 0, "min must be <= 0");
        // require(maxDeltaBps >= 0, "max must be >= 0");
        require(minDeltaBps < maxDeltaBps, "invalid bounds");
    }

    /// @dev Extracts the two int256 deltas from a `nudge(int256,int256)` payload via raw `mload`,
    ///      skipping the 32-byte length prefix and 4-byte selector: bytes [0x24, 0x44) are
    ///      option1DeltaBps, bytes [0x44, 0x64) are option2DeltaBps.
    function _decodeNudgeOptions(bytes memory payload) private pure returns (int256 option1DeltaBps, int256 option2DeltaBps) {
        assembly {
            option1DeltaBps := mload(add(payload, 0x24))
            option2DeltaBps := mload(add(payload, 0x44))
        }
    }

    /// @dev Extracts the five `setGovernanceParameters` args from its payload via raw `mload`,
    ///      same layout as `_validateGovernanceParamsCalldata`: 0x24 proposalNumerator,
    ///      0x44 quorumNumerator, 0x64 minDeltaBps, 0x84 maxDeltaBps, 0xA4 votingDelay.
    function _decodeGovernanceParams(bytes memory payload) private pure returns (
        uint256 proposalNumeratorValue,
        uint256 quorumNumeratorValue,
        int256 minDeltaBps,
        int256 maxDeltaBps,
        uint256 votingDelayValue
    ) {
        assembly {
            proposalNumeratorValue := mload(add(payload, 0x24))
            quorumNumeratorValue := mload(add(payload, 0x44))
            minDeltaBps := mload(add(payload, 0x64))
            maxDeltaBps := mload(add(payload, 0x84))
            votingDelayValue := mload(add(payload, 0xA4))
        }
    }

    /// @dev For nudge proposals only, ties are resolved by preferring lower inflation.
    function _winningOption(uint256 proposalId) internal view override returns (uint8) {
        uint8 strictWinner = super._winningOption(proposalId);
        if (strictWinner != 3 || !_isNudgeProposal[proposalId]) {
            return strictWinner;
        }

        (uint256 option1Votes, uint256 option2Votes, uint256 option3Votes) = proposalVotes(proposalId);
        uint256 maxVotes = option1Votes;
        if (option2Votes > maxVotes) maxVotes = option2Votes;
        if (option3Votes > maxVotes) maxVotes = option3Votes;
        if (maxVotes == 0) {
            return 3;
        }

        int256 maxDelta = type(int256).max;
        int256 option1Delta = option1Votes == maxVotes ? _proposalOption1DeltaBps[proposalId] : maxDelta;
        int256 option2Delta = option2Votes == maxVotes ? _proposalOption2DeltaBps[proposalId] : maxDelta;
        int256 option3Delta = option3Votes == maxVotes ? int256(0) : maxDelta;

        if (option1Delta <= option2Delta && option1Delta <= option3Delta) return 0;
        if (option2Delta <= option3Delta) return 1;
        return 2;
    }

    /// @dev For generic governor-parameter proposals, only Option1 is treated as passing.
    ///      Nudge proposals keep the 3-option behavior from L2GovernorCountingSimple + tie-break rules above.
    function _voteSucceeded(uint256 proposalId) internal view override(L2Governor, L2GovernorCountingSimple) returns (bool) {
        if (_isNudgeProposal[proposalId]) {
            return super._voteSucceeded(proposalId);
        }
        return _winningOption(proposalId) == 0;
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 epochTimeHash
    ) internal virtual override {
        string memory errorMessage = "Governor: call reverted without message";
        uint8 winningOption = _winningOption(proposalId);
        result = winningOption < 3 ? IBlackGovernor.ProposalResult(winningOption + 1) : IBlackGovernor.ProposalResult.None;
        // All proposals are epoch-bound and must execute before minter flips into that target epoch.
        require(IMinter(minter).active_period() < uint256(epochTimeHash), "GovernorSimple: epoch flipped");

        for (uint256 i = 0; i < targets.length; ++i) {
            // `calldatas` here is the proposer's original submission stored at propose() time
            // (see `execute` in Governor.sol), already shape/selector-validated there by
            // `_validateNudgeAndDecode`/`_validateGovernanceParamsCalldata` — no caller-supplied
            // calldata reaches this point, so no selector allowlist check is needed here.
            bytes memory execCalldata = calldatas[i];
            bytes4 selector = bytes4(calldatas[i]);

            if (selector == NUDGE_OPTIONS_SELECTOR) {
                (int256 option1DeltaBps, int256 option2DeltaBps) = _decodeNudgeOptions(calldatas[i]);
                int256 selectedDeltaBps = result == IBlackGovernor.ProposalResult.Option1
                    ? option1DeltaBps
                    : result == IBlackGovernor.ProposalResult.Option2
                    ? option2DeltaBps
                    : int256(0);

                execCalldata = abi.encodeWithSelector(NUDGE_SELECTOR, selectedDeltaBps);
            } else {
                (
                    uint256 proposalNumeratorValue,
                    uint256 quorumNumeratorValue,
                    int256 minDeltaBps,
                    int256 maxDeltaBps,
                    uint256 votingDelayValue
                ) = _decodeGovernanceParams(calldatas[i]);

                execCalldata = abi.encodeWithSelector(
                    SET_GOVERNANCE_PARAMETERS_SELECTOR,
                    proposalNumeratorValue,
                    quorumNumeratorValue,
                    minDeltaBps,
                    maxDeltaBps,
                    votingDelayValue
                );
            }

            (bool success, bytes memory returndata) = targets[i].call{value: values[i]}(execCalldata);
            Address.verifyCallResult(success, returndata, errorMessage);
        }
    }

}
