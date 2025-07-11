// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IGenesisPoolManager {
    function nativeTokens(uint256 index) external view returns(address);
    function liveNativeTokens(uint256 index) external view returns(address);
    function getAllNaitveTokens() external view returns (address[] memory);
    function getLiveNaitveTokens() external view returns (address[] memory);

    function checkAtEpochFlip() external;
    function checkBeforeEpochFlip() external;

    function check() external view returns (bool);
}
