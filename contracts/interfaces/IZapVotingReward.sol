// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Zap} from "../libraries/zap.sol";

interface IZapVotingReward {
    /// @param bribes       Bribe contract addresses to claim from (one per gauge).
    /// @param tokens       Reward tokens to claim per bribe (parallel to `bribes`).
    /// @param tokenId      The veNFT used to vote; its owner receives the bribes.
    /// @param swaps        Off-chain computed routes converting each reward token to `outputToken`.
    /// @param outputToken  The single token the caller wants to receive.
    /// @param minAmountOut Minimum acceptable amount of `outputToken` (slippage guard).
    /// @param unwrapWETH   If true and `outputToken` is WETH, the output is unwrapped to native.
    /// @param deadline     Swap deadline forwarded to the router.
    struct ZapVotingRewardParams {
        address[] bribes;
        address[][] tokens;
        uint256 tokenId;
        Zap.Swap[] swaps;
        address outputToken;
        uint256 minAmountOut;
        bool unwrapWETH;
        uint256 deadline;
    }

    event VotingRewardsZapped(
        address indexed user, uint256 indexed tokenId, address indexed outputToken, uint256 amountOut
    );

    event DustRefunded(address indexed user, address indexed token, uint256 amount);

    function zapVotingRewards(ZapVotingRewardParams calldata params) external returns (uint256 amountOut);
}