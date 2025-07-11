// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IGenesisPoolBase.sol"; 
import '../interfaces/IGenesisPoolManager.sol';
import '../interfaces/IGenesisPoolFactory.sol';
import '../interfaces/IGenesisPool.sol';
import '../interfaces/IERC20.sol';
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";

contract GenesisPoolAPI is IGenesisPoolBase, Initializable {

    struct GenesisData {
        address genesisPool;
        address nativeToken;

        uint nativeTokensDecimal;
        uint fundingTokensDecimal;

        uint256 userDeposit;
        uint256 estimatedNativeAmount;

        TokenAllocation tokenAllocation;
        TokenIncentiveInfo incentiveInfo;
        GenesisInfo genesisInfo;
        LiquidityPool liquidityPool;
        PoolStatus poolStatus;
    }

    address public owner;
    IGenesisPoolManager public genesisManager;
    IGenesisPoolFactory public genesisPoolFactory;

    uint256 public constant MAX_POOLS = 1000;

    constructor() {}

    function initialize(address _genesisManager, address _genesisPoolFactory) initializer public {
  
        owner = msg.sender;

        genesisManager = IGenesisPoolManager(_genesisManager);
        genesisPoolFactory = IGenesisPoolFactory(_genesisPoolFactory);
    }

    function getGenesisPoolFromNative(address _user, address nativeToken) external view returns (GenesisData memory genesisData){
        address genesisPool = genesisPoolFactory.getGenesisPool(nativeToken);
        if(genesisPool == address(0)) return genesisData;

        return _getGenesisPool(_user, genesisPool);
    }

    function getGenesisPool(address _user, address genesisPool) external view returns (GenesisData memory genesisData){
        return _getGenesisPool(_user, genesisPool);
    }

    function _getGenesisPool(address _user, address genesisPool) internal view returns (GenesisData memory genesisData){
        GenesisInfo memory genesisInfo = IGenesisPool(genesisPool).getGenesisInfo();
        address fundingToken = genesisInfo.fundingToken;
        address nativeToken = genesisInfo.nativeToken;
        uint256 userDeposit;

        genesisData.nativeToken = nativeToken;
        genesisData.genesisPool = genesisPool;

        genesisData.nativeTokensDecimal = IERC20(nativeToken).decimals();
        genesisData.fundingTokensDecimal = IERC20(fundingToken).decimals();

        userDeposit = _user != address(0) ? IGenesisPool(genesisPool).userDeposits(_user) : 0;
        genesisData.userDeposit = userDeposit;
        genesisData.estimatedNativeAmount = userDeposit > 0 ? IGenesisPool(genesisPool).getNativeTokenAmount(userDeposit) : 0;

        genesisData.tokenAllocation = IGenesisPool(genesisPool).getAllocationInfo();
        genesisData.incentiveInfo = IGenesisPool(genesisPool).getIncentivesInfo();
        genesisData.genesisInfo = genesisInfo;
        genesisData.liquidityPool = IGenesisPool(genesisPool).getLiquidityPoolInfo();
        genesisData.poolStatus = IGenesisPool(genesisPool).poolStatus();
    }

    function getAllGenesisPools(address _user, uint _amounts, uint _offset) external view returns(uint totalPools, bool hasNext, GenesisData[] memory genesisPools){
        require(_amounts <= MAX_POOLS, 'TOO_MANY');

        genesisPools = new GenesisData[](_amounts);

        address[] memory proposedTokens = genesisManager.getLiveNaitveTokens();
        totalPools = proposedTokens.length;

        uint i = _offset;
        hasNext = true;
        address genesisPool;
        address nativeToken;
        GenesisInfo memory genesisInfo;
        uint256 userDeposit;

        for(i; i < _offset + _amounts; i++){
            if(i >= totalPools) {
                hasNext = false;
                break;
            }

            nativeToken = proposedTokens[i];

            genesisPool = genesisPoolFactory.getGenesisPool(nativeToken);
            genesisInfo = IGenesisPool(genesisPool).getGenesisInfo();

            genesisPools[i - _offset].genesisPool = genesisPool;
            genesisPools[i - _offset].nativeToken = nativeToken;

            genesisPools[i - _offset].nativeTokensDecimal = IERC20(nativeToken).decimals();
            genesisPools[i - _offset].fundingTokensDecimal = IERC20(genesisInfo.fundingToken).decimals();

            userDeposit = _user != address(0) ? IGenesisPool(genesisPool).userDeposits(_user) : 0;
            genesisPools[i - _offset].userDeposit = userDeposit;
            genesisPools[i - _offset].estimatedNativeAmount = userDeposit > 0 ? IGenesisPool(genesisPool).getNativeTokenAmount(userDeposit) : 0;

            genesisPools[i - _offset].tokenAllocation = IGenesisPool(genesisPool).getAllocationInfo();
            genesisPools[i - _offset].incentiveInfo = IGenesisPool(genesisPool).getIncentivesInfo();
            genesisPools[i - _offset].genesisInfo = genesisInfo;
            genesisPools[i - _offset].liquidityPool = IGenesisPool(genesisPool).getLiquidityPoolInfo();
            genesisPools[i - _offset].poolStatus = IGenesisPool(genesisPool).poolStatus();
        }

    }
   
    function getAllUserRelatedGenesisPools(address _user) external view returns(uint totalTokens, GenesisData[] memory genesisPools){
        address[] memory proposedTokens = genesisManager.getAllNaitveTokens();
        totalTokens = proposedTokens.length;

        uint i = 0;
        uint j = 0;
        uint count = 0;
        IGenesisPool genesisPool;
        address[] memory genesisPoolsPerToken;
        address nativeToken;
        PoolStatus poolStatus;
        uint256 userDeposit;

        for(i; i < totalTokens; i++){
            nativeToken = proposedTokens[i];
            j = 0;
            genesisPoolsPerToken = genesisPoolFactory.getGenesisPools(nativeToken);
            for(j; j < genesisPoolsPerToken.length; j++){

                if(genesisPoolsPerToken[j] == address(0)) continue;

                genesisPool = IGenesisPool(genesisPoolsPerToken[j]);
                poolStatus = genesisPool.poolStatus();

                if(poolStatus == PoolStatus.DEFAULT || poolStatus == PoolStatus.LAUNCH)
                    continue;
                
                userDeposit = _user != address(0) ? genesisPool.userDeposits(_user) : 0;

                if(_hasClaimbaleForOwner(_user, userDeposit, poolStatus, genesisPool.getGenesisInfo().tokenOwner, genesisPool.getAllocationInfo(), genesisPool.getIncentivesInfo())){
                    count++;
                }
            }
        }

        genesisPools = new GenesisData[](count);
        uint index = 0;
        i = 0;

        for(i; i < totalTokens; i++){
            nativeToken = proposedTokens[i];
            j = 0;
            genesisPoolsPerToken = genesisPoolFactory.getGenesisPools(nativeToken);
            for(j; j < genesisPoolsPerToken.length; j++){

                if(genesisPoolsPerToken[j] == address(0)) continue;
                
                genesisPool = IGenesisPool(genesisPoolsPerToken[j]);
                poolStatus = genesisPool.poolStatus();

                if(poolStatus == PoolStatus.DEFAULT || poolStatus == PoolStatus.LAUNCH)
                    continue;
                
                userDeposit = _user != address(0) ? genesisPool.userDeposits(_user) : 0;


                if(_hasClaimbaleForOwner(_user, userDeposit, poolStatus, genesisPool.getGenesisInfo().tokenOwner, genesisPool.getAllocationInfo(), genesisPool.getIncentivesInfo())){
                
                    genesisPools[index].genesisPool = genesisPoolsPerToken[j];
                    genesisPools[index].nativeToken = nativeToken;

                    genesisPools[index].nativeTokensDecimal = IERC20(nativeToken).decimals();
                    genesisPools[index].fundingTokensDecimal = IERC20(genesisPool.getGenesisInfo().fundingToken).decimals();

                    genesisPools[index].userDeposit = userDeposit;
                    genesisPools[index].estimatedNativeAmount = userDeposit > 0 ? genesisPool.getNativeTokenAmount(userDeposit) : 0;

                    genesisPools[index].tokenAllocation = genesisPool.getAllocationInfo();
                    genesisPools[index].incentiveInfo = genesisPool.getIncentivesInfo();
                    genesisPools[index].genesisInfo = genesisPool.getGenesisInfo();
                    genesisPools[index].liquidityPool = genesisPool.getLiquidityPoolInfo();
                    genesisPools[index].poolStatus = genesisPool.poolStatus();
                    index++;
                }
            }
        }

        totalTokens = count;
    }

    function _hasClaimbaleForOwner(address _user, uint256 userDeposit, PoolStatus poolStatus, address tokenOwner, TokenAllocation memory tokenAllocation, TokenIncentiveInfo memory incentiveInfo) internal pure returns (bool) {
        if(_user == tokenOwner){
            if(poolStatus == PoolStatus.NOT_QUALIFIED){
                return (tokenAllocation.refundableNativeAmount > 0 || incentiveInfo.incentivesToken.length > 0);
            }
            else if(poolStatus == PoolStatus.NATIVE_TOKEN_DEPOSITED){
                return (tokenAllocation.proposedNativeAmount > 0 || incentiveInfo.incentivesToken.length > 0);
            }
            else if(poolStatus == PoolStatus.PRE_LISTING || poolStatus == PoolStatus.PRE_LAUNCH || poolStatus == PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED){
                return true;
            }
            else if(poolStatus == PoolStatus.PARTIALLY_LAUNCHED){
                return tokenAllocation.refundableNativeAmount > 0;
            }
            return false;
        }else if(userDeposit > 0){
            return (poolStatus == PoolStatus.PRE_LISTING || poolStatus == PoolStatus.PRE_LAUNCH || poolStatus == PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED || poolStatus == PoolStatus.NOT_QUALIFIED); 
        }
        return false;
    }
}