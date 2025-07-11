// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.7;

import "../chainlink/AutomationCompatibleInterface.sol";
import "../interfaces/IMinter.sol";
import "../interfaces/IGaugeManager.sol";
import "../interfaces/IGenesisPoolManager.sol";
import "../interfaces/IPermissionsRegistry.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract EpochController is AutomationCompatibleInterface, OwnableUpgradeable {

    address public automationRegistry;
    address public automationRegistry2;
    address public minter;
    address public gaugeManager;
    IGenesisPoolManager public genesisManager;
    IPermissionsRegistry public permissionsRegistry;

    event Logger(string addr, uint timestamp, uint blocknbr, bool x1, bool x2, string msg);

    constructor() {}

    function initialize(address _minter, address _permissionsRegistry, address _gaugeManager) public initializer {
        __Ownable_init();
        minter = _minter;
        gaugeManager = _gaugeManager;
        permissionsRegistry = IPermissionsRegistry(_permissionsRegistry);
    }


    function checkUpkeep(bytes memory /*checkdata*/) public view override returns (bool upkeepNeeded, bytes memory /*performData*/) {
        upkeepNeeded = IMinter(minter).check();
        // event fire with upkeepNeeded....
    }

    function checkUpPrekeep(bytes memory /*checkdata*/) public view override returns (bool preUpkeepNeeded, bytes memory /*performData*/) {
        preUpkeepNeeded = genesisManager.check();
        // event fire with upkeepNeeded....
    }

    function performUpkeep(bytes calldata /*performData*/) external override {
        // event fire msg.sender and automationRegistry
        require(msg.sender == automationRegistry || permissionsRegistry.hasRole("EPOCH_MANAGER", msg.sender), 'cannot execute');
        (bool upkeepNeeded,) = checkUpkeep('0x');
        // event fire with upkeepNeeded..
        require(upkeepNeeded, "condition not met");
        string memory sender = Strings.toHexString(msg.sender);
        emit Logger(sender, block.timestamp, block.number, msg.sender == automationRegistry, permissionsRegistry.hasRole("EPOCH_MANAGER", msg.sender), 'performUpkeep called');
        genesisManager.checkAtEpochFlip();
        IGaugeManager(gaugeManager).distributeAll();
        IGaugeManager(gaugeManager).distributeFees();
    }

    function performPreUpkeep(bytes calldata /*performData*/) external override {
        // event fire msg.sender and automationRegistry2
        require(msg.sender == automationRegistry2 || permissionsRegistry.hasRole("EPOCH_MANAGER", msg.sender), 'cannot execute');
        (bool preUpkeepNeeded,) = checkUpPrekeep('0x');
        // event fire with preUpkeepNeeded..
        require(preUpkeepNeeded, "condition not met");
        string memory sender = Strings.toHexString(msg.sender);
        emit Logger(sender, block.timestamp, block.number, msg.sender == automationRegistry2, permissionsRegistry.hasRole("EPOCH_MANAGER", msg.sender), 'performPreUpkeep called');
        genesisManager.checkBeforeEpochFlip();
    }

    function setAutomationRegistry(address _automationRegistry) external onlyOwner {
        require(_automationRegistry != address(0));
        automationRegistry = _automationRegistry;
    }

    function setAutomationRegistry2(address _automationRegistry2) external onlyOwner {
        require(_automationRegistry2 != address(0));
        automationRegistry2 = _automationRegistry2;
    }

    function setGaugeManager(address _gaugeManager) external onlyOwner {
        require(_gaugeManager != address(0));
        gaugeManager = _gaugeManager;
    }

    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0));
        minter = _minter;
    }

    function setGenesisManager(address _genesisManager) external onlyOwner {
        require(_genesisManager != address(0));
        genesisManager = IGenesisPoolManager(_genesisManager);
    }
}