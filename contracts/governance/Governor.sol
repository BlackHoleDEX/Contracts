// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC6372.sol";
import "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Timers.sol";
import "./IGovernor.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IBlackHoleVotes} from "../interfaces/IBlackHoleVotes.sol";
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";




/**
 * @author Modified from RollCall (https://github.com/withtally/rollcall/blob/main/src/standards/L2Governor.sol)
 *
 * @dev Core of the governance system, designed to be extended though various modules.
 *
 * This contract is abstract and requires several function to be implemented in various modules:
 *
 * - A counting module must implement {quorum}, {_quorumReached}, {_voteSucceeded} and {_countVote}
 * - A voting module must implement {_getVotes}
 * - Additionanly, the {votingPeriod} must also be implemented
 *
 * _Available since v4.3._
 */
abstract contract L2Governor is Context, ERC165, EIP712, IGovernor, IERC721Receiver, IERC1155Receiver {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeCast for uint256;
    using Timers for Timers.Timestamp;

    bytes32 public constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId,uint8 support)");
    bytes32 public constant EXTENDED_BALLOT_TYPEHASH =
        keccak256("ExtendedBallot(uint256 proposalId,uint8 support,string reason,bytes params)");

    struct ProposalCore {
        address proposer;
        Timers.Timestamp voteStart;
        Timers.Timestamp voteEnd;
        bool executed;
        bool canceled;
    }

    string private _name;
    
    ProposalState public status;

    mapping(uint256 => ProposalCore) public _proposals;

    // This queue keeps track of the governor operating on itself. Calls to functions protected by the
    // {onlyGovernance} modifier needs to be whitelisted in this queue. Whitelisting is set in {_beforeExecute},
    // consumed by the {onlyGovernance} modifier and eventually reset in {_afterExecute}. This ensures that the
    // execution of {onlyGovernance} protected calls can only be achieved through successful proposals.
    DoubleEndedQueue.Bytes32Deque private _governanceCall;

    /**
     * @dev Restricts a function so it can only be executed through governance proposals. For example, governance
     * parameter setters in {GovernorSettings} are protected using this modifier.
     *
     * The governance executing address may be different from the Governor's own address, for example it could be a
     * timelock. This can be customized by modules by overriding {_executor}. The executor is only able to invoke these
     * functions during the execution of the governor's {execute} function, and not under any other circumstances. Thus,
     * for example, additional timelock proposers are not able to change governance parameters without going through the
     * governance protocol (since v4.6).
     */
    modifier onlyGovernance() {
        require(msg.sender == _executor(), "Governor: onlyGovernance");
        if (_executor() != address(this)) {
            bytes32 msgDataHash = keccak256(_msgData());
            // loop until popping the expected operation - throw if deque is empty (operation not authorized)
            while (_governanceCall.popFront() != msgDataHash) {}
        }
        _;
    }

    /**
     * @dev Sets the value for {name} and {version}
     */
    constructor(string memory name_) EIP712(name_, version()) {
        
        _name = name_;
    }

    /**
     * @dev Function to receive ETH that will be handled by the governor (disabled if executor is a third party contract)
     */
    receive() external payable virtual {
        require(_executor() == address(this));
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC165) returns (bool) {
        // In addition to the current interfaceId, also support previous version of the interfaceId that did not
        // include the castVoteWithReasonAndParams() function as standard
        return
            interfaceId ==
            (type(IGovernor).interfaceId ^
                type(IERC6372).interfaceId ^
                this.castVoteWithReasonAndParams.selector ^
                this.castVoteWithReasonAndParamsBySig.selector ^
                this.getVotesWithParams.selector) ||
            // Previous interface for backwards compatibility
            interfaceId == (type(IGovernor).interfaceId ^ type(IERC6372).interfaceId) ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IGovernor-name}.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IGovernor-version}.
     */
    function version() public view virtual override returns (string memory) {
        return "1";
    }

    /**
     * @dev See {IGovernor-hashProposal}.
     *
     * The proposal id is produced by hashing the RLC encoded `targets` array, the `values` array, the `calldatas` array
     * and the descriptionHash (bytes32 which itself is the keccak256 hash of the description string). This proposal id
     * can be produced from the proposal data which is part of the {ProposalCreated} event. It can even be computed in
     * advance, before the proposal is submitted.
     *
     * Note that the chainId and the governor address are not part of the proposal id computation. Consequently, the
     * same proposal (with same operation and same description) will have the same id if submitted on multiple governors
     * across multiple networks. This also means that in order to execute the same operation twice (on the same
     * governor) the proposer will have to change the description in order to avoid proposal id conflicts.
     */
    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 epochTimeHash
    ) public pure virtual override returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, epochTimeHash)));
    }

    function proposalProposer(uint256 proposalId) public view virtual override returns (address) {
        return _proposals[proposalId].proposer;
    }

    /**
     * @dev See {IGovernor-state}.
     */
    function state(uint256 proposalId) public view virtual override returns (ProposalState) {
        ProposalCore storage proposal = _proposals[proposalId];

        if (proposal.executed) {
            return ProposalState.Executed;
        }

        if (proposal.canceled) {
            return ProposalState.Canceled;
        }

        uint256 start = proposalSnapshot(proposalId);

        if (start == 0) {
            revert("Governor: unknown proposal id");
        }

        if (start >= block.timestamp) {
            return ProposalState.Pending;
        }

        uint256 deadline = proposalDeadline(proposalId);

        if (deadline >= block.timestamp) {
            return ProposalState.Active;
        }
        // quorum reached is basically a percentage check which is of the number specifie in constructor of the L2GovernorVotesQuorumFraction(4) // 4%
        if (_quorumReached(proposalId) && _voteSucceeded(proposalId)) {
            return ProposalState.Succeeded;
        } else if (_quorumReached(proposalId) && _voteDefeated(proposalId)) {
            return ProposalState.Defeated;
        } else {
            return ProposalState.Expired;
        }
    }

    /**
     * @dev See {IGovernor-proposalSnapshot}.
     */
    function proposalSnapshot(uint256 proposalId) public view virtual override returns (uint256) {
        return _proposals[proposalId].voteStart.getDeadline();
    }

    /**
     * @dev See {IGovernor-proposalDeadline}.
     */
    function proposalDeadline(uint256 proposalId) public view virtual override returns (uint256) {
        return _proposals[proposalId].voteEnd.getDeadline();
    }

    /**
     * @dev Part of the Governor Bravo's interface: _"The number of votes required in order for a voter to become a proposer"_.
     */
    function proposalThreshold() public view virtual returns (uint256) {
        return 0;
    }

    /**
     * @dev Amount of votes already cast passes the threshold limit.
     */
    function _quorumReached(uint256 proposalId) internal view virtual returns (bool);

    /**
     * @dev Is the proposal successful or not.
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual returns (bool);

    function _voteDefeated(uint256 proposalId) internal view virtual returns (bool);

    /**
     * @dev Get the voting weight of `account` at a specific `blockTimestamp`, for a vote as described by `params`.
     */
    function _getVotes(
        address account,
        uint256 tokenId,
        uint256 blockTimestamp,
        bytes memory params
    ) internal view virtual returns (uint256);

    /**
     * @dev Register a vote for `proposalId` by `account` with a given `support`, voting `weight` and voting `params`.
     *
     * Note: Support is generic and can represent various things depending on the voting system used.
     */
    function _countVote(
        uint256 proposalId,
        uint256 tokenId,
        uint8 support,
        uint256 weight,
        bytes memory params
    ) internal virtual;

    /**
     * @dev Default additional encoded parameters used by castVote methods that don't include them
     *
     * Note: Should be overridden by specific implementations to use an appropriate value, the
     * meaning of the additional params, in the context of that implementation
     */
    function _defaultParams() internal view virtual returns (bytes memory) {
        return "";
    }

    /**
     * @dev See {IGovernor-propose}.
     */
    function _proposal(
        uint256 tokenId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal virtual returns (uint256) {
        require(
            getVotes(msg.sender, tokenId, block.timestamp) >= proposalThreshold(),
            "Governor: proposer votes below proposal threshold"
        );
        bytes32 epochStart = bytes32(BlackTimeLibrary.epochNext(block.timestamp));

        uint256 proposalId = hashProposal(targets, values, calldatas, epochStart);

        require(targets.length > 0, "Governor: empty proposal");

        ProposalCore storage proposal = _proposals[proposalId];
        require(proposal.voteStart.isUnset(), "Governor: proposal already exists");

        uint64 start = block.timestamp.toUint64() + votingDelay().toUint64();
        uint64 deadline = votingPeriod().toUint64();

        proposal.voteStart.setDeadline(start);
        proposal.voteEnd.setDeadline(deadline);
        proposal.proposer = msg.sender;

        _proposals[proposalId] = proposal;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            new string[](targets.length),
            calldatas,
            start,
            deadline,
            ""
        );

        return proposalId;
    }

    /**
     * @dev See {IGovernor-execute}.
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 epochTimeHash
    ) public payable virtual override returns (uint256) {
        uint256 proposalId = hashProposal(targets, values, calldatas, epochTimeHash);

        status = state(proposalId);
        require(
            status == ProposalState.Succeeded || status == ProposalState.Defeated,
            "Governor: proposal not successful or defeated"
        );
        _proposals[proposalId].executed = true;

        emit ProposalExecuted(proposalId);

        _beforeExecute(proposalId, targets, values, calldatas, epochTimeHash);
        _execute(proposalId, targets, values, calldatas, epochTimeHash);
        _afterExecute(proposalId, targets, values, calldatas, epochTimeHash);

        return proposalId;
    }

    /**
     * @dev Internal execution mechanism. Can be overridden to implement different execution mechanism
     */
    function _execute(
        uint256, /* proposalId */
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 /*descriptionHash*/
    ) internal virtual {
        string memory errorMessage = "Governor: call reverted without message";
        for (uint256 i = 0; i < targets.length; ++i) {
            (bool success, bytes memory returndata) = targets[i].call{value: values[i]}(calldatas[i]);
            Address.verifyCallResult(success, returndata, errorMessage);
        }
    }

    /**
     * @dev Hook before execution is triggered.
     */
    function _beforeExecute(
        uint256, /* proposalId */
        address[] memory targets,
        uint256[] memory, /* values */
        bytes[] memory calldatas,
        bytes32 /*descriptionHash*/
    ) internal virtual {
        if (_executor() != address(this)) {
            for (uint256 i = 0; i < targets.length; ++i) {
                if (targets[i] == address(this)) {
                    _governanceCall.pushBack(keccak256(calldatas[i]));
                }
            }
        }
    }

    /**
     * @dev Hook after execution is triggered.
     */
    function _afterExecute(
        uint256, /* proposalId */
        address[] memory, /* targets */
        uint256[] memory, /* values */
        bytes[] memory, /* calldatas */
        bytes32 /*descriptionHash*/
    ) internal virtual {
        if (_executor() != address(this)) {
            if (!_governanceCall.empty()) {
                _governanceCall.clear();
            }
        }
    }

    /**
     * @dev Internal cancel mechanism: locks up the proposal timer, preventing it from being re-submitted. Marks it as
     * canceled to allow distinguishing it from executed proposals.
     *
     * Emits a {IGovernor-ProposalCanceled} event.
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 epochTimeHash
    ) internal virtual returns (uint256) {
        uint256 proposalId = hashProposal(targets, values, calldatas, epochTimeHash);
        ProposalState currentStatus = state(proposalId);

        require(
            currentStatus != ProposalState.Canceled && currentStatus != ProposalState.Expired && currentStatus != ProposalState.Executed,
            "Governor: proposal not active"
        );
        _proposals[proposalId].canceled = true;

        emit ProposalCanceled(proposalId);

        return proposalId;
    }

    /**
     * @dev See {IGovernor-getVotes}.
     */
    function getVotes(address account, uint256 tokenId, uint256 blockTimestamp) public view virtual override returns (uint256) {
        return _getVotes(account, tokenId, blockTimestamp, _defaultParams());
    }

    /**
     * @dev See {IGovernor-getVotesWithParams}.
     */
    function getVotesWithParams(
        address account,
        uint256 tokenId,
        uint256 blockTimestamp,
        bytes memory params
    ) public view virtual override returns (uint256) {
        return _getVotes(account, tokenId, blockTimestamp, params);
    }

    /**
     * @dev See {IGovernor-castVote}.
     */
    function castVote(uint256 proposalId, uint256 tokenId, uint8 support) public virtual override returns (uint256) {
        address voter = msg.sender;
        return _castVote(proposalId, voter, tokenId, support, "");
    }

    /**
     * @dev See {IGovernor-castVoteWithReason}.
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint256 tokenId,
        uint8 support,
        string calldata reason
    ) public virtual override returns (uint256) {
        address voter = msg.sender;
        return _castVote(proposalId, voter, tokenId, support, reason);
    }

    /**
     * @dev See {IGovernor-castVoteWithReasonAndParams}.
     */
    function castVoteWithReasonAndParams(
        uint256 proposalId,
        uint256 tokenId,
        uint8 support,
        string calldata reason,
        bytes memory params
    ) public virtual override returns (uint256) {
        address voter = msg.sender;
        return _castVote(proposalId, voter, tokenId, support, reason, params);
    }

    /**
     * @dev See {IGovernor-castVoteBySig}.
     */
    function castVoteBySig(
        uint256 proposalId,
        uint256 tokenId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override returns (uint256) {
        address voter = ECDSA.recover(
            _hashTypedDataV4(keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support))),
            v,
            r,
            s
        );
        return _castVote(proposalId, voter, tokenId, support, "", "");
    }

    /**
     * @dev See {IGovernor-castVoteWithReasonAndParamsBySig}.
     */
    function castVoteWithReasonAndParamsBySig(
        uint256 proposalId,
        uint256 tokenId,
        uint8 support,
        string calldata reason,
        bytes memory params,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override returns (uint256) {
        address voter = ECDSA.recover(
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        EXTENDED_BALLOT_TYPEHASH,
                        proposalId,
                        support,
                        keccak256(bytes(reason)),
                        keccak256(params)
                    )
                )
            ),
            v,
            r,
            s
        );

        return _castVote(proposalId, voter, tokenId, support, reason, params);
    }

    /**
     * @dev Internal vote casting mechanism: Check that the vote is pending, that it has not been cast yet, retrieve
     * voting weight using {IGovernor-getVotes} and call the {_countVote} internal function. Uses the _defaultParams().
     *
     * Emits a {IGovernor-VoteCast} event.
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint256 tokenId,
        uint8 support,
        string memory reason
    ) internal virtual returns (uint256) {
        return _castVote(proposalId, account, tokenId, support, reason, _defaultParams());
    }

    /**
     * @dev Internal vote casting mechanism: Check that the vote is pending, that it has not been cast yet, retrieve
     * voting weight using {IGovernor-getVotes} and call the {_countVote} internal function.
     *
     * Emits a {IGovernor-VoteCast} event.
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint256 tokenId,
        uint8 support,
        string memory reason,
        bytes memory params
    ) internal virtual returns (uint256) {
        ProposalCore storage proposal = _proposals[proposalId];
        require(state(proposalId) == ProposalState.Active, "Governor: vote not currently active");

        uint256 weight = _getVotes(account, tokenId, proposal.voteStart.getDeadline(), params);
        _countVote(proposalId, tokenId, support, weight, params);

        if (params.length == 0) {
            emit VoteCast(account, proposalId, support, weight, reason);
        } else {
            emit VoteCastWithParams(account, proposalId, support, weight, reason, params);
        }

        return weight;
    }

    /**
     * @dev Relays a transaction or function call to an arbitrary target. In cases where the governance executor
     * is some contract other than the governor itself, like when using a timelock, this function can be invoked
     * in a governance proposal to recover tokens or Ether that was sent to the governor contract by mistake.
     * Note that if the executor is simply the governor itself, use of `relay` is redundant.
     */
    function relay(
        address target,
        uint256 value,
        bytes calldata data
    ) external virtual onlyGovernance {
        Address.functionCallWithValue(target, data, value);
    }

    /**
     * @dev Address through which the governor executes action. Will be overloaded by module that execute actions
     * through another contract such as a timelock.
     */
    function _executor() internal view virtual returns (address) {
        return address(this);
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

// OpenZeppelin Contracts (last updated v4.6.0) (governance/extensions/GovernorCountingSimple.sol)

/**
 * @author Modified from RollCall (https://github.com/withtally/rollcall/blob/main/src/standards/L2GovernorCountingSimple.sol)
 *
 * @dev Extension of {Governor} for simple, 3 options, vote counting.
 *
 * _Available since v4.3._
 */
abstract contract L2GovernorCountingSimple is L2Governor {
    /**
     * @dev Supported vote types. Matches Governor Bravo ordering.
     */
    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(uint256 => bool) hasVoted;
    }

    mapping(uint256 => ProposalVote) private _proposalVotes;

    /**
     * @dev See {IGovernor-COUNTING_MODE}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    /**
     * @dev See {IGovernor-hasVoted}.
     */
    function hasVoted(uint256 proposalId, uint256 tokenId) public view virtual override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[tokenId];
    }

    /**
     * @dev Accessor to the internal vote counts.
     */
    function proposalVotes(uint256 proposalId)
        public
        view
        virtual
        returns (
            uint256 againstVotes,
            uint256 forVotes,
            uint256 abstainVotes
        )
    {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];
        return (proposalvote.againstVotes, proposalvote.forVotes, proposalvote.abstainVotes);
    }

    /**
     * @dev See {Governor-_quorumReached}.
     */
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        return quorum(proposalSnapshot(proposalId)) <= proposalvote.forVotes + proposalvote.abstainVotes + proposalvote.againstVotes;
    }

    /**
     * @dev See {Governor-_voteSucceeded}. In this module, the forVotes must be strictly over the againstVotes.
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        return proposalvote.forVotes > proposalvote.againstVotes && proposalvote.forVotes > proposalvote.abstainVotes;
    }

    function _voteDefeated(uint256 proposalId) internal view virtual override returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return proposalVote.againstVotes > proposalVote.forVotes && proposalVote.againstVotes > proposalVote.abstainVotes;
    }

    /**
     * @dev See {Governor-_countVote}. In this module, the support follows the `VoteType` enum (from Governor Bravo).
     */
    function _countVote(
        uint256 proposalId,
        uint256 tokenId,
        uint8 support,
        uint256 weight,
        bytes memory // params
    ) internal virtual override {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];

        require(!proposalvote.hasVoted[tokenId], "GovernorVotingSimple: vote already cast");
        proposalvote.hasVoted[tokenId] = true;

        if (support == uint8(VoteType.Against)) {
            proposalvote.againstVotes += weight;
        } else if (support == uint8(VoteType.For)) {
            proposalvote.forVotes += weight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposalvote.abstainVotes += weight;
        } else {
            revert("GovernorVotingSimple: invalid value for enum VoteType");
        }
    }
}

