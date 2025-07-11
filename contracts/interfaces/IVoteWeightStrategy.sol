// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "../libraries/PoolsAndRewardsLibrary.sol";

interface IVoteWeightStrategy {
    function getVoteWeights() external view returns(uint256[] memory);
    function setAVM(address _avm) external;
    function setTopN() external;
}
