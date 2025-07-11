// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import '../interfaces/IPairFactory.sol';
import '../interfaces/IPair.sol';
import '../interfaces/IPairGenerator.sol';

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract PairFactory is IPairFactory, OwnableUpgradeable {

    bool public isPaused;

    uint256 public stableFee;
    uint256 public volatileFee;
    uint256 public stakingNFTFee;
    uint256 public MAX_REFERRAL_FEE; // 12%
    uint256 public constant MAX_FEE = 500; // 5%

    address public feeManager;
    address public pendingFeeManager;
    address public dibs; // referral fee handler
    address public stakingFeeHandler; // staking fee handler
    address public pairGenerator;
    address public genesisManager;

    mapping(address => mapping(address => mapping(bool => address))) public getPair;
    address[] public allPairs;
    mapping(address => bool) public isPair;
    mapping(address => uint256) public customFees;
    mapping(address => uint256) public customReferralFees;
    mapping(address => bool) public isGenesis;

    event PairCreated(address indexed token0, address indexed token1, bool stable, address pair, uint);

    modifier onlyManager() {
        require(msg.sender == feeManager, "NA");
        _;
    }

    mapping(address => bool) public authorizedAccounts;
    modifier onlyAuthorized() {
        require(
            authorizedAccounts[msg.sender] || msg.sender == feeManager || msg.sender == genesisManager,
            "not manager or authorized"
        );
        _;
    }
    event AuthorizedAccountAdded(address indexed account);
    event AuthorizedAccountRemoved(address indexed account);
    constructor() {}

    function initialize(address _pairGenerator) public initializer {
        __Ownable_init();
        isPaused = false;
        feeManager = msg.sender;
        stableFee = 5; // 0.05%
        volatileFee = 60; // 0.6%
        stakingNFTFee = 0; // 0% of stable/volatileFee, we can change it later if needed
        MAX_REFERRAL_FEE = 0; // 0%
        pairGenerator = _pairGenerator;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function setPause(bool _state) external {
        require(msg.sender == owner(), "NA");
        isPaused = _state;
    }

    function setFeeManager(address _feeManager) external onlyManager {
        pendingFeeManager = _feeManager;
    }

    function acceptFeeManager() external {
        require(msg.sender == pendingFeeManager, "NA");
        feeManager = pendingFeeManager;
    }

    function setStakingFees(uint256 _newFee) external onlyManager {
        require(_newFee <= 3000, "HFE");
        stakingNFTFee = _newFee;
    }

    function setStakingFeeAddress(address _feehandler) external onlyManager {
        require(_feehandler != address(0), "ZA");
        stakingFeeHandler = _feehandler;
    }

    function setDibs(address _dibs) external onlyManager {
        require(_dibs != address(0), "ZA");
        dibs = _dibs;
    }

    function setReferralFee(uint256 _refFee) external onlyManager {
        MAX_REFERRAL_FEE = _refFee;
    }

    function setFee(bool _stable, uint256 _fee) external onlyManager {
        require(_fee <= MAX_FEE, "HFE");
        require(_fee != 0, "ZFE");
        if (_stable) {
            stableFee = _fee;
        } else {
            volatileFee = _fee;
        }
    }

    function setCustomFees(address _pairAddress, uint256 _fees) external onlyManager {
        require(_fees <= MAX_FEE, "HFE");
        require(isPair[_pairAddress], "INVP");
        customFees[_pairAddress] = _fees;
    }

    function setCustomReferralFee(address _pairAddress, uint256 _refFee) external onlyManager {
        require(isPair[_pairAddress], "INVP");
        customReferralFees[_pairAddress] = _refFee;
    }

    function getFee(address _pairAddress, bool _stable) public view returns (uint256) {
        if (customFees[_pairAddress] > 0) {
            return customFees[_pairAddress];
        }
        return _stable ? stableFee : volatileFee;
    }

    function getReferralFee(address _pairAddress) public view returns (uint256) {
        if (customReferralFees[_pairAddress] > 0) {
            return customReferralFees[_pairAddress];
        }
        return MAX_REFERRAL_FEE;
    }

    function getIsGenesis(address _pairAddress) public view returns (bool) {
        return isGenesis[_pairAddress];
    }

    function setIsGenesis(address _pairAddress, bool status) external onlyManager {
        require(_pairAddress != address(0) && isPair[_pairAddress], "INVP");
        isGenesis[_pairAddress] = status;
    }

    function pairCodeHash() external view returns (bytes32) {
        return IPairGenerator(pairGenerator).pairCodeHash();
    }

    function createPair(address tokenA, address tokenB, bool stable) external onlyAuthorized returns (address pair) {
        require(tokenA != tokenB, "IA"); // Pair: IDENTICAL_ADDRESSES
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZA"); // Pair: ZERO_ADDRESS
        require(getPair[token0][token1][stable] == address(0), "!ZA");
        pair = IPairGenerator(pairGenerator).createPair(token0, token1, stable);
        getPair[tokenA][tokenB][stable] = pair;
        getPair[tokenB][tokenA][stable] = pair; // Store in reverse direction
        allPairs.push(pair);
        isPair[pair] = true;

        emit PairCreated(token0, token1, stable, pair, allPairs.length);
    }

    function setGenesisManager(address _genesisManager) external onlyManager {
        genesisManager = _genesisManager;
    }

    function setGenesisStatus(address _pair, bool status) external {
        require(msg.sender == genesisManager || msg.sender == feeManager, "NA");
        isGenesis[_pair] = status;
    }

    function addAuthorizedAccount(address account) external onlyManager {
        require(account != address(0), "zero address");
        require(!authorizedAccounts[account], "already authorized");
        authorizedAccounts[account] = true;
        emit AuthorizedAccountAdded(account);
    }

    function removeAuthorizedAccount(address account) external onlyManager {
        require(account != address(0), "zero address");
        require(authorizedAccounts[account], "!authorized");
        authorizedAccounts[account] = false;
        emit AuthorizedAccountRemoved(account);
    }

    function version() external pure returns (string memory) {
        return "PairFactory v1.2.2";
    }
}