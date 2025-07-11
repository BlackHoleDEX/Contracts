// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./IGenesisPoolBase.sol";

interface IGenesisPool {
    function getAllocationInfo() external view returns (IGenesisPoolBase.TokenAllocation memory);
    function getIncentivesInfo() external view returns (IGenesisPoolBase.TokenIncentiveInfo memory);
    function getGenesisInfo() external view returns (IGenesisPoolBase.GenesisInfo memory);
    function getLiquidityPoolInfo() external view returns (IGenesisPoolBase.LiquidityPool memory);
    function poolStatus() external view returns (IGenesisPoolBase.PoolStatus);
    function userDeposits(address _user) external view returns (uint256);

    function setGenesisPoolInfo(IGenesisPoolBase.GenesisInfo calldata _genesisInfo, IGenesisPoolBase.TokenAllocation calldata _allocationInfo, address auction) external;
    function rejectPool() external;
    function approvePool(address _pairAddress) external;
    function depositToken(address spender, uint256 amount) external returns (bool);
    function transferIncentives(address gauge, address external_bribe, address internal_bribe) external;
    function eligbleForPreLaunchPool() external view returns (bool);
    function eligbleForDisqualify() external view returns (bool);
    function setPoolStatus(IGenesisPoolBase.PoolStatus status) external;
    function balanceOf(address account) external view returns (uint256);
    function deductAmount(address account, uint256 amount) external;
    function deductAllAmount(address account) external;
    function setAuction(address _auction) external;
    function getNativeTokenAmount(uint256 depositAmount) external view returns (uint256);

    function launch(address router, uint256 maturityTime) external;
    function setMaturityTime(uint256 _maturityTime) external;
    function setStartTime(uint256 _startTime) external;

}