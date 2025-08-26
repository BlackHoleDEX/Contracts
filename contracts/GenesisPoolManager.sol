// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IGenesisPoolManager.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/IGenesisPoolBase.sol";
import "./interfaces/IGauge.sol";

import "./interfaces/ITokenHandler.sol";
import "./interfaces/IPermissionsRegistry.sol";
import "./interfaces/IGenesisPoolFactory.sol";
import './interfaces/IGenesisPool.sol';
import './interfaces/IAuctionFactory.sol';
import './interfaces/IPair.sol';
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

interface IBaseV1Factory {
    function isPair(address pair) external view returns (bool);
    function getPair(address tokenA, address token, bool stable) external view returns (address);
    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);
    function setGenesisPool(address _genesisPool) external;
    function setGenesisStatus(address _pair, bool status) external;
}

contract GenesisPoolManager is IGenesisPoolBase, IGenesisPoolManager, Ownable {

    uint256 public MIN_DURATION;
    uint256 public MIN_THRESHOLD;
    uint256 public MATURITY_TIME;

    address public epochController;
    address public permissionRegistory;
    address public router;
    IBaseV1Factory public pairFactory;

    IGaugeManager public gaugeManager;
    ITokenHandler public tokenHandler;

    IGenesisPoolFactory public genesisFactory;
    IAuctionFactory public auctionFactory;

    uint public WEEK;
    uint public pre_epoch_period; // 2 : 30 of every thursday

    using SafeERC20 for IERC20;

    mapping(address => mapping(address => bool)) public whiteListedTokensToUser;
    address[] public nativeTokens;
    address[] public liveNativeTokens;
    mapping(address => uint256) internal liveNativeTokensIndex;
    mapping(address => bool) internal isNativeToken;
    uint256 public processingIndex;
    uint256 public epochFlipProcessingIndex;


    event WhiteListedTokenToUser(address proposedToken, address tokenOwner);
    event DespositedToken(address genesisPool, address sender, uint256 amount);

    modifier Governance() {
        require(IPermissionsRegistry(permissionRegistory).hasRole("GOVERNANCE",msg.sender), 'GOVERNANCE');
        _;
    }

    function _checkGovernance() internal view returns (bool) {
        return IPermissionsRegistry(permissionRegistory).hasRole("GOVERNANCE",msg.sender);
    }

    modifier GenesisManager() {
        require(IPermissionsRegistry(permissionRegistory).hasRole("GENESIS_MANAGER", msg.sender), 'GENESIS_MANAGER');
        _;
    }

    modifier EpochManagerOrGenesisManager() {
        require(IPermissionsRegistry(permissionRegistory).hasRole("EPOCH_MANAGER", msg.sender) || IPermissionsRegistry(permissionRegistory).hasRole("GENESIS_MANAGER", msg.sender), 'EPOCH_MANAGER_OR_GENESIS_MANAGER');
        _;
    }

    constructor(address _epochController, address _router, address _permissionRegistory, address _gaugeManager, address _pairFactory, address _genesisFactory, address _auctionFactory, address _tokenHandler) {
        epochController = _epochController;
        router = _router;
        permissionRegistory = _permissionRegistory;
        gaugeManager = IGaugeManager(_gaugeManager);
        pairFactory = IBaseV1Factory(_pairFactory);
        genesisFactory = IGenesisPoolFactory(_genesisFactory);
        auctionFactory = IAuctionFactory(_auctionFactory);
        tokenHandler = ITokenHandler(_tokenHandler);
        WEEK = BlackTimeLibrary.WEEK;
        MIN_DURATION = 2 * BlackTimeLibrary.WEEK;
        MIN_THRESHOLD = 50 * 10 ** 2;
        MATURITY_TIME = BlackTimeLibrary.GENESIS_STAKING_MATURITY_TIME;

        pre_epoch_period = BlackTimeLibrary.prevPreEpoch(block.timestamp);
        processingIndex = 0;
        epochFlipProcessingIndex =0;
    }

    function check() external view returns (bool) {
        uint _period = pre_epoch_period;
        return block.timestamp >= _period + WEEK;
    }

    function whiteListUserAndToken(address tokenOwner, address proposedToken) external Governance {
        whiteListedTokensToUser[proposedToken][tokenOwner] = true;
        emit WhiteListedTokenToUser(proposedToken, tokenOwner);
    }

    function liveNativeTokensLength() external view returns (uint256) {
        return liveNativeTokens.length;
    }

    function depositNativeToken(address nativeToken, uint auctionIndex, GenesisInfo calldata genesisPoolInfo, TokenAllocation calldata allocationInfo) external returns(address genesisPool) {
        address _sender = msg.sender;
        require(whiteListedTokensToUser[nativeToken][_sender] || _checkGovernance(), "!WHITELIST");
        require(nativeToken == genesisPoolInfo.nativeToken, "IA");
        require(_sender == genesisPoolInfo.tokenOwner, "NA");
        require(allocationInfo.proposedNativeAmount > 0, "ZV");
        require(allocationInfo.proposedFundingAmount > 0, "ZV");

        address _fundingToken = genesisPoolInfo.fundingToken;
        require(tokenHandler.isConnector(_fundingToken), "!CONN");
        bool _stable = genesisPoolInfo.stable;

        address pairAddress = pairFactory.getPair(nativeToken, _fundingToken, _stable);
        if (pairAddress == address(0)) {
            pairAddress = pairFactory.createPair(nativeToken, _fundingToken, _stable);
        } else {
            require(IERC20(nativeToken).balanceOf(pairAddress) == 0, "!ZV");
            require(IERC20(_fundingToken).balanceOf(pairAddress) == 0, "!ZV");
        }
        pairFactory.setGenesisStatus(pairAddress, true);

        require(genesisPoolInfo.duration >= MIN_DURATION && genesisPoolInfo.threshold >= MIN_THRESHOLD && genesisPoolInfo.startPrice > 0, "INV_GENESIS");
        require(genesisPoolInfo.supplyPercent > 0 && genesisPoolInfo.supplyPercent <= 10000, "INV");

        require(genesisPoolInfo.nativeToken == nativeToken, "MISMATCH");

        genesisPool = genesisFactory.getGenesisPool(nativeToken);
        if(genesisPool == address(0))
            genesisPool = genesisFactory.createGenesisPool(_sender, nativeToken, _fundingToken);

        require(genesisPool != address(0), "ZA");
        IERC20(nativeToken).safeTransferFrom(_sender, genesisPool, allocationInfo.proposedNativeAmount);

        address auction = auctionFactory.auctions(auctionIndex);
        auction = auction == address(0) ? auctionFactory.auctions(0) : auction;
        if(!isNativeToken[nativeToken]){
            nativeTokens.push(nativeToken);
            isNativeToken[nativeToken] = true;
        }
        GenesisInfo memory modifiedGenesisInfo = genesisPoolInfo;
        modifiedGenesisInfo.maturityTime = MATURITY_TIME; //The maturity time should be the value present in the GenesisPoolManager.
        IGenesisPool(genesisPool).setGenesisPoolInfo(modifiedGenesisInfo, allocationInfo, auction);
    }

    function rejectGenesisPool(address nativeToken) external Governance {
        require(nativeToken != address(0), "ZA");
        address genesisPool = genesisFactory.getGenesisPool(nativeToken);
        require(genesisPool != address(0), 'ZA');

        IGenesisPool(genesisPool).rejectPool();
        _removeLiveToken(nativeToken);
    }

    function approveGenesisPool(address nativeToken) external Governance {
        require(nativeToken != address(0), "ZA");
        address genesisPool = genesisFactory.getGenesisPool(nativeToken);
        require(genesisPool != address(0), 'ZA');

        GenesisInfo memory genesisInfo =  IGenesisPool(genesisPool).getGenesisInfo();
        require(genesisInfo.startTime + genesisInfo.duration - BlackTimeLibrary.NO_GENESIS_DEPOSIT_WINDOW > block.timestamp, "TIME");

        address pairAddress = pairFactory.getPair(nativeToken, genesisInfo.fundingToken, genesisInfo.stable);
        IPair ipair = IPair(pairAddress);
        (uint r0,uint r1,) = ipair.getReserves();
        require(r0 == 0 && r1 == 0, "!ZV");

        liveNativeTokens.push(nativeToken);
        liveNativeTokensIndex[nativeToken] = liveNativeTokens.length; // becuase default valie is 0, so starting with 1

        IGenesisPool(genesisPool).approvePool(pairAddress);
    }

    function depositToken(address genesisPool, uint256 amount) external{
        require(amount > 0, "ZV");
        require(genesisPool != address(0), "ZA");

        bool preLaunchPool = IGenesisPool(genesisPool).depositToken(msg.sender, amount);

        if(preLaunchPool){
            tokenHandler.whitelistToken(IGenesisPool(genesisPool).getGenesisInfo().nativeToken);
            _preLaunchPool(genesisPool);
        }

        emit DespositedToken(genesisPool, msg.sender, amount);
    }


    function _preLaunchPool(address genesisPool) internal {
        address _poolAddress = IGenesisPool(genesisPool).getLiquidityPoolInfo().pairAddress;
        (address _gauge, address _internal_bribe, address _external_bribe) = gaugeManager.createGauge(_poolAddress, 0);

        IGenesisPool(genesisPool).transferIncentives(_gauge, _external_bribe, _internal_bribe);
    }

    function _launchPool(address _nativeToken, address _genesisPool) internal {
        LiquidityPool memory liquidityPool = IGenesisPool(_genesisPool).getLiquidityPoolInfo();
        pairFactory.setGenesisStatus(liquidityPool.pairAddress, false);
        IGauge(liquidityPool.gaugeAddress).setGenesisPool(_genesisPool);
        IGenesisPool(_genesisPool).launch(router, MATURITY_TIME);
        _removeLiveToken(_nativeToken);
    }

    // at epoch flip, PRE_LISTING -> PRE_LAUNCH (condition met) , PRE_LAUNCH_DDEPOSIT_DISBALED -> LAUNCH or PARTIALLY_LAUNCH
    function checkAtEpochFlipOld() external GenesisManager {
        require(epochController == msg.sender, "NA");

        uint256 _proposedTokensCnt = liveNativeTokens.length;
        uint256 i;
        address _genesisPool;
        PoolStatus _poolStatus;
        address nativeToken;

        for(i = _proposedTokensCnt; i > 0; i--){
            nativeToken = liveNativeTokens[i-1];
            _genesisPool = genesisFactory.getGenesisPool(nativeToken);
            _poolStatus = IGenesisPool(_genesisPool).poolStatus();

            if(_poolStatus == PoolStatus.PRE_LISTING && IGenesisPool(_genesisPool).eligbleForPreLaunchPool()){
                tokenHandler.whitelistToken(nativeToken);
                _preLaunchPool(_genesisPool);
            }else if(_poolStatus == PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED){
                _launchPool(nativeToken, _genesisPool);
            }
        }
    }

    // before 3 hrs
    function checkBeforeEpochFlip() external GenesisManager {
        require(epochController == msg.sender, "NA");

        uint _period = pre_epoch_period;
        if (block.timestamp >= _period + WEEK) {

            uint256 _proposedTokensCnt = liveNativeTokens.length;
            uint256 i;
            address _genesisPool;
            PoolStatus _poolStatus;
            address nativeToken;

            for(i = _proposedTokensCnt; i > 0; i--){
                nativeToken = liveNativeTokens[i-1];
                _genesisPool = genesisFactory.getGenesisPool(nativeToken);
                _poolStatus = IGenesisPool(_genesisPool).poolStatus();

                if(_poolStatus == PoolStatus.PRE_LISTING && IGenesisPool(_genesisPool).eligbleForDisqualify()){
                    IGenesisPool(_genesisPool).setPoolStatus(PoolStatus.NOT_QUALIFIED);
                    _removeLiveToken(nativeToken);
                }
                else if(_poolStatus == PoolStatus.PRE_LAUNCH){
                    IGenesisPool(_genesisPool).setPoolStatus(PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED);
                }
            }
            pre_epoch_period = BlackTimeLibrary.currPreEpoch(block.timestamp);
        }
    }

    // at epoch flip, PRE_LISTING -> PRE_LAUNCH (condition met) , PRE_LAUNCH_DDEPOSIT_DISBALED -> LAUNCH or PARTIALLY_LAUNCH
    function checkAtEpochFlip() external EpochManagerOrGenesisManager {
        // require(epochController == msg.sender, "NA");

        uint256 tokensCount = liveNativeTokens.length;

        // If no tokens or all processed, reset index and exit
        if (tokensCount == 0 || epochFlipProcessingIndex >= tokensCount) {
            epochFlipProcessingIndex = 0;
            return;
        }

        // Process one token at current index
        address nativeToken = liveNativeTokens[epochFlipProcessingIndex];
        address _genesisPool = genesisFactory.getGenesisPool(nativeToken);
        PoolStatus _poolStatus = IGenesisPool(_genesisPool).poolStatus();

        if (_poolStatus == PoolStatus.PRE_LISTING && IGenesisPool(_genesisPool).eligbleForPreLaunchPool()) {
            tokenHandler.whitelistToken(nativeToken);
            _preLaunchPool(_genesisPool);
            epochFlipProcessingIndex++;
        } else if (_poolStatus == PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED) {
            _launchPool(nativeToken, _genesisPool);
        } else {
            epochFlipProcessingIndex++;
        }
    }

    function processNextTokenPreEpoch() external EpochManagerOrGenesisManager {
        // require(epochController == msg.sender, "NA");

        uint _period = pre_epoch_period;
        if (block.timestamp < _period + WEEK) {
            return;
        }

        uint256 tokensCount = liveNativeTokens.length;

        // If no tokens or all processed, nothing to do here
        if (tokensCount == 0 || processingIndex >= tokensCount) {
            return;
        }

        // Process current token
        address nativeToken = liveNativeTokens[processingIndex];
        address _genesisPool = genesisFactory.getGenesisPool(nativeToken);
        PoolStatus _poolStatus = IGenesisPool(_genesisPool).poolStatus();

        if (_poolStatus == PoolStatus.PRE_LISTING && _eligibleForDisqualify(_genesisPool)) {
            IGenesisPool(_genesisPool).setPoolStatus(PoolStatus.NOT_QUALIFIED);
            _removeLiveToken(nativeToken);
        } else {
            if (_poolStatus == PoolStatus.PRE_LAUNCH) {
                IGenesisPool(_genesisPool).setPoolStatus(PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED);
            }
            processingIndex++;
        }
    }


    function finalizePreEpochIfReady() external EpochManagerOrGenesisManager {
        // require(epochController == msg.sender, "NA");

        uint _period = pre_epoch_period;
        if (block.timestamp < _period + WEEK) {
            revert("Epoch not ready to finalize");
        }

        if (liveNativeTokens.length == 0 || processingIndex >= liveNativeTokens.length) {
            pre_epoch_period = BlackTimeLibrary.currPreEpoch(block.timestamp);
            processingIndex = 0;
        } else {
            revert("Still processing tokens");
        }
    }


    function _eligibleForDisqualify(address _genesisPool) internal view returns (bool) {
        uint256 _endTime = IGenesisPool(_genesisPool).getGenesisInfo().startTime + IGenesisPool(_genesisPool).getGenesisInfo().duration;
        uint256 targetNativeAmount = (IGenesisPool(_genesisPool).getAllocationInfo().proposedNativeAmount * IGenesisPool(_genesisPool).getGenesisInfo().threshold) / 10000;
        return (_endTime - WEEK <= block.timestamp && IGenesisPool(_genesisPool).getAllocationInfo().allocatedNativeAmount < targetNativeAmount);
    }

    function _removeLiveToken(address nativeToken) internal {
        uint index = liveNativeTokensIndex[nativeToken]; // 1-based index
        uint length = liveNativeTokens.length;

        if (length > 0 && index >= 1 && index <= length) {
            uint arrayIndex = index - 1;
            address lastToken = liveNativeTokens[length - 1];

            // Replace the token to remove with the last token
            liveNativeTokens[arrayIndex] = lastToken;
            liveNativeTokens.pop();

            // Update index for the moved token (if not the same)
            if (nativeToken != lastToken) {
                liveNativeTokensIndex[lastToken] = index;
            }

            // Remove index mapping for removed token
            delete liveNativeTokensIndex[nativeToken];
        }
    }

    function setAuction(address _genesisPool, address _auction) external Governance {
        require(_genesisPool != address(0), "ZA");
        IGenesisPool(_genesisPool).setAuction(_auction);
    }

    function getAllNaitveTokens() external view returns (address[] memory) {
        return nativeTokens;
    }

    function getLiveNaitveTokens() external view returns (address[] memory) {
        return liveNativeTokens;
    }

    function setEpochController(address _epochController) external Governance {
        require(_epochController != address(0), "ZA");
        epochController = _epochController;
    }

    function setMinimumDuration(uint256 _duration) external Governance {
        MIN_DURATION = _duration;
    }

    function setMinimumThreshold(uint256 _threshold) external Governance {
        MIN_THRESHOLD = _threshold;
    }

    function setMaturityTime(uint256 _maturityTime) external Governance {
        MATURITY_TIME = _maturityTime;
    }

    function setMaturityTime(address _nativeToken, uint256 _maturityTime) external Governance {
        require(_nativeToken != address(0), "ZA");
        address genesisPool = genesisFactory.getGenesisPool(_nativeToken);
        require(genesisPool != address(0), "ZA");
        IGenesisPool(genesisPool).setMaturityTime(_maturityTime);
    }

    function setGenesisStartTime(address _nativeToken, uint256 _startTime) external Governance {
        require(_nativeToken != address(0), "ZA");
        address genesisPool = genesisFactory.getGenesisPool(_nativeToken);
        require(genesisPool != address(0), "ZA");
        IGenesisPool(genesisPool).setStartTime(_startTime);
    }

    function setRouter (address _router) external onlyOwner {
        require(_router != address(0), "ZA");
        router = _router;
    }

    function updateGenesisPoolStatus(address nativeToken, PoolStatus poolStatus) external GenesisManager {
        address _genesisPool = genesisFactory.getGenesisPool(nativeToken);
        require(_genesisPool != address(0), "ZA");
        IGenesisPool(_genesisPool).setPoolStatus(poolStatus);
        if (poolStatus == PoolStatus.NOT_QUALIFIED) {
            _removeLiveToken(nativeToken);
        }
        if (poolStatus == PoolStatus.PRE_LAUNCH_DEPOSIT_DISABLED) {
            tokenHandler.whitelistToken(nativeToken);
            _preLaunchPool(_genesisPool);
        }
        if (poolStatus == PoolStatus.LAUNCH) {
            _launchPool(nativeToken, _genesisPool);
        }
    }

    function version() external pure returns (string memory) {
        return "1.5.6";
    }
}