// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import './interfaces/ITokenHandler.sol';
import './interfaces/IPermissionsRegistry.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenHandler is  ITokenHandler, Ownable {

    mapping(address => bool) public isWhitelisted;             
    mapping(uint256 => bool) public isWhitelistedNFT;
    mapping(address => bool) public isConnector;
    mapping(address => uint256) public tokenVolatilityBucket; // Mapping of token to volatility bucket ID
    mapping(uint256 => string) public bucketType; // Mapping of token to volatility bucket ID

    address[] public whiteListed;
    address[] public connectors;

    address public permissionRegistry;
    uint256 public volatilityBucketCount;

    event SetPermissionRegistry(address indexed old, address indexed latest);
    event Whitelisted(address indexed whitelister, address indexed token);
    event Blacklisted(address indexed blacklister, address indexed token);
    event WhitelistedNFT(address indexed whitelister, uint256 tokenId);
    event BlacklistNFT(address indexed whitelister, uint256 tokenId);
    event WhitelistedConnector(address indexed whitelister, address indexed token);
    event BlacklistConnector(address indexed whitelister, address indexed token);
    event TokenVolatilityBucketUpdated(address indexed token, uint256 bucketId);

    modifier Governance() {
        require(IPermissionsRegistry(permissionRegistry).hasRole("GOVERNANCE",msg.sender), 'GOVERNANCE');
        _;
    }

    modifier GovernanceOrGenesisManager() {
        require(IPermissionsRegistry(permissionRegistry).hasRole("GENESIS_MANAGER", msg.sender) || IPermissionsRegistry(permissionRegistry).hasRole("GOVERNANCE",msg.sender), 'GOVERNANCE GENESIS_MANAGER');
        _;
    }

    constructor(address _permissionRegistry) {
        permissionRegistry = _permissionRegistry;
    }

    function setPermissionsRegistry(address _permissionRegistry) external onlyOwner {
        require(_permissionRegistry.code.length > 0, "!contract");
        require(_permissionRegistry != address(0), "addr0");
        emit SetPermissionRegistry(permissionRegistry, _permissionRegistry);
        permissionRegistry = _permissionRegistry;
    }

    /// @notice Whitelist a token for gauge creation
    function whitelistTokens(address[] memory _tokens) external GovernanceOrGenesisManager {
        uint256 i = 0;
        for(i = 0; i < _tokens.length; i++){
            _whitelist(_tokens[i]);
        }
    }

    function whitelistToken(address _token) external GovernanceOrGenesisManager {
        _whitelist(_token);
    }
       
    function _whitelist(address _token) private {
        require(!isWhitelisted[_token], "in");
        require(_token.code.length > 0, "!contract");
        isWhitelisted[_token] = true;
        whiteListed.push(_token);
        emit Whitelisted(msg.sender, _token);
    }
    
    /// @notice Blacklist a malicious token
    function blacklistTokens(address[] memory _token) external GovernanceOrGenesisManager {
        uint256 i = 0;
        for(i = 0; i < _token.length; i++){
            _blacklist(_token[i]);
        }
    }

    function blacklistToken(address _token) external GovernanceOrGenesisManager {
        _blacklist(_token);
    }
       
    function _blacklist(address _token) private {
        require(isWhitelisted[_token], "out");
        require(_token.code.length > 0, "!contract");
        isWhitelisted[_token] = false;

        uint256 length = whiteListed.length;
        uint256 i;
        for (i = 0; i < length; i++) {
            if (whiteListed[i] == _token) {
                whiteListed[i] = whiteListed[length - 1]; 
                whiteListed.pop(); 
                return;
            }
        }

        emit Blacklisted(msg.sender, _token);
    }

    function whitelistNFT(uint256 _tokenId) external Governance() {
        isWhitelistedNFT[_tokenId] = true;
        emit WhitelistedNFT(msg.sender, _tokenId);
    }

    function blacklistNFT(uint256 _tokenId) external Governance() {
        isWhitelistedNFT[_tokenId] = false;
        emit BlacklistNFT(msg.sender, _tokenId);
    }

    function whitelistConnectors(address[] memory _tokens) external Governance {
        uint256 i = 0;
        for(i = 0; i < _tokens.length; i++){
            _whitelistConnector(_tokens[i]);
        }
    }

    function whitelistConnector(address _token) external Governance() {
        _whitelistConnector(_token);
    }

    function _whitelistConnector(address _token) internal {
        require(isWhitelisted[_token], "out");
        require(!isConnector[_token], "connector");
        require(_token.code.length > 0, "!contract");
        isConnector[_token] = true;
        connectors.push(_token);
        emit WhitelistedConnector(msg.sender, _token);
    }

    function blacklistConnector(address _token) external Governance() {
        require(isWhitelisted[_token], "out");
        require(isConnector[_token], "not connector");
        require(_token.code.length > 0, "!contract");
        isConnector[_token] = false;

        uint256 length = connectors.length;
        uint256 i;
        for (i = 0; i < length; i++) {
            if (connectors[i] == _token) {
                connectors[i] = connectors[length - 1]; 
                connectors.pop(); 
                return;
            }
        }

        emit BlacklistConnector(msg.sender, _token);
    }

    function setBucketType(uint256 bucketId, string calldata bucketName) external Governance {
        require(bucketId <= volatilityBucketCount + 1);
        if(bucketId == volatilityBucketCount + 1) volatilityBucketCount++;
        bucketType[bucketId] = bucketName;
    }

    function getBucketType(uint256 bucketId) external view returns (string memory) {
        require(bucketId <= volatilityBucketCount);
        return bucketType[bucketId]; // Retrieve bucket type by ID
    }

    function updateTokenVolatilityBucket(address _token, uint256 bucketId) external Governance {
        require(isWhitelisted[_token], "!whitelisted");
        tokenVolatilityBucket[_token] = bucketId; // Update the token's volatility bucket
        emit TokenVolatilityBucketUpdated(_token, bucketId);
    }

    function getTokenVolatilityBucket(address _token) external view returns (uint256) {
        require(isWhitelisted[_token], "!whitelisted");
        return tokenVolatilityBucket[_token];
    }

    function whiteListedTokensLength() external view returns(uint256) {
        return whiteListed.length;
    }

    function connectorTokensLength() external view returns(uint256) {
        return connectors.length;
    }

    function whiteListedTokens() external view returns(address[] memory tokens) {
        return whiteListed;
    }

    function connectorTokens() external view returns(address[] memory tokens) {
        return connectors;
    }
    
}
