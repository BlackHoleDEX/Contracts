// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IAlgebraPoolAPIStorage {
    function pairToDeployer(address) external view returns (address);
    function setDeployerForPair(address _pair) external;
    function customDeployers(uint256 i) external view returns(address);
    function setDeployerForPair(address _pair, address _deployer) external;
}
