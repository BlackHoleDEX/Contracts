// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IVeArtProxy {
    function _tokenURI(uint _tokenId, uint _balanceOf, uint _locked_end, uint _value, bool isSMNFT) external pure returns (string memory output);
}