// OpenZeppelin Contracts (last updated v4.6.0) (governance/extensions/GovernorVotes.sol)

/**
 * @author Modified from RollCall (https://github.com/withtally/rollcall/blob/main/src/standards/L2GovernorVotes.sol)
 *
 * @dev Extension of {Governor} for voting weight extraction from an {ERC20Votes} token, or since v4.5 an {ERC721Votes} token.
 *
 * _Available since v4.3._
 */
abstract contract L2GovernorVotes is L2Governor {
    IBlackHoleVotes public immutable token;

    constructor(IBlackHoleVotes tokenAddress) {
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

// OpenZeppelin Contracts (last updated v4.5.0) (governance/extensions/GovernorVotesQuorumFraction.sol)

/**
 * @author Modified from RollCall (https://github.com/withtally/rollcall/blob/main/src/standards/L2GovernorVotesQuorumFraction.sol)
 *
 * @dev Extension of {Governor} for voting weight extraction from an {ERC20Votes} token and a quorum expressed as a
 * fraction of the total supply.
 *
 * _Available since v4.3._
 */
abstract contract L2GovernorVotesQuorumFraction is L2GovernorVotes {
    uint256 private _quorumNumerator;

    event QuorumNumeratorUpdated(uint256 oldQuorumNumerator, uint256 newQuorumNumerator);

    /**
     * @dev Initialize quorum as a fraction of the token's total supply.
     *
     * The fraction is specified as `numerator / denominator`. By default the denominator is 100, so quorum is
     * specified as a percent: a numerator of 10 corresponds to quorum being 10% of total supply. The denominator can be
     * customized by overriding {quorumDenominator}.
     */
    constructor(uint256 quorumNumeratorValue) {
        _updateQuorumNumerator(quorumNumeratorValue);
    }

    /**
     * @dev Returns the current quorum numerator. See {quorumDenominator}.
     */
    function quorumNumerator() public view virtual returns (uint256) {
        return _quorumNumerator;
    }

    /**
     * @dev Returns the quorum denominator. Defaults to 100, but may be overridden.
     */
    function quorumDenominator() public view virtual returns (uint256) {
        return 100;
    }

    /**
     * @dev Returns the quorum for a block timestamp, in terms of number of votes: `supply * numerator / denominator`.
     */
    function quorum(uint256 blockTimestamp) public view virtual override returns (uint256) {
        return (token.getsmNFTPastTotalSupply() * quorumNumerator()) / quorumDenominator();
    }

    /**
     * @dev Changes the quorum numerator.
     *
     * Emits a {QuorumNumeratorUpdated} event.
     *
     * Requirements:
     *
     * - Must be called through a governance proposal.
     * - New numerator must be smaller or equal to the denominator.
     */
    function updateQuorumNumerator(uint256 newQuorumNumerator) external virtual onlyGovernance {
        _updateQuorumNumerator(newQuorumNumerator);
    }

    /**
     * @dev Changes the quorum numerator.
     *
     * Emits a {QuorumNumeratorUpdated} event.
     *
     * Requirements:
     *
     * - New numerator must be smaller or equal to the denominator.
     */
    function _updateQuorumNumerator(uint256 newQuorumNumerator) internal virtual {
        require(
            newQuorumNumerator <= quorumDenominator(),
            "GovernorVotesQuorumFraction: quorumNumerator over quorumDenominator"
        );

        uint256 oldQuorumNumerator = _quorumNumerator;
        _quorumNumerator = newQuorumNumerator;

        emit QuorumNumeratorUpdated(oldQuorumNumerator, newQuorumNumerator);
    }
}