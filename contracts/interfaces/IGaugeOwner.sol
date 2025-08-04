pragma solidity ^0.8.13;

interface IGaugeOwner{
    function setDistribution(address _gauge, address _distro) external;
    function activateEmergencyMode(address _gauge) external;
    function stopEmergencyMode(address _gauge) external;
    function setInternalBribe(address _gauge, address intbribe) external;
    function setGaugeRewarder(address _gauge, address _gr) external;
    function secureGenesisPool(address _gauge) external;
}