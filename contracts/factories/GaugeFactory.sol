// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;


import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '../interfaces/IPermissionsRegistry.sol';
import '../interfaces/IGaugeFactory.sol';
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
    constructor() {}

    function initialize(address _permissionRegistry) initializer  public {
        __Ownable_init();   //after deploy ownership to multisig
        permissionsRegistry = _permissionRegistry;
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
        last_gauge = address(new GaugeV2(_rewardToken,_ve,_token,_distribution,_internal_bribe,_external_bribe,_isPair, _genesisManager) );
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
            IGauge(_gauges[i]).activateEmergencyMode();
        }
    }

    function stopEmergencyMode( address[] memory _gauges) external EmergencyCouncil {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).stopEmergencyMode();
        }
    }

    function setRewarderPid( address[] memory _gauges, uint[] memory _pids) external onlyAllowed {
        require(_gauges.length == _pids.length, "EXACT_LEN");
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).setRewarderPid(_pids[i]);
        }
    }

    function setGaugeRewarder( address[] memory _gauges, address[] memory _rewarder) external onlyAllowed {
        require(_gauges.length == _rewarder.length, "EXACT_LEN");
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).setGaugeRewarder(_rewarder[i]);
        }
    }

    function setDistribution(address[] memory _gauges,  address distro) external onlyAllowed {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).setDistribution(distro);
        }
    }


    function setInternalBribe(address[] memory _gauges,  address[] memory int_bribe) external onlyAllowed {
        require(_gauges.length == int_bribe.length, "EXACT_LEN");
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).setInternalBribe(int_bribe[i]);
        }
    }

    function setGenesisManager(address _gauge, address _genesisManager) external onlyAllowed {
        require(_genesisManager != address(0), "ZA");
        require(_gauge != address(0), "ZA");
        IGauge(_gauge).setGenesisPoolManager(_genesisManager);
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
