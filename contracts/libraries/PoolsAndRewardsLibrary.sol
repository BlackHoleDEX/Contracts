// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

library PoolsAndRewardsLibrary {
    struct PoolsAndRewards {
        address pool;
        address gauge;
        address bribes;
        uint256 rewards;
        uint256 totalVotingPower;
    }
}
