// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import '../interfaces/IGenesisPoolFactory.sol';
import '../GenesisPool.sol';
import '../interfaces/IGenesisPool.sol';
import '../interfaces/ITokenHandler.sol';

contract GenesisPoolFactory is IGenesisPoolFactory {

    address public genesisManager;
    address public tokenHandler;

    mapping(address => address[]) public genesisPools;
    address[] public allGenesisPools;

    event GenesisCreated(address indexed nativeToken, address indexed fundingToken);
    event GenesisManagerChanged(address indexed oldManager, address indexed newManager);

    modifier onlyManager() {    
        require(msg.sender == genesisManager);
        _;
    }

    constructor(address _tokenHandler) {
        genesisManager = msg.sender;
        tokenHandler = _tokenHandler;
    }

    function setGenesisManager(address _genesisManager) external onlyManager {
        emit GenesisManagerChanged(genesisManager, _genesisManager);
        genesisManager = _genesisManager;
    }

    function genesisPoolsLength() external view returns (uint256){
        return allGenesisPools.length;
    }

    function createGenesisPool(address tokenOwner, address nativeToken, address fundingToken) external onlyManager returns (address genesisPool) {
        require(nativeToken != address(0), "ZA"); 
        require(getGenesisPool(nativeToken) == address(0), "!ZA");

        bytes32 salt = keccak256(abi.encodePacked(nativeToken, fundingToken, genesisPools[nativeToken].length));
        genesisPool = address(new GenesisPool{salt: salt}(genesisManager, tokenHandler, tokenOwner, nativeToken, fundingToken));

        genesisPools[nativeToken].push(genesisPool);
        allGenesisPools.push(genesisPool);

        emit GenesisCreated(nativeToken, fundingToken);
    }

    function getGenesisPools(address nativeToken) external view returns (address[] memory){
        return genesisPools[nativeToken];
    }

    function getGenesisPool(address nativeToken) public view returns (address) {
        address[] memory pools = genesisPools[nativeToken];
        uint length = pools.length;

        if (length == 0) {
            return address(0);
        }
        if(IGenesisPool(pools[length - 1]).poolStatus() != IGenesisPoolBase.PoolStatus.NOT_QUALIFIED)
        {
            return pools[length - 1];
        }

        return address(0);
    }

}