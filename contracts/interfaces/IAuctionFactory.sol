// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IAuctionFactory {
    function auctions(uint index) external view returns (address);
    function isAuction(address auction) external view returns (bool);
    function auctionsLength() external view returns (uint256);
    function allAuctions() external view returns (address[] memory);
}