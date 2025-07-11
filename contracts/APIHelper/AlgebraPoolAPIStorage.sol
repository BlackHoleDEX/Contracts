// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';
import '../interfaces/IAlgebraCLFactory.sol';
import '../interfaces/IPermissionsRegistry.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


contract AlgebraPoolAPIStorage is Initializable, OwnableUpgradeable {

    IAlgebraCLFactory public algebraFactory;
    mapping(address => address) public pairToDeployer;
    address[] public customDeployers;
    mapping(address => bool) public isCustomDeployer;
    address public permissionRegistry;

    modifier CLPoolAdmin() {
        require(IPermissionsRegistry(permissionRegistry).hasRole("CL_POOL_ADMIN",msg.sender), 'CL_POOL_ADMIN');
        _;
    }

    function initialize(address _algebraFactory, address _permissionRegistry) public initializer {
        __Ownable_init();
        algebraFactory = IAlgebraCLFactory(_algebraFactory);
        permissionRegistry = _permissionRegistry;
    }

    function addCustomDeployer(address _customDeployer) external CLPoolAdmin {
        require(!isCustomDeployer[_customDeployer], "added");
        customDeployers.push(_customDeployer);
        isCustomDeployer[_customDeployer] = true;
    }


    function setDeployerForPair(address _pair) external {
        require(
          isCustomDeployer[msg.sender],"!CD"
        );
        address token0 = IAlgebraPool(_pair).token0();
        address token1 = IAlgebraPool(_pair).token1();
        require(_pair == IAlgebraCLFactory(algebraFactory).customPoolByPair(msg.sender, token0, token1), '!deployer');
        pairToDeployer[_pair] = msg.sender;
    }

    function setDeployerForPair(address _pair, address _deployer) external {
        require(msg.sender == owner(), 'not owner');
        address token0 = IAlgebraPool(_pair).token0();
        address token1 = IAlgebraPool(_pair).token1();
        require(_pair == IAlgebraCLFactory(algebraFactory).customPoolByPair(_deployer, token0, token1), '!deployer');
        pairToDeployer[_pair] = _deployer;
    }

}
