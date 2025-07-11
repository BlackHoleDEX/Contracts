// SPDX-License-Identifier: GPL-3.0-or-later
// BlackHole Foundation 2025

pragma solidity 0.8.13;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IBlackHoleVotes is IVotes{
    function getsmNFTPastVotes(address account, uint256 timepoint) external view returns (uint256);

   
    function getsmNFTPastTotalSupply() external view returns (uint256);

    function calculate_sm_nft_bonus(uint amount) external view returns (uint);
}