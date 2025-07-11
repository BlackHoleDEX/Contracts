// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IAuction {
    function getNativePrice() external view returns (uint256);
    function getNativeTokenAmount(uint256 depositAmount) external view returns (uint256);
    function getFundingTokenAmount(uint256 nativeAmount) external view returns (uint256);
    function purchased(uint256 amount) external;
}
