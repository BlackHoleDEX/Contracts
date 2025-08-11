// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import './interfaces/IGaugeOwner.sol';

interface IGaugeV2 {
    function setDistribution(address _distribution) external;
    function setGaugeRewarder(address _gaugeRewarder) external;
    function setInternalBribe(address _int) external;
    function activateEmergencyMode() external;
    function stopEmergencyMode() external;
    function setGenesisPoolManager(address _manager) external;
    function setGenesisPool(address _genesisPool) external;
}

contract GaugeOwner is IGaugeOwner, Ownable {
    constructor(address _GaugeFactory) { 
        _transferOwnership(_GaugeFactory);
    }

    function setDistribution(address _gauge, address _distribution) external onlyOwner {
        IGaugeV2(_gauge).setDistribution(_distribution);
    }

    function setGaugeRewarder(address _gauge, address _gaugeRewarder) external onlyOwner {
        IGaugeV2(_gauge).setGaugeRewarder(_gaugeRewarder);
    }

    function setInternalBribe(address _gauge, address _int) external onlyOwner {
        // Not updating InternalBribe once it's set
    }

    function activateEmergencyMode(address _gauge) external onlyOwner {
        IGaugeV2(_gauge).activateEmergencyMode();
    }

    function stopEmergencyMode(address _gauge) external onlyOwner {
        IGaugeV2(_gauge).stopEmergencyMode();
    }

    function secureGenesisPool(address _gauge) external onlyOwner {
        // Not updating GenesisPool once it's set
    }
}