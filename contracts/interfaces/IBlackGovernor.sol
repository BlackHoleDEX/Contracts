// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IBlackGovernor {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    enum ProposalResult {
        None,
        Option1,
        Option2,
        Option3
    }

    /// @dev Stores most recent proposal lifecycle state after execution checks.
    ///      Any contracts that wish to use this governor must read from this to determine results.
    function status() external returns (ProposalState);

    /// @dev Stores latest executed proposal winner.
    function result() external view returns (ProposalResult);
}

