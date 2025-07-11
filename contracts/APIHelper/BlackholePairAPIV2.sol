// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;


import '../libraries/Math.sol';
import '../interfaces/IBribeAPI.sol';
import '../interfaces/IGaugeAPI.sol';

import '../interfaces/IGaugeFactory.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IMinter.sol';
import '../interfaces/IPair.sol';
import '../interfaces/IPairInfo.sol';
import '../interfaces/IPairFactory.sol';
import '../interfaces/IVoter.sol';
import '../interfaces/IGaugeManager.sol';
import '../interfaces/IVotingEscrow.sol';
import '../../contracts/Pair.sol';
import '../interfaces/IRouter.sol';
import '../interfaces/IAlgebraPoolAPIStorage.sol';

import '../interfaces/IAlgebraCLFactory.sol';


import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import '@cryptoalgebra/integral-periphery/contracts/interfaces/IQuoterV2.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';

import "hardhat/console.sol";

import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";

contract BlackholePairAPIV2 is Initializable {

    struct pairInfo {
        // pair info
        address pair_address; 			// pair contract address
        string symbol; 				    // pair symbol
        string name;                    // pair name
        uint decimals; 			        // pair decimals
        bool stable; 				    // pair pool type (stable = false, means it's a variable type of pool)
        uint total_supply; 			    // pair tokens supply
    
        // token pair info
        address token0; 				// pair 1st token address
        string token0_symbol; 			// pair 1st token symbol
        uint token0_decimals; 		    // pair 1st token decimals
        uint reserve0; 			        // pair 1st token reserves (nr. of tokens in the contract)
        uint claimable0;                // claimable 1st token from fees (for unstaked positions)

        address token1; 				// pair 2nd token address
        string token1_symbol;           // pair 2nd token symbol
        uint token1_decimals;    		// pair 2nd token decimals
        uint reserve1; 			        // pair 2nd token reserves (nr. of tokens in the contract)
        uint claimable1; 			    // claimable 2nd token from fees (for unstaked positions)

        // pairs gauge
        address gauge; 				    // pair gauge address
        uint gauge_total_supply; 		// pair staked tokens (less/eq than/to pair total supply)
        uint emissions; 			    // pair emissions (per second)
        uint total_emissions; 			// total pair emissions (per second)
        address emissions_token; 		// pair emissions token address
        uint emissions_token_decimals; 	// pair emissions token decimals

        // User deposit
        uint account_lp_balance; 		// account LP tokens balance
        uint account_token0_balance; 	// account 1st token balance
        uint account_token1_balance; 	// account 2nd token balance
        uint account_gauge_balance;     // account pair staked in gauge balance
        uint account_gauge_earned; 		// account earned emissions for this pair

        uint account_staked_unlock;     // account pair staked in gauge balance

        // votes
        uint votes;

        // fees
        uint staked_token0_fees;      // staked token 0 fees accumulated till now
        uint staked_token1_fees;      // staked token 1 fees accumulated till now

        // bribes
        Bribes internal_bribes;
        Bribes external_bribes;

        bool isGenesisRunning;
    }

    struct tokenBribe {
        address token;
        uint8 decimals;
        uint256 amount;
        string symbol;
    }
    

    struct pairBribeEpoch {
        uint256 epochTimestamp;
        uint256 totalVotes;
        address pair;
        tokenBribe[] bribes;
    }

    struct Bribes {
        address bribeAddress;
        address[] tokens;
        string[] symbols;
        uint[] decimals;
        uint[] amounts;
    }

    struct Rewards {
        Bribes[] bribes;
    }

    struct swapRoute{
        uint amountOut;
        uint hops;
        route[] routes;
    }

    struct route {
        address pair;
        address from;
        address to;
        bool stable;
        bool concentrated;
        uint amountOut;
        address receiver;
        uint160 sqrtPriceAfter;
    }

    struct SwapRouteHelperData {
        address _pair1;
        address _pair2;
        address _pairMid;
        bool isBasic1;
        bool isBasic2; 
        bool isBasicMid; 
        address otherToken1;
        address otherToken2;
        uint256 minAmount;
        bool foundPath;
        uint deployersLength;
        uint tempAmountOut;
        uint160 sqrtPriceAfter;
    }

    struct CLOutputData {
        uint256 amountOut;
        uint256 amountIn;
        uint160 sqrtPriceX96After;
        uint32 initializedTicksCrossed;
        uint256 gasEstimate;
        uint16 fee;
    }

    uint256 public constant MAX_PAIRS = 1000;
    uint256 public constant MAX_EPOCHS = 200;
    uint256 public constant MAX_REWARDS = 16;

    IPairFactory public pairFactory;
    IAlgebraCLFactory public algebraFactory;
    IQuoterV2 public quoterV2;

    IVoter public voter;
    IGaugeManager public gaugeManager;
    address public routerV2;
    IAlgebraPoolAPIStorage public algebraPoolAPIStorage;

    address public underlyingToken;

    address public owner;


    event Owner(address oldOwner, address newOwner);
    event Voter(address oldVoter, address newVoter);
    event GaugeManager(address oldGaugeManager, address newGaugeManager);
    event WBF(address oldWBF, address newWBF);
    event swapped(address pairAddress);

    constructor() {}


    function initialize(address _voter, address _router, address _gaugeManager, address _pairFactory, address _algebraFactory, address _quoterV2, address _algebraPoolAPIStorage) initializer public {

  
        owner = msg.sender;

        voter = IVoter(_voter);
        gaugeManager = IGaugeManager(_gaugeManager);

        routerV2 = _router;

        algebraFactory = IAlgebraCLFactory(_algebraFactory);

        algebraPoolAPIStorage = IAlgebraPoolAPIStorage(_algebraPoolAPIStorage);

        quoterV2 = IQuoterV2(_quoterV2);

        pairFactory = IPairFactory(_pairFactory);
        underlyingToken = IVotingEscrow(voter._ve()).token();
    }

    function getClaimable(address _account, address _pair) internal view returns(uint claimable0, uint claimable1){

        if(address(_account) == address(0)){
            return (0,0);
        }
        
        Pair pair = Pair(_pair);

        uint _supplied = pair.balanceOf(_account); // get LP balance of `_user`
        uint _claim0 = pair.claimable0(_account);
        uint _claim1 = pair.claimable1(_account);
        if (_supplied > 0) {
            uint _supplyIndex0 = pair.supplyIndex0(_account); // get last adjusted index0 for recipient
            uint _supplyIndex1 = pair.supplyIndex1(_account);
            uint _index0 = pair.index0(); // get global index0 for accumulated fees
            uint _index1 = pair.index1();
            uint _delta0 = _index0 - _supplyIndex0; // see if there is any difference that need to be accrued
            uint _delta1 = _index1 - _supplyIndex1;
            if (_delta0 > 0) {
                _claim0 += _supplied * _delta0 / 1e18; // add accrued difference for each supplied token
            }
            if (_delta1 > 0) {
                _claim1 += _supplied * _delta1 / 1e18;
            }
        } 

        return (_claim0, _claim1);
    }


    // valid only for sAMM and vAMM
    function getAllPair(address _user, uint _amounts, uint _offset) external view returns(uint totPairs, bool hasNext, pairInfo[] memory pairs, uint epochDuration){

        
        require(_amounts <= MAX_PAIRS, 'tp');

        pairs = new pairInfo[](_amounts);
        
        uint i = _offset;
        totPairs = pairFactory.allPairsLength();
        hasNext = true;
        address _pair;
        uint claim0;
        uint claim1;
        uint stakedToken0Fees;     
        uint stakedToken1Fees; 
        Bribes[] memory bribes;
        epochDuration = BlackTimeLibrary.WEEK;

        for(i; i < _offset + _amounts; i++){
            // if totalPairs is reached, break.
            if(i >= totPairs) {
                hasNext = false;
                break;
            }
            _pair = pairFactory.allPairs(i);
            pairs[i - _offset] = _pairAddressToInfo(_pair, _user);

            (claim0, claim1) = getClaimable(_user, _pair);
            pairs[i - _offset].claimable0 = claim0;
            pairs[i - _offset].claimable1 = claim1;

            (stakedToken0Fees, stakedToken1Fees) = getClaimable(pairs[i - _offset].gauge, _pair);
            pairs[i - _offset].staked_token0_fees = stakedToken0Fees;
            pairs[i - _offset].staked_token1_fees = stakedToken1Fees;  

            bribes = _getBribes(_pair);
            pairs[i - _offset].external_bribes = bribes[0];
            pairs[i - _offset].internal_bribes = bribes[1];  
        }

    }

    function getPair(address _pair, address _account) external view returns(pairInfo memory _pairInfo){
        pairInfo memory pairInformation =  _pairAddressToInfo(_pair, _account);
        uint claim0;
        uint claim1;
        uint stakedToken0Fees;     
        uint stakedToken1Fees; 

        (claim0, claim1) = getClaimable(_account, _pair);
        pairInformation.claimable0 = claim0;
        pairInformation.claimable1 = claim1;

        (stakedToken0Fees, stakedToken1Fees) = getClaimable(pairInformation.gauge, _pair);
        pairInformation.staked_token0_fees = stakedToken0Fees;
        pairInformation.staked_token1_fees = stakedToken1Fees;  

        Bribes[] memory bribes;
        bribes = _getBribes(_pair);
        pairInformation.external_bribes = bribes[0];
        pairInformation.internal_bribes = bribes[1];
        return pairInformation;
    }

    function _pairAddressToInfo(address _pair, address _account) internal view returns(pairInfo memory _pairInfo) {

        IPair ipair = IPair(_pair); 
        
        address token_0 = ipair.token0();
        address token_1 = ipair.token1();
        uint r0;
        uint r1;

        // checkout is v2 or v3? if v3 then load algebra pool 
        bool _type = IPairFactory(pairFactory).isPair(_pair);
        
        if(_type == false){
            // hypervisor totalAmounts = algebra.pool + gamma.unused
        } else {
            (r0,r1,) = ipair.getReserves();
        }

        IGaugeAPI _gauge = IGaugeAPI(gaugeManager.gauges(_pair));
        uint accountGaugeLPAmount = 0;
        uint earned = 0;
        uint gaugeTotalSupply = 0;
        uint emissions = 0;
        
        {
            if(address(_gauge) != address(0)){
                if(_account != address(0)){
                    accountGaugeLPAmount = _gauge.balanceOf(_account);
                    earned = _gauge.earned(_account);
                } else {
                    accountGaugeLPAmount = 0;
                    earned = 0;
                }
                gaugeTotalSupply = _gauge.totalSupply();
                emissions = _gauge.rewardRate();
                _pairInfo.total_emissions = _gauge.rewardForDuration();
            }
        }
        

        // Pair General Info
        _pairInfo.pair_address = _pair;
        _pairInfo.symbol = ipair.symbol();
        _pairInfo.name = ipair.name();
        _pairInfo.decimals = ipair.decimals();
        _pairInfo.stable = _type == false ? false : ipair.isStable();
        _pairInfo.total_supply = ipair.totalSupply();        
        
        // Token0 Info
        _pairInfo.token0 = token_0;
        _pairInfo.token0_decimals = IERC20(token_0).decimals();
        _pairInfo.token0_symbol = IERC20(token_0).symbol();
        _pairInfo.reserve0 = r0;
        _pairInfo.claimable0 = _type == false || _account == address(0) ? 0 : ipair.claimable0(_account);

        // Token1 Info
        _pairInfo.token1 = token_1;
        _pairInfo.token1_decimals = IERC20(token_1).decimals();
        _pairInfo.token1_symbol = IERC20(token_1).symbol();
        _pairInfo.reserve1 = r1;
        _pairInfo.claimable1 = _type == false || _account == address(0) ? 0 : ipair.claimable1(_account);

        
        // Pair's gauge Info
        _pairInfo.gauge = address(_gauge);
        _pairInfo.gauge_total_supply = gaugeTotalSupply;
        _pairInfo.emissions = emissions;
        _pairInfo.emissions_token = underlyingToken;
        _pairInfo.emissions_token_decimals = IERC20(underlyingToken).decimals();			    

        // Account Info
        _pairInfo.account_lp_balance = _account == address(0) ? 0 : IERC20(_pair).balanceOf(_account);
        _pairInfo.account_token0_balance = _account == address(0) ? 0 : IERC20(token_0).balanceOf(_account);
        _pairInfo.account_token1_balance = _account == address(0) ? 0 : IERC20(token_1).balanceOf(_account);
        _pairInfo.account_gauge_balance = accountGaugeLPAmount;
        _pairInfo.account_gauge_earned = earned;
        _pairInfo.account_staked_unlock = _account != address(0) && address(_gauge) != address(0) ? _gauge.maturityTime(_account) : 0;

        // votes
        _pairInfo.votes = voter.weights(_pair);   

        // genesis
        _pairInfo.isGenesisRunning = pairFactory.isGenesis(_pair);
    }

    // read all the bribe available for a pair
    function _getBribes(address pair) internal view returns(Bribes[] memory){

        address _gaugeAddress;
        address _bribeAddress;

        Bribes[] memory _tempReward = new Bribes[](2);

        // get external
        _gaugeAddress = gaugeManager.gauges(pair);

        {
            if(address(_gaugeAddress) != address(0)){
                
                _bribeAddress = gaugeManager.external_bribes(_gaugeAddress);
                _tempReward[0] = _getNextEpochRewards(_bribeAddress);
                
                // get internal
                _bribeAddress = gaugeManager.internal_bribes(_gaugeAddress);
                _tempReward[1] = _getNextEpochRewards(_bribeAddress);
            }
        }

        return _tempReward;
            
    }

    function _getNextEpochRewards(address _bribeAddress) internal view returns(Bribes memory _rewards){
        uint totTokens = IBribeAPI(_bribeAddress).rewardsListLength();
        uint[] memory _amounts = new uint[](totTokens);
        address[] memory _tokens = new address[](totTokens);
        string[] memory _symbol = new string[](totTokens);
        uint[] memory _decimals = new uint[](totTokens);
        uint ts = BlackTimeLibrary.epochStart(block.timestamp);
        uint i = 0;
        address _token;

        for(i; i < totTokens; i++){
            _token = IBribeAPI(_bribeAddress).bribeTokens(i);
            _tokens[i] = _token;
            _symbol[i] = IERC20(_token).symbol();
            _decimals[i] = IERC20(_token).decimals();
            _amounts[i] = IBribeAPI(_bribeAddress).tokenRewardsPerEpoch(_token, ts);
        }

        _rewards.bribeAddress = _bribeAddress;
        _rewards.tokens = _tokens;
        _rewards.amounts = _amounts;
        _rewards.symbols = _symbol;
        _rewards.decimals = _decimals;
    }

    function getCurrentFees(address _pair, address token_0, address token_1)  internal view returns(uint _tokenFees0, uint _tokenFees1, address _feesAddress) {
        Pair pair = Pair(_pair);  

        address feesAddress = pair.fees();
        uint tokenFees0 = IERC20(token_0).balanceOf(feesAddress);
        uint tokenFees1 = IERC20(token_1).balanceOf(feesAddress);

        return (tokenFees0, tokenFees1, feesAddress);
    }


    function setOwner(address _owner) external {
        require(msg.sender == owner);
        require(_owner != address(0));
        owner = _owner;
        emit Owner(msg.sender, _owner);
    }


    function setVoter(address _voter) external {
        require(msg.sender == owner);
        require(_voter != address(0));
        address _oldVoter = address(voter);
        voter = IVoter(_voter);
        
        // update variable depending on voter
        pairFactory = IPairFactory(voter.factories()[0]);
        underlyingToken = IVotingEscrow(voter._ve()).token();

        emit Voter(_oldVoter, _voter);
    }


    function setGaugeManager(address _gaugeManager) external {
        require(msg.sender == owner, 'no');
        require(_gaugeManager != address(0), 'zo');
        address _oldGaugeManager = address(gaugeManager);
        gaugeManager = IGaugeManager(_gaugeManager);
        emit GaugeManager(_oldGaugeManager, _gaugeManager);
    }
    
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut, address _userAddress) external returns (swapRoute memory swapRoutes){ //TODO:: this was view initially check
        
        SwapRouteHelperData memory swapRouteHelperData;

        bool stable;
        //uint totBasicPairs = pairFactory.allPairsLength();
        // uint totConcentratedPairs = algebraFactory.allPairsLength();

        swapRouteHelperData.minAmount = 0;

        //This is for direct Basic pool
        (swapRouteHelperData.minAmount, stable) = IRouter(routerV2).getAmountOut(amountIn, tokenIn, tokenOut);

        if (swapRouteHelperData.minAmount > 0) {
            swapRouteHelperData._pair1 = pairFactory.getPair(tokenIn, tokenOut, stable);

            if(pairFactory.isPair(swapRouteHelperData._pair1) && !pairFactory.isGenesis(swapRouteHelperData._pair1)){
                swapRoutes.routes = new route[](1);
                swapRoutes.routes[0] = _createRoute(swapRouteHelperData._pair1, tokenIn, tokenOut, true, swapRouteHelperData.minAmount, _userAddress, 0);
                swapRoutes.amountOut = swapRouteHelperData.minAmount;
                swapRoutes.hops = 1;
            }
            else{
                swapRouteHelperData.minAmount = 0;
            }
        }

        //This is for direct Concentrated pool
        uint i;
        uint j;
        for(i = 0; i < 5; i++){
            swapRouteHelperData._pair1 = algebraFactory.customPoolByPair(algebraPoolAPIStorage.customDeployers(i), tokenIn < tokenOut ? tokenIn : tokenOut, tokenIn < tokenOut ? tokenOut : tokenIn);
            if(swapRouteHelperData._pair1 != address(0) && !_isDiscarded(swapRouteHelperData._pair1)){
                (swapRouteHelperData.tempAmountOut, swapRouteHelperData.sqrtPriceAfter) = _getCLPoolAmountOut(tokenIn, tokenOut, swapRouteHelperData._pair1, amountIn);
                if(swapRouteHelperData.tempAmountOut > swapRouteHelperData.minAmount){
                    swapRoutes.routes = new route[](1);
                    swapRouteHelperData.minAmount = swapRouteHelperData.tempAmountOut;
                    swapRoutes.routes[0] = _createRoute(swapRouteHelperData._pair1, tokenIn, tokenOut, false, swapRouteHelperData.minAmount, _userAddress, swapRouteHelperData.sqrtPriceAfter);
                    swapRoutes.amountOut = swapRouteHelperData.minAmount;
                    swapRoutes.hops = 1;
                }
            }
        }

        swapRouteHelperData.foundPath = false;
        swapRoute memory swapRouteFromHopping; 
        uint _minAmount;
        // for(i = 0; i < pairFactory.allPairsLength() + algebraFactory.allPairsLength(); i++){
        for(i = 0; i < 0; i++){
            if(i >= pairFactory.allPairsLength()){
                if(algebraPoolAPIStorage.pairToDeployer(algebraFactory.allPairs(i - pairFactory.allPairsLength())) == address(0) || _isDiscarded(algebraFactory.allPairs(i - pairFactory.allPairsLength())))continue;
                swapRouteHelperData.isBasic1 = false;
                swapRouteHelperData._pair1 = algebraFactory.allPairs(i - pairFactory.allPairsLength());
                _minAmount = 0;
                if( tokenOut == IAlgebraPool(swapRouteHelperData._pair1).token0() || tokenOut == IAlgebraPool(swapRouteHelperData._pair1).token1()){
                    swapRouteHelperData.otherToken1 = IAlgebraPool(swapRouteHelperData._pair1).token0() == tokenOut ? IAlgebraPool(swapRouteHelperData._pair1).token1(): IAlgebraPool(swapRouteHelperData._pair1).token0();
                    for(j = 0; j < 5; j++){
                        address _pair1 = algebraFactory.customPoolByPair(algebraPoolAPIStorage.customDeployers(j), tokenIn < swapRouteHelperData.otherToken1 ? tokenIn : swapRouteHelperData.otherToken1, tokenIn < swapRouteHelperData.otherToken1 ? swapRouteHelperData.otherToken1 : tokenIn);
                        if(_pair1 != address(0) && !_isDiscarded(_pair1)) {
                            (swapRouteHelperData.tempAmountOut, swapRouteHelperData.sqrtPriceAfter) = _getCLPoolAmountOut(tokenIn, swapRouteHelperData.otherToken1, _pair1, amountIn);
                            if(swapRouteHelperData.tempAmountOut > _minAmount){
                                _minAmount = swapRouteHelperData.tempAmountOut;
                                swapRouteHelperData._pair1 = _pair1;
                            }
                        }
                    }
                    swapRouteHelperData.isBasic2 = false;
                    swapRouteHelperData._pair2 = algebraFactory.allPairs(i - pairFactory.allPairsLength());
                    if(_minAmount == 0) continue;
                    swapRouteFromHopping = _getSwapRoutesFromTwoHop(swapRouteHelperData, amountIn, tokenIn, tokenOut, _userAddress);
                    if(swapRouteHelperData.foundPath){
                        swapRoutes = swapRouteFromHopping;
                    }

                    if(pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, true)!=address(0) || pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, true)!=address(0)){
                        swapRouteHelperData._pair1 = pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, true)!=address(0) ? pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, true): pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, true);
                        swapRouteHelperData._pair2 = algebraFactory.allPairs(i - pairFactory.allPairsLength());
                        swapRouteHelperData.isBasic1 = true;
                        swapRouteHelperData.isBasic2 = false;
                        swapRouteFromHopping = _getSwapRoutesFromTwoHop(swapRouteHelperData, amountIn, tokenIn, tokenOut, _userAddress);
                        if(swapRouteHelperData.foundPath){
                            swapRoutes = swapRouteFromHopping;
                        }
                    }

                    if(pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, false)!=address(0) || pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, false)!=address(0)){
                        swapRouteHelperData._pair1 = pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, false)!=address(0) ? pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, false): pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, false);
                        swapRouteHelperData._pair2 = algebraFactory.allPairs(i - pairFactory.allPairsLength());
                        swapRouteHelperData.isBasic1 = true;
                        swapRouteHelperData.isBasic2 = false;
                        swapRouteFromHopping = _getSwapRoutesFromTwoHop(swapRouteHelperData, amountIn, tokenIn, tokenOut, _userAddress);
                        if(swapRouteHelperData.foundPath){
                            swapRoutes = swapRouteFromHopping;
                        }
                    }
                }
            }
            else{
                swapRouteHelperData._pair1 = pairFactory.allPairs(i);
                swapRouteHelperData.isBasic1 = true;
                swapRouteHelperData.isBasic2 = true;
                if(pairFactory.isGenesis(swapRouteHelperData._pair1)) continue;
                if(tokenOut == IPair(swapRouteHelperData._pair1).token0() || tokenOut == IPair(swapRouteHelperData._pair1).token1()){
                    swapRouteHelperData.otherToken1 = IPair(swapRouteHelperData._pair1).token0() == tokenOut ? IPair(swapRouteHelperData._pair1).token1(): IPair(swapRouteHelperData._pair1).token0();

                    if(pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, true)!=address(0) || pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, true)!=address(0)){
                        swapRouteHelperData._pair1 = pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, true)!=address(0) ? pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, true): pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, true);
                        swapRouteHelperData._pair2 = pairFactory.allPairs(i);
                        swapRouteHelperData.isBasic2 = true;
                        swapRouteFromHopping = _getSwapRoutesFromTwoHop(swapRouteHelperData, amountIn, tokenIn, tokenOut, _userAddress);
                        if(swapRouteHelperData.foundPath){
                            swapRoutes = swapRouteFromHopping;
                        }
                    }

                    if(pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, false)!=address(0) || pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, false)!=address(0)){
                        swapRouteHelperData._pair1 = pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, false)!=address(0) ? pairFactory.getPair(swapRouteHelperData.otherToken1, tokenIn, false): pairFactory.getPair(tokenIn, swapRouteHelperData.otherToken1, false);
                        swapRouteHelperData._pair2 = pairFactory.allPairs(i);
                        swapRouteHelperData.isBasic2 = true;
                        swapRouteFromHopping = _getSwapRoutesFromTwoHop(swapRouteHelperData, amountIn, tokenIn, tokenOut, _userAddress);
                        if(swapRouteHelperData.foundPath){
                            swapRoutes = swapRouteFromHopping;
                        }
                    }
                    _minAmount = 0;
                    for(j = 0; j < 5; j++){
                        address _pair1 = algebraFactory.customPoolByPair(algebraPoolAPIStorage.customDeployers(j), tokenIn < swapRouteHelperData.otherToken1 ? tokenIn : swapRouteHelperData.otherToken1, tokenIn < swapRouteHelperData.otherToken1 ? swapRouteHelperData.otherToken1 : tokenIn);
                        if(_pair1 != address(0) && !_isDiscarded(_pair1)) {
                            (swapRouteHelperData.tempAmountOut, swapRouteHelperData.sqrtPriceAfter) = _getCLPoolAmountOut(tokenIn, swapRouteHelperData.otherToken1, _pair1, amountIn);
                            if(swapRouteHelperData.tempAmountOut > _minAmount){
                                _minAmount = swapRouteHelperData.tempAmountOut;
                                swapRouteHelperData._pair1 = _pair1;
                                swapRouteHelperData.isBasic1 = false;
                            }
                        }
                    }

                    swapRouteHelperData._pair2 = pairFactory.allPairs(i);
                    swapRouteHelperData.isBasic2 = true;
                    if(_minAmount == 0) continue;
                    swapRouteFromHopping = _getSwapRoutesFromTwoHop(swapRouteHelperData, amountIn, tokenIn, tokenOut, _userAddress);
                    if(swapRouteHelperData.foundPath){
                        swapRoutes = swapRouteFromHopping;
                    }
                }
                // swapRouteHelperData.otherToken1 = tokenIn == IPair(swapRouteHelperData._pair1).token0() ? IPair(swapRouteHelperData._pair1).token1() : IPair(swapRouteHelperData._pair1).token0();
            }
        }
    }

    // function _getPoolSwapRoutesFromThreeHop(SwapRouteHelperData memory swapRouteFromHopping, uint amountIn, address tokenIn, address tokenOut, address _userAddress) internal returns (swapRoute memory swapRoutes){
    //     uint256[] memory amounts;
    //     uint160[] memory sqrtPriceAfter;
    //     if(swapRouteFromHopping.isBasicMid){
    //         if(!pairFactory.isPair(swapRouteFromHopping._pairMid)) return swapRoutes;
    //         if(pairFactory.isGenesis(swapRouteFromHopping._pairMid)) return swapRoutes;
    //     }
        
        
    //     (amounts, sqrtPriceAfter) = _getAmountViaHopping(amountIn, tokenIn, swapRouteFromHopping.otherToken1, swapRouteFromHopping.otherToken2, tokenOut, swapRouteFromHopping);
    //     address receiver;
    //     if(amounts[0] > 0 && amounts[1] > 0 && amounts[2] > 0 && amounts[2] > swapRouteFromHopping.minAmount){
    //         swapRouteFromHopping.minAmount = amounts[2];
    //         swapRouteFromHopping.foundPath = true;
    //         swapRoutes.routes = new route[](3);

    //         receiver = swapRouteFromHopping.isBasicMid ? swapRouteFromHopping._pairMid: routerV2;

    //         swapRoutes.routes[0] = _createRoute(swapRouteFromHopping._pair1, tokenIn, swapRouteFromHopping.otherToken1, swapRouteFromHopping.isBasic1, amounts[0], receiver, sqrtPriceAfter[0]);

    //         receiver = swapRouteFromHopping.isBasic2 ? swapRouteFromHopping._pair2: routerV2;

    //         swapRoutes.routes[1] = _createRoute(swapRouteFromHopping._pairMid, swapRouteFromHopping.otherToken1, swapRouteFromHopping.otherToken2, swapRouteFromHopping.isBasicMid, amounts[1], receiver, sqrtPriceAfter[1]);

    //         swapRoutes.routes[2] = _createRoute(swapRouteFromHopping._pair2, swapRouteFromHopping.otherToken2, tokenOut, swapRouteFromHopping.isBasic2, amounts[2], _userAddress, sqrtPriceAfter[2]);

    //         swapRoutes.amountOut = amounts[2];
    //         swapRoutes.hops = 3;
    //     }
    //     return swapRoutes;
    // }

    function _getSwapRoutesFromTwoHop(SwapRouteHelperData memory swapRouteFromHopping, uint amountIn, address tokenIn, address tokenOut, address _userAddress) internal returns (swapRoute memory swapRoutes){
        (uint256[] memory amounts, uint160[] memory sqrtPriceAfter) = _getAmountViaHopping(amountIn, tokenIn, swapRouteFromHopping.otherToken1, tokenOut, swapRouteFromHopping);
        address receiver;
        swapRouteFromHopping.foundPath = false;
        if(amounts[0] > 0 && amounts[1] > 0 && amounts[1] > swapRouteFromHopping.minAmount && 
            !checkAvaxRoute(tokenIn, tokenOut, swapRouteFromHopping.otherToken1)){
            swapRouteFromHopping.minAmount = amounts[1];
            swapRouteFromHopping.foundPath = true;
            swapRoutes.routes = new route[](2);
            receiver = swapRouteFromHopping.isBasic2 ? swapRouteFromHopping._pair2: routerV2;
            swapRoutes.routes[0] = _createRoute(swapRouteFromHopping._pair1, tokenIn, swapRouteFromHopping.otherToken1, swapRouteFromHopping.isBasic1, amounts[0], receiver, sqrtPriceAfter[0]);
            swapRoutes.routes[1] = _createRoute(swapRouteFromHopping._pair2, swapRouteFromHopping.otherToken1, tokenOut, swapRouteFromHopping.isBasic2, amounts[1], _userAddress, sqrtPriceAfter[1]);
            swapRoutes.amountOut = amounts[1];
            swapRoutes.hops = 2;
        }
        return swapRoutes;
    }

    function checkAvaxRoute(address tokenIn, address tokenOut, address tokenMid) internal returns (bool){
        return tokenIn == 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7 ||
        tokenOut == 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7 ||
        tokenMid == 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    }


    function _getAmountViaHopping(uint amountIn, address tokenIn, address tokenMid, address tokenOut, SwapRouteHelperData memory swapRouteHelperData) internal returns (uint256[] memory amounts, uint160[] memory sqrtPriceAfter){

        amounts = new uint256[](2);
        sqrtPriceAfter = new uint160[](3);

        (amounts[0], sqrtPriceAfter[0]) = _getAmountOut(amountIn, tokenIn, tokenMid, swapRouteHelperData.isBasic1, swapRouteHelperData._pair1);
        (amounts[1], sqrtPriceAfter[1]) = _getAmountOut(amounts[0], tokenMid, tokenOut, swapRouteHelperData.isBasic2, swapRouteHelperData._pair2);

        return (amounts, sqrtPriceAfter);
    }

    // function _getAmountViaHopping(uint amountIn, address tokenIn, address tokenMid1, address tokenMid2, address tokenOut, SwapRouteHelperData memory swapRouteHelperData) internal returns (uint256[] memory amounts, uint160[] memory sqrtPriceAfter){

    //     amounts = new uint256[](3);
    //     sqrtPriceAfter = new uint160[](3);

    //     (amounts[0], sqrtPriceAfter[0]) = _getAmountOut(amountIn, tokenIn, tokenMid1, swapRouteHelperData.isBasic1, swapRouteHelperData._pair1);
    //     (amounts[1], sqrtPriceAfter[1]) = _getAmountOut(amounts[0], tokenMid1, tokenMid2, swapRouteHelperData.isBasicMid, swapRouteHelperData._pairMid);
    //     (amounts[2], sqrtPriceAfter[2]) = _getAmountOut(amounts[1], tokenMid2, tokenOut, swapRouteHelperData.isBasic2, swapRouteHelperData._pair2);

    //     return (amounts, sqrtPriceAfter);
    // }

    function _isDiscarded(address pool) internal pure returns (bool) {
        return pool == 0x037664daFceFEb8874cDea15c2e9912b7eCe8B7E ||
           pool == 0x0C292979Aa3c397dFB6a3C06c6fE08E2378678b0 ||
           pool == 0x276676E544585ad447147eb89c51daC54c14f9A0 ||
           pool == 0x419dE182A2Ab3d4e7b58a19B6e36DD8621B6200d ||
           pool == 0x4D1328203DB71cB1f7611a3e1Ee55A99bbd6335f ||
           pool == 0x6D4B16834AcfC6f35A5c912e7ecAB123f0277b95 ||
           pool == 0xa7fA6d28Cd99a8A0f3e9412931bA43c5a7512886 ||
           pool == 0xB5Afb4534661D2E30b29C97B080464e92d0d8EE2;
    }


    function _getCLPoolAmountOut(address tokenIn, address tokenOut, address pair, uint amountIn) internal returns (uint, uint160) {
        IQuoterV2.QuoteExactInputSingleParams memory clInputParams;
        clInputParams = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            deployer: IAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(pair),
            amountIn: amountIn,
            limitSqrtPrice: 0
        });

        try IQuoterV2(quoterV2).quoteExactInputSingle(clInputParams) returns (
            uint256 amountOut,
            uint256, 
            uint160 sqrtPriceAfter,  
            uint32, 
            uint256, 
            uint16  
        ) {
            return (amountOut, sqrtPriceAfter);
        } catch {
            return (0, 0); 
        }
    }

    function _getAmountOut(uint amountIn, address tokenIn, address tokenOut, bool isBasic, address pair) internal returns (uint256, uint160){

        IQuoterV2.QuoteExactInputSingleParams memory clInputParams;
        uint256 amountOut;
        uint160 sqrtPriceAfter;

        if(isBasic){
            amountOut = IRouter(routerV2).getPoolAmountOut(amountIn, tokenIn, pair);
            sqrtPriceAfter = 0;
        }
        else{
            clInputParams = IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: IAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(pair),
                amountIn: amountIn,
                limitSqrtPrice: 0
            });
            try quoterV2.quoteExactInputSingle(clInputParams) returns (
                uint256 _amountOut,
                uint256, 
                uint160 _sqrtPriceAfter,  
                uint32, 
                uint256, 
                uint16  
            ) {
                return (_amountOut, _sqrtPriceAfter);
            } catch {
                return (0, 0); 
            }
        }

        return (amountOut, sqrtPriceAfter);
    }

    //Basic -> Basic //Address
    //Basic->CL //Router
    //CL-Basic //Address
    //CL-CL //Router

    function _createRoute(address pair, address from, address to, bool isBasic, uint amountOut, address _receiver, uint160 sqrtPriceAfter) internal view returns (route memory) {
        return route({
            pair: pair,
            from: from,
            to: to,
            stable: isBasic ? IPair(pair).isStable() : false,
            concentrated: !isBasic,
            amountOut: amountOut,
            receiver: _receiver,
            sqrtPriceAfter: sqrtPriceAfter
        });
    }

    function setAlgebraFactory(address _algebraFactory) external {
        require(msg.sender == owner);
        algebraFactory = IAlgebraCLFactory(_algebraFactory);
    }

    function setQuoterV2(address _quoterV2) external {
        require(msg.sender == owner);
        quoterV2 = IQuoterV2(_quoterV2);
    }

    function setAlgebraPoolAPI(address _algebraPoolAPIStorage) external {
        require(msg.sender == owner);
        algebraPoolAPIStorage = IAlgebraPoolAPIStorage(_algebraPoolAPIStorage);
    }

    function setPairFactory(address _pairFactory) external {
        require(msg.sender == owner);
        pairFactory = IPairFactory(_pairFactory);
    }

    /// @notice get next epoch (where bribes are saved)
    function getNextEpochStart() public view returns(uint256){
        return BlackTimeLibrary.epochNext(block.timestamp);
    }
}
