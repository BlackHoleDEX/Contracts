// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@cryptoalgebra/integral-periphery/contracts/interfaces/IAlgebraCustomPoolEntryPoint.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/vault/IAlgebraCommunityVault.sol";
import "./interfaces/IAlgebraPoolAPIStorage.sol";
import "./interfaces/IAlgebraCustomVaultPoolEntryPoint.sol";
import "./interfaces/IAlgebraBasePluginV1FactoryCustom.sol";
import "@cryptoalgebra/integral-base-plugin/contracts/interfaces/plugins/IVolatilityOracle.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract CustomPoolDeployer is Initializable, OwnableUpgradeable {
    event AuthorizedAccountAdded(address indexed account);
    event AuthorizedAccountRemoved(address indexed account);
    event CustomPoolCreated(address indexed creator, address indexed tokenA, address indexed tokenB, address customPool, address pluginAddress);
    event SetPlugin(address indexed pool, address indexed newPlugin);
    event SetPluginConfig(address indexed pool, uint8 newConfig);
    event SetFee(address indexed pool, uint16 newFee);
    event SetCommunityFee(address indexed pool, uint16 newCommunityFee);
    event SetAlgebraFeeRecipient(address indexed oldRecipient, address indexed newRecipient);
    event SetAlgebraFeeManager(address indexed oldManager, address indexed newManager);
    event SetAlgebraFeeShare(uint16 oldFeeShare, uint16 newFeeShare);
    event SetAlgebraFactory(address indexed oldAlgebraFactory, address indexed newAlgebraFactory);
    event SetAlgebraPluginFactory(address indexed oldAlgebraPluginFactory, address indexed newAlgebraPluginFactory);

    address public entryPoint;
    address public plugin;
    int24 public tickSpacing;
    address public algebraPoolAPIStorage;
    address public algebraFeeRecipient;
    address public algebraFeeManager;
    uint16 public algebraFeeShare;

    address public algebraFactory;
    address public algebraPluginFactory;

    mapping(address => bool) public authorizedAccounts;

    // Calculated as: BEFORE_POSITION_MODIFY_FLAG(4) | AFTER_INIT_FLAG(64) | BEFORE_SWAP_FLAG(1) | AFTER_SWAP_FLAG(2) | BEFORE_FLASH_FLAG(16)
    // Using numeric values since library references are not compile-time constants
    uint8 public constant defaultPluginConfig = 87; // 87 in decimal (sum of above selected flags)

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
        address newPluginAddress = IAlgebraBasePluginV1FactoryCustom(algebraPluginFactory)
            .createPluginForExistingCustomPool(tokenA, tokenB, address(this));
        IAlgebraCustomPoolEntryPoint(entryPoint).setPlugin(
            customPool,
            newPluginAddress
        );
        IVolatilityOracle(newPluginAddress).initialize();
        IAlgebraCustomPoolEntryPoint(entryPoint).setPluginConfig(
            customPool,
            defaultPluginConfig
        );
        emit CustomPoolCreated(creator, tokenA, tokenB, customPool, newPluginAddress);
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

    // If we need new tick spacing, we'll use a new deployer
    // function setTickSpacing(address pool, int24 newTickSpacing) external {
    //     IAlgebraCustomPoolEntryPoint(entryPoint).setTickSpacing(pool, newTickSpacing);
    // }

    function setPluginConfig(
        address pool,
        uint8 newConfig
    ) external onlyAuthorized {
        IAlgebraCustomPoolEntryPoint(entryPoint).setPluginConfig(
            pool,
            newConfig
        );
        emit SetPluginConfig(pool, newConfig);
    }

    function setFee(address pool, uint16 newFee) external onlyAuthorized {
        IAlgebraCustomPoolEntryPoint(entryPoint).setFee(pool, newFee);
        emit SetFee(pool, newFee);
    }

    function setCommunityFee(address pool, uint16 newCommunityFee) external onlyAuthorized {
        IAlgebraCustomVaultPoolEntryPoint(entryPoint).setCommunityFee(pool, newCommunityFee);
        emit SetCommunityFee(pool, newCommunityFee);
    }

    function setAlgebraFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "zero address");
        address oldRecipient = algebraFeeRecipient;
        algebraFeeRecipient = _newRecipient;
        emit SetAlgebraFeeRecipient(oldRecipient, _newRecipient);
    }

    function setAlgebraFeeManager(address _newManager) external onlyOwner {
        require(_newManager != address(0), "zero address");
        address oldManager = algebraFeeManager;
        algebraFeeManager = _newManager;
        emit SetAlgebraFeeManager(oldManager, _newManager);
    }

    function setAlgebraFeeShare(uint16 _newFeeShare) external onlyOwner {
        uint16 oldFeeShare = algebraFeeShare;
        algebraFeeShare = _newFeeShare;
        emit SetAlgebraFeeShare(oldFeeShare, _newFeeShare);
    }

    function setAlgebraFactory(address _algebraFactory) external onlyOwner {
        require(_algebraFactory != address(0), "zero address");
        address oldAlgebraFactory = algebraFactory;
        algebraFactory = _algebraFactory;
        emit SetAlgebraFactory(oldAlgebraFactory, _algebraFactory);
    }

    function setAlgebraPluginFactory(address _algebraPluginFactory) external onlyOwner {
        require(_algebraPluginFactory != address(0), "zero address");
        address oldAlgebraPluginFactory = algebraPluginFactory;
        algebraPluginFactory = _algebraPluginFactory;
        emit SetAlgebraPluginFactory(oldAlgebraPluginFactory, _algebraPluginFactory);
    }
}