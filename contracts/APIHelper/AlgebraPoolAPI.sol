// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IGaugeCL.sol';
import '../interfaces/IGaugeManager.sol';

import '../interfaces/IVoter.sol';
import '../interfaces/IAlgebraCLFactory.sol';
import '../interfaces/IBribeAPI.sol';
import '../interfaces/IVotingEscrow.sol';
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";


contract AlgebraPoolAPI is Initializable {

    IAlgebraCLFactory public algebraFactory;
    INonfungiblePositionManager public nonfungiblePositionManager;

    struct PoolInfo {
        // pair info
        address pair_address; 			// pair contract address
        string symbol; 				    // pair symbol
        string name;                    // pair name
        uint decimals; 			        // pair decimals
        bool stable; 				    // pair pool type (stable = false, means it's a variable type of pool)
        uint total_supply; 			    // pair tokens supply

        // token pair info
        address token0;
        address token1;
        string token0_symbol;
        string token1_symbol;
        uint8 token0_decimals;
        uint8 token1_decimals;		

        int24 tickSpacing;

        // Pool State
        uint160 sqrtPriceX96; // Current price
        int24 tick;           // Current tick
        uint128 liquidity;    // Current *active* liquidity in the pool
        uint16 fee;

        // Fee Growth (Global)
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;

        address gauge; 				    // pair gauge address
        uint gauge_total_supply; 		// pair staked tokens (less/eq than/to pair total supply)
        uint emissions; 			    // pair emissions (per second)
        uint total_emissions; 			// total pair emissions (per second)
        address emissions_token; 		// pair emissions token address
        uint emissions_token_decimals; 	// pair emissions token decimals

        uint votes;

        // fees
        uint staked_token0_fees;      // staked token 0 fees accumulated till now
        uint staked_token1_fees;      // staked token 1 fees accumulated till now

        Bribes internal_bribes;
        Bribes external_bribes;
    }

    // Struct to hold detailed information about an NFT position
    struct PositionInfo {
        uint256 tokenId;
        address token0;
        address token1;
        address deployer;
        address pair;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0; // Fees owed as of last action
        uint128 tokensOwed1; // Fees owed as of last action
        // Current claimable fees (calculated via staticcall to collect)
        uint256 claimableFee0;
        uint256 claimableFee1;
        // Optional: Add token symbols/decimals if needed, similar to PoolInfo
        string token0_symbol;
        string token1_symbol;
        uint8 token0_decimals;
        uint8 token1_decimals;
        uint256 account_token0_balance;
        uint256 account_token1_balance;
        // pairs gauge
        address gauge; 				    // pair gauge address
        address emissions_token; 		// pair emissions token address
        uint emissions_token_decimals; 	// pair emissions token decimals
        //user specific
        uint account_gauge_balance;    
        uint account_gauge_earned;
        bool isStaked; 
    }

    struct Bribes {
        address bribeAddress;
        address[] tokens;
        string[] symbols;
        uint[] decimals;
        uint[] amounts;
    }

    address public owner;

    IVoter public voter;
    IGaugeManager public gaugeManager;
    address public underlyingToken;

    event Owner(address oldOwner, address newOwner);
    event FactoryChanged(address indexed oldFactory, address indexed newFactory);
    event NonfungiblePositionManagerChanged(address indexed oldManager, address indexed newManager);

    function initialize(address _voter, address _factory, address _nonfungiblePositionManager, address _gaugeManager) public initializer {
        require(_factory != address(0), "Zero address: factory");
        require(_nonfungiblePositionManager != address(0), "Zero address: position manager");
        owner = msg.sender;
        algebraFactory = IAlgebraCLFactory(_factory);
        gaugeManager = IGaugeManager(_gaugeManager);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
        voter = IVoter(_voter);
        underlyingToken = IVotingEscrow(voter._ve()).token();
    }

    /// @notice Fetches information for multiple Algebra pools based on their addresses.
    /// @param _pools Array of pool addresses to query.
    /// @return infos Array of PoolInfo structs for the provided pool addresses. Invalid/uninitialized pools will have default values.
    function getAllPoolInfo(address[] calldata _pools)
        external
        view
        returns (PoolInfo[] memory infos)
    {
        uint256 numPools = _pools.length;
        infos = new PoolInfo[](numPools);

        for (uint i = 0; i < numPools; i++) {
            address pool = _pools[i];
            // Check if the address is valid and the pool appears initialized
            // A zero address or uninitialized pool will result in default PoolInfo struct values
            if (pool != address(0)) {
                try IAlgebraPool(pool).token0() returns (address token0Addr) {
                    // Check if token0 is non-zero, indicating initialization
                    if (token0Addr != address(0)) {
                         infos[i] = _poolAddressToInfo(pool);
                    }
                    // If token0 is zero, infos[i] remains default (zeroed)
                } catch {
                    // Handle cases where the address is not a contract or doesn't implement token0()
                    // infos[i] remains default (zeroed)
                }
            }
        }
    }

    /// @notice Fetches information for a single Algebra pool.
    /// @param _pool Address of the Algebra pool contract.
    /// @return info PoolInfo struct for the pool.
    function getPoolInfo(address _pool)
        external
        view
        returns (PoolInfo memory info)
    {
        require(_pool != address(0), "Zero address: pool");
        // Basic check if pool seems initialized
        require(IAlgebraPool(_pool).token0() != address(0), "Pool not initialized or invalid");
        info = _poolAddressToInfo(_pool);
    }


    /// @notice Internal function to gather data for a specific pool address.
    function _poolAddressToInfo(address _pool)
        internal
        view
        returns (PoolInfo memory info)
    {
        IAlgebraPool pool = IAlgebraPool(_pool);
        Bribes[] memory bribes;

        info.pair_address = _pool;
        info.token0 = pool.token0();
        info.token1 = pool.token1();
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();

        // Read globalState (slot0)
        (info.sqrtPriceX96, info.tick, info.fee, , , ) = pool.globalState();

        // Read fee growth globals
        info.feeGrowthGlobal0X128 = pool.totalFeeGrowth0Token();
        info.feeGrowthGlobal1X128 = pool.totalFeeGrowth1Token();

        IGaugeCL _gauge = IGaugeCL(gaugeManager.gauges(_pool));

        info.gauge = gaugeManager.gauges(_pool);

        {
            if(address(_gauge) != address(0)){
                try _gauge.totalSupply() returns (uint256 supply) {
                    info.gauge_total_supply = supply;
                } catch {
                    // If the call fails (e.g., gauge is not a standard ERC20 or reverts),
                    // set supply to 0 to indicate failure or absence of supply.
                    info.gauge_total_supply = 0;
                }
                info.emissions = _gauge.rewardRate();
                info.total_emissions = _gauge.rewardForDuration();
                (info.staked_token0_fees, info.staked_token1_fees) = IGaugeCL(info.gauge).stakedFees();
            }
        }

        bribes = _getBribes(_pool);

        info.votes = voter.weights(_pool); 

        info.external_bribes = bribes[0];
        info.internal_bribes = bribes[1]; 
        info.emissions_token = underlyingToken;
        info.emissions_token_decimals = IERC20(underlyingToken).decimals();

        // Get Token Info - Wrap in safe calls if tokens might not implement standard ERC20/might revert
        info.token0_symbol = IERC20(info.token0).symbol();
        info.token1_symbol = IERC20(info.token1).symbol();
        info.token0_decimals = IERC20(info.token0).decimals();
        info.token1_decimals = IERC20(info.token1).decimals();
    }

     /// @notice Sorts two token addresses.
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "Tokens must be different");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Fetches detailed information for multiple NFT positions.
    /// @param _tokenIds An array of NFT token IDs to query.
    /// @return positionsInfo An array of PositionInfo structs containing details for each requested tokenId.
    function getAllPositionsInfo(uint256[] calldata _tokenIds, address _user)
        external
        view
        returns (PositionInfo[] memory positionsInfo)
    {
        require(address(nonfungiblePositionManager) != address(0), "Manager not set");
        uint256 numTokenIds = _tokenIds.length;
        positionsInfo = new PositionInfo[](numTokenIds);

        for (uint i = 0; i < numTokenIds; i++) {
            uint256 tokenId = _tokenIds[i];
            positionsInfo[i].tokenId = tokenId;

            // 1. Get base position data
            (
                ,
                ,
                positionsInfo[i].token0,
                positionsInfo[i].token1,
                positionsInfo[i].deployer,
                positionsInfo[i].tickLower,
                positionsInfo[i].tickUpper,
                positionsInfo[i].liquidity,
                ,
                ,
                ,
            ) = nonfungiblePositionManager.positions(tokenId);

            // 2. Get current claimable fees via staticcall to collect
            // We use type(uint128).max to request the maximum possible amount
            (bool success, bytes memory result) = address(nonfungiblePositionManager).staticcall(
                abi.encodeWithSelector(
                    INonfungiblePositionManager.collect.selector,
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this), // recipient doesn't matter for staticcall view
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                )
            );

            if (success && result.length >= 64) { // Expecting two uint256 values
                (positionsInfo[i].claimableFee0, positionsInfo[i].claimableFee1) = abi.decode(result, (uint256, uint256));
            } else {
                // Handle potential revert from staticcall (e.g., token ID doesn't exist)
                // Keep claimable fees as 0 or revert the whole call, depending on desired behavior.
                // Here, we'll just leave them as 0. Consider adding error handling if needed.
                positionsInfo[i].claimableFee0 = 0;
                positionsInfo[i].claimableFee1 = 0;
            }

            positionsInfo[i].pair = IAlgebraCLFactory(algebraFactory).computeCustomPoolAddress(positionsInfo[i].deployer, positionsInfo[i].token0, positionsInfo[i].token1);
            positionsInfo[i].isStaked = nonfungiblePositionManager.tokenFarmedIn(tokenId) != address(0);

            IGaugeCL _gauge = IGaugeCL(gaugeManager.gauges(positionsInfo[i].pair));

            {
                if(address(_gauge) != address(0)){
                    positionsInfo[i].gauge = address(_gauge);
                    if(_user != address(0) && positionsInfo[i].isStaked){
                        positionsInfo[i].account_gauge_balance = _gauge.balanceOf(tokenId); 
                        (positionsInfo[i].account_gauge_earned, ) = _gauge.earned(tokenId);
            
                        // (bool success, bytes memory result) = address(_gauge).staticcall(
                        //     abi.encodeWithSelector(
                        //         IGaugeCL.earned.selector,
                        //         tokenId
                        //     )
                        // );
                        // if(success){
                        //     (positionsInfo[i].account_gauge_earned, ) = abi.decode(result, (uint256, uint256));
                        // }else{
                        //     positionsInfo[i].account_gauge_earned = 0;
                        // }
                    } else {
                        positionsInfo[i].account_gauge_balance = 0;
                        positionsInfo[i].account_gauge_earned = 0;
                    }
                }
            }

            positionsInfo[i].emissions_token = underlyingToken;
            positionsInfo[i].emissions_token_decimals = IERC20(underlyingToken).decimals();

             // 3. (Optional) Get token symbols and decimals
             // This adds extra external calls, increasing gas cost further.
             // Only include if necessary for the API consumer.
            positionsInfo[i].token0_symbol = IERC20(positionsInfo[i].token0).symbol();
            positionsInfo[i].token1_symbol = IERC20(positionsInfo[i].token1).symbol();
            positionsInfo[i].token0_decimals = IERC20(positionsInfo[i].token0).decimals();
            positionsInfo[i].token1_decimals = IERC20(positionsInfo[i].token1).decimals();
            positionsInfo[i].account_token0_balance = IERC20(positionsInfo[i].token0).balanceOf(_user);
            positionsInfo[i].account_token1_balance = IERC20(positionsInfo[i].token1).balanceOf(_user);
        }
    }

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

    

    function setOwner(address _owner) external {
        require(msg.sender == owner, 'not owner');
        require(_owner != address(0), 'zeroAddr');
        owner = _owner;
        emit Owner(msg.sender, _owner);
    }

    function setVoter(address _voter) external {
        require(msg.sender == owner, 'not owner');
        require(_voter != address(0), 'zeroAddr');
        address _oldVoter = address(voter);
        voter = IVoter(_voter);
        underlyingToken = IVotingEscrow(voter._ve()).token();
    }

    /// @notice Updates the Algebra Factory address (onlyOwner).
    function setFactory(address _newFactory) external {
        require(msg.sender == owner, 'not owner');
        require(_newFactory != address(0), "Zero address: new factory");
        address oldFactory = address(algebraFactory);
        algebraFactory = IAlgebraCLFactory(_newFactory);
        emit FactoryChanged(oldFactory, _newFactory);
    }

    /// @notice Updates the Nonfungible Position Manager address (onlyOwner).
    function setNonfungiblePositionManager(address _newManager) external {
        require(msg.sender == owner, 'not owner');
        require(_newManager != address(0), "Zero address: new manager");
        address oldManager = address(nonfungiblePositionManager);
        nonfungiblePositionManager = INonfungiblePositionManager(_newManager);
        emit NonfungiblePositionManagerChanged(oldManager, _newManager);
    }

    function setGaugeManager(address _gaugeManager) external {
        require(msg.sender == owner, 'not owner');
        require(_gaugeManager != address(0), "Zero address: gauge");
        gaugeManager = IGaugeManager(_gaugeManager);
    }
}
