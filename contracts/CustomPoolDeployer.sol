// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@cryptoalgebra/integral-periphery/contracts/interfaces/IAlgebraCustomPoolEntryPoint.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/vault/IAlgebraCommunityVault.sol";
import "./interfaces/IAlgebraPoolAPIStorage.sol";
import "./interfaces/IAlgebraFarmingProxyPluginFactory.sol";
import "./interfaces/IAlgebraCustomVaultPoolEntryPoint.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract CustomPoolDeployer is Initializable, OwnableUpgradeable {
    event AuthorizedAccountAdded(address indexed account);
    event AuthorizedAccountRemoved(address indexed account);

    address public entryPoint;
    address public plugin;
    int24 public tickSpacing;
    address public algebraPoolAPIStorage;
    address public algebraFeeRecipient;
    address public algebraFeeManager;
    uint16 public algebraFeeShare;

    address public algebraFarmingProxyPluginFactory;
    address public algebraFactory;
    address public algebraPluginFactory;

    mapping(address => address) public poolToPlugin;
    mapping(address => bool) public authorizedAccounts;

    modifier onlyAuthorized() {
        require(
            authorizedAccounts[msg.sender] || msg.sender == owner(),
            "not owner or authorized"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _entryPoint,
        address _plugin,
        int24 _tickSpacing,
        address _algebraPoolAPIStorage,
        address _algebraFeeRecipient,
        address _algebraFeeManager,
        uint16 _algebraFeeShare,
        address _algebraFarmingProxyPluginFactory,
        address _algebraFactory,
        address _algebraPluginFactory
    ) public initializer {
        __Ownable_init();
        
        entryPoint = _entryPoint;
        plugin = _plugin;
        tickSpacing = _tickSpacing;
        algebraPoolAPIStorage = _algebraPoolAPIStorage;
        algebraFeeRecipient = _algebraFeeRecipient;
        algebraFeeManager = _algebraFeeManager;
        algebraFeeShare = _algebraFeeShare;
        algebraFarmingProxyPluginFactory = _algebraFarmingProxyPluginFactory;
        algebraFactory = _algebraFactory;
        algebraPluginFactory = _algebraPluginFactory;
    }

    function addAuthorizedAccount(address account) external onlyOwner {
        require(account != address(0), "zero address");
        require(!authorizedAccounts[account], "already authorized");
        authorizedAccounts[account] = true;
        emit AuthorizedAccountAdded(account);
    }

    function removeAuthorizedAccount(address account) external onlyOwner {
        require(account != address(0), "zero address");
        require(authorizedAccounts[account], "!authorized");
        authorizedAccounts[account] = false;
        emit AuthorizedAccountRemoved(account);
    }

    function createCustomPool(
        address creator,
        address tokenA,
        address tokenB,
        bytes calldata data,
        uint160 initialPrice
    ) external onlyAuthorized returns (address customPool) {
        customPool = IAlgebraCustomPoolEntryPoint(entryPoint).createCustomPool(
            address(this),
            creator,
            tokenA,
            tokenB,
            data
        );
        IAlgebraPool(customPool).initialize(initialPrice);
        IAlgebraCustomPoolEntryPoint(entryPoint).setTickSpacing(
            customPool,
            tickSpacing
        );
        IAlgebraPoolAPIStorage(algebraPoolAPIStorage).setDeployerForPair(customPool);
        address vault = IAlgebraPool(customPool).communityVault();
        IAlgebraCommunityVault(vault).changeAlgebraFeeReceiver(
            algebraFeeRecipient
        );
        // Propose and accept algebra fee change
        IAlgebraCommunityVault(vault).proposeAlgebraFeeChange(algebraFeeShare);
        IAlgebraCommunityVault(vault).acceptAlgebraFeeChangeProposal(
            algebraFeeShare
        );

        IAlgebraCommunityVault(vault).transferAlgebraFeeManagerRole(
            algebraFeeManager
        );
        address newPluginAddress = IAlgebraFarmingProxyPluginFactory(
            algebraFarmingProxyPluginFactory
        ).createAlgebraProxyPlugin(
                customPool,
                algebraFactory,
                algebraPluginFactory
            );
        IAlgebraCustomPoolEntryPoint(entryPoint).setPlugin(
            customPool,
            newPluginAddress
        );
    }

    function beforeCreatePoolHook(
        address,
        address,
        address,
        address,
        address,
        bytes calldata
    ) external view returns (address) {
        require(msg.sender == entryPoint, "Only entryPoint");
        return plugin;
    }

    function afterCreatePoolHook(address, address, address) external pure {
        return;
    }

    function setPluginForPool(
        address pool,
        address _plugin
    ) external onlyAuthorized {
        poolToPlugin[pool] = _plugin;
    }

    // If we need new tick spacing, we'll use a new deployer
    // function setTickSpacing(address pool, int24 newTickSpacing) external {
    //     IAlgebraCustomPoolEntryPoint(entryPoint).setTickSpacing(pool, newTickSpacing);
    // }

    function setPlugin(
        address pool,
        address newPluginAddress
    ) external onlyAuthorized {
        IAlgebraCustomPoolEntryPoint(entryPoint).setPlugin(
            pool,
            newPluginAddress
        );
    }

    function setPluginConfig(
        address pool,
        uint8 newConfig
    ) external onlyAuthorized {
        IAlgebraCustomPoolEntryPoint(entryPoint).setPluginConfig(
            pool,
            newConfig
        );
    }

    function setFee(address pool, uint16 newFee) external onlyAuthorized {
        IAlgebraCustomPoolEntryPoint(entryPoint).setFee(pool, newFee);
    }

    function setCommunityFee(address pool, uint16 newCommunityFee) external onlyAuthorized {
        IAlgebraCustomVaultPoolEntryPoint(entryPoint).setCommunityFee(pool, newCommunityFee);
    }

    function setAlgebraFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "zero address");
        algebraFeeRecipient = _newRecipient;
    }

    function setAlgebraFeeManager(address _newManager) external onlyOwner {
        require(_newManager != address(0), "zero address");
        algebraFeeManager = _newManager;
    }

    function setAlgebraFeeShare(uint16 _newFeeShare) external onlyOwner {
        algebraFeeShare = _newFeeShare;
    }

    function setAlgebraFarmingProxyPluginFactory(address _algebraFarmingProxyPluginFactory) external onlyOwner {
        require(_algebraFarmingProxyPluginFactory != address(0), "zero address");
        algebraFarmingProxyPluginFactory = _algebraFarmingProxyPluginFactory;
    }

    function setAlgebraFactory(address _algebraFactory) external onlyOwner {
        require(_algebraFactory != address(0), "zero address");
        algebraFactory = _algebraFactory;
    }

    function setAlgebraPluginFactory(address _algebraPluginFactory) external onlyOwner {
        require(_algebraPluginFactory != address(0), "zero address");
        algebraPluginFactory = _algebraPluginFactory;
    }
}
