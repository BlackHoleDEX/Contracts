// SPDX-License-Identifier: GPL-3.0-or-later
// BlackHole Foundation 2025

pragma solidity 0.8.13;

/// @title Interface for protocol's seasonal player rewards program
/// @author Chance Santana-Wees (Coelacanth/Coel.eth)
interface IBlackClaims {
    struct Season {
        uint256 start_time;
        uint256 reward_amount;
        uint256 remaining_reward_amount;
        uint256 claim_end_time;   //Last time claim is available
    }

    function startSeason(
        uint256 start_time_
    ) external returns(Season memory);

    function finalize(
        uint256 claim_duration
    ) external;

    function reportRewards(
        address[] calldata players_,
        uint256[] calldata rewards_
    ) external;

    function getClaimableReward(address userAddress) external view returns(uint256); 

    function revokeUnclaimedReward() external;
}