// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '../interfaces/IPermissionsRegistry.sol';
import '../interfaces/IGaugeFactory.sol';
import '../interfaces/IGaugeOwner.sol';
import '../GaugeV2.sol';

interface IGauge{
    function setDistribution(address _distro) external;
    function activateEmergencyMode() external;
    function stopEmergencyMode() external;
    function setInternalBribe(address intbribe) external;
    function setRewarderPid(uint256 pid) external;
    function setGaugeRewarder(address _gr) external;
    function setFeeVault(address _feeVault) external;
    function setGenesisPoolManager(address _genesisManager) external;
}

contract GaugeFactory is IGaugeFactory, OwnableUpgradeable {
    address public last_gauge;
    address public permissionsRegistry;

    address[] internal __gauges;
    address public gaugeManager;
    IGaugeOwner internal __gaugeOwner;

    constructor() {}

    function initialize(address _permissionRegistry) initializer  public {
        __Ownable_init();   //after deploy ownership to multisig
        permissionsRegistry = _permissionRegistry;
    }

    function setGaugeOwner(address _gaugeOwner) public {
        require(owner() == msg.sender, 'NA');
        __gaugeOwner = IGaugeOwner(_gaugeOwner);
    }

    function fixUnsetGaugeOwners(uint i, uint j) external {
        require(owner() == msg.sender, 'NA');
        require(address(__gaugeOwner) != address(0), 'ZA');
        uint k = i;
        uint gaugesLength = __gauges.length;
        for (k; k < j && k < gaugesLength; k++) {
            if (Ownable(__gauges[k]).owner() == address(this)) {
                Ownable(__gauges[k]).transferOwnership(address(__gaugeOwner));
            }
        }
    }

    function setRegistry(address _registry) external {
        require(owner() == msg.sender, 'NA');
        permissionsRegistry = _registry;
    }

    function gauges(uint256 i) external view returns(address) {
        return __gauges[i];
    }

    function length() external view returns(uint) {
        return __gauges.length;
    }

    function createGauge(address _rewardToken,address _ve,address _token,address _distribution, address _internal_bribe, address _external_bribe, bool _isPair, address _genesisManager) external onlyGaugeManager returns (address) {
        last_gauge = address(new GaugeV2(_rewardToken,_ve,_token,_distribution,_internal_bribe,_external_bribe,_isPair, address(0)) );
        Ownable(last_gauge).transferOwnership(address(__gaugeOwner));
        __gauges.push(last_gauge);
        return last_gauge;
    }

    modifier onlyAllowed() {
        require(owner() == msg.sender || IPermissionsRegistry(permissionsRegistry).hasRole("GAUGE_ADMIN",msg.sender), 'GAUGE_ADMIN');
        _;
    }

    modifier EmergencyCouncil() {
        require( msg.sender == IPermissionsRegistry(permissionsRegistry).emergencyCouncil(), "NA");
        _;
    }

    function activateEmergencyMode( address[] memory _gauges) external EmergencyCouncil {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            __gaugeOwner.activateEmergencyMode(_gauges[i]);
        }
    }

    function stopEmergencyMode( address[] memory _gauges) external EmergencyCouncil {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            __gaugeOwner.stopEmergencyMode(_gauges[i]);
        }
    }

    /*
    function setRewarderPid( address[] memory _gauges, uint[] memory _pids) external onlyAllowed {
        require(_gauges.length == _pids.length, "EXACT_LEN");
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).setRewarderPid(_pids[i]);
        }
    }
    */

    function setGaugeRewarder( address[] memory _gauges, address[] memory _rewarder) external onlyAllowed {
        require(_gauges.length == _rewarder.length, "EXACT_LEN");
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            __gaugeOwner.setGaugeRewarder(_gauges[i], _rewarder[i]);
        }
    }

    function setDistribution(address[] memory _gauges,  address distro) external onlyAllowed {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            __gaugeOwner.setDistribution(_gauges[i], distro);
        }
    }


    function setInternalBribe(address[] memory _gauges,  address[] memory int_bribe) external onlyAllowed {
        require(_gauges.length == int_bribe.length, "EXACT_LEN");
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            __gaugeOwner.setInternalBribe(_gauges[i], int_bribe[i]);
        }
    }

    function setGenesisManager(address _gauge, address _genesisManager) external onlyAllowed {
        require(_genesisManager != address(0), "ZA");
        require(_gauge != address(0), "ZA");
        __gaugeOwner.secureGenesisPool(_gauge);
    }


    modifier onlyGaugeManager() {
        require(msg.sender == gaugeManager, "N_G_M");
        _;
    }

    function setGaugeManager(address _gaugeManager) external onlyAllowed {
        require(_gaugeManager != address(0), "ZA");
        gaugeManager = _gaugeManager;
    }
}
