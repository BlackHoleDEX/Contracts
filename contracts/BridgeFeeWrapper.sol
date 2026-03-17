// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


// Interface for LayerZero bridge contract
interface ILayerZeroBridge {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt);

    function quoteSend(
        SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (MessagingFee memory msgFee);

    /**
     * @notice Whether this OFT/bridge implementation requires ERC20 approvals
     * @dev For OFT tokens that burn on send, this typically returns false.
     */
    function approvalRequired() external view returns (bool);
}

/**
 * @title BridgeFeeWrapper
 * @notice Generic wrapper contract that sits before LayerZero bridging and collects a fee
 * @dev Can handle multiple tokens on the same chain. Users approve tokens to this contract.
 *      Bridge addresses are passed as parameters - no registration required.
 */
contract BridgeFeeWrapper is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // Custom errors
    error InvalidAddress(address addr);
    error FeeTooHigh(uint256 fee, uint256 maxFee);
    error InvalidTokenAddress();
    error InvalidBridgeAddress();
    error BridgedAmountZero();
    error MinAmountExceedsBridgedAmount(uint256 minAmountLD, uint256 bridgedAmount);
    
    // Mapping: token address -> fee basis points (0 means use default)
    mapping(address => uint256) public tokenFeeBasisPoints;
    
    // Default fee recipient address (where collected fees go)
    address public feeRecipient;
    
    // Default fee basis points (1 basis point = 0.01%, so 100 = 1%)
    // e.g., 50 = 0.5%, 100 = 1%, 1000 = 10%
    uint256 public defaultFeeBasisPoints;
    
    // Maximum fee basis points (safety limit, e.g., 1000 = 10%)
    uint256 public constant MAX_FEE_BASIS_POINTS = 1000;
    
    // Events
    event TokenFeeUpdated(address indexed token, uint256 oldFee, uint256 newFee);
    event FeeCollected(address indexed token, uint256 amount, address indexed recipient);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DefaultFeeBasisPointsUpdated(uint256 oldFee, uint256 newFee);
    event BridgeExecuted(
        address indexed user,
        address indexed token,
        address indexed bridge,
        uint256 originalAmount,
        uint256 feeAmount,
        uint256 bridgedAmount
    );
    event DustRefunded(address indexed user, address indexed token, uint256 amount);

    /**
     * @param _feeRecipient The address that will receive collected fees
     * @param _defaultFeeBasisPoints The default fee in basis points (e.g., 50 = 0.5%)
     */
    constructor(
        address _feeRecipient,
        uint256 _defaultFeeBasisPoints
    ){
        if (_feeRecipient == address(0)) revert InvalidAddress(_feeRecipient);
        if (_defaultFeeBasisPoints > MAX_FEE_BASIS_POINTS) revert FeeTooHigh(_defaultFeeBasisPoints, MAX_FEE_BASIS_POINTS);
        
        feeRecipient = _feeRecipient;
        defaultFeeBasisPoints = _defaultFeeBasisPoints;
    }

    /**
     * @notice Set custom fee basis points for a specific token (0 to use default)
     * @param _token The token contract address
     * @param _feeBasisPoints The fee in basis points (0 to use default)
     */
    function setTokenFeeBasisPoints(address _token, uint256 _feeBasisPoints) external onlyOwner {
        if (_feeBasisPoints > MAX_FEE_BASIS_POINTS) revert FeeTooHigh(_feeBasisPoints, MAX_FEE_BASIS_POINTS);
        uint256 oldFee = tokenFeeBasisPoints[_token];
        tokenFeeBasisPoints[_token] = _feeBasisPoints;
        emit TokenFeeUpdated(_token, oldFee, _feeBasisPoints);
    }

    /**
     * @notice Get the fee basis points for a token (returns default if not set)
     * @param _token The token contract address
     * @return The fee basis points for this token
     */
    function getFeeBasisPoints(address _token) public view returns (uint256) {
        uint256 tokenFee = tokenFeeBasisPoints[_token];
        return tokenFee > 0 ? tokenFee : defaultFeeBasisPoints;
    }

    /**
     * @notice Calculate the fee amount for a given token and amount
     * @param _token The token contract address
     * @param amount The input amount
     * @return feeAmount The fee amount to be collected
     * @return bridgedAmount The amount that will be bridged (after fee)
     */
    function calculateFee(address _token, uint256 amount) public view returns (uint256 feeAmount, uint256 bridgedAmount) {
        uint256 feeBps = getFeeBasisPoints(_token);
        feeAmount = (amount * feeBps) / 10000;
        bridgedAmount = amount - feeAmount;
    }

    /**
     * @notice Wrapper for the bridge contract's send function
     * @param _token The ERC20 token contract address (for transfers)
     * @param _bridgeContract The LayerZero bridge contract address for this token
     * @param _sendParam The send parameters (same as bridge contract)
     * @param _fee The messaging fee (same as bridge contract)
     * @param _refundAddress The refund address (same as bridge contract)
     * @return msgReceipt The messaging receipt from the bridge
     * @return oftReceipt The OFT receipt from the bridge
     * 
     * @dev Works with both OFT tokens and OFT adapters:
     *      - OFT Token: _token == _bridgeContract (token is the bridge)
     *      - OFT Adapter: _token != _bridgeContract (adapter wraps the token)
     *      For shared-decimals OFTs the bridge may debit less than the requested amount
     *      (rounded down). Any such dust is refunded to the caller and no longer accumulates
     *      in the wrapper.
     */
    function send(
        address _token,
        address _bridgeContract,
        ILayerZeroBridge.SendParam calldata _sendParam,
        ILayerZeroBridge.MessagingFee calldata _fee,
        address _refundAddress
    ) external payable nonReentrant returns (ILayerZeroBridge.MessagingReceipt memory msgReceipt, ILayerZeroBridge.OFTReceipt memory oftReceipt) {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_bridgeContract == address(0)) revert InvalidBridgeAddress();
        
        ILayerZeroBridge bridgeContract = ILayerZeroBridge(_bridgeContract);
        uint256 originalAmount = _sendParam.amountLD;
        
        // Calculate fee
        (uint256 feeAmount, uint256 bridgedAmount) = calculateFee(_token, originalAmount);
        
        // Transfer fee to fee recipient (using ERC20 token address)
        if (feeAmount > 0) {
            IERC20(_token).safeTransferFrom(msg.sender, feeRecipient, feeAmount);
            emit FeeCollected(_token, feeAmount, feeRecipient);
        }
        
        // Transfer remaining amount to this contract
        // For OFT tokens: _bridgeContract == _token (token burns on send, no approval needed)
        // For OFT adapters: _bridgeContract != _token (adapter pulls tokens via transferFrom)
        if (bridgedAmount == 0) revert BridgedAmountZero();
        IERC20(_token).safeTransferFrom(msg.sender, address(this), bridgedAmount);
        // Only approve if the bridge implementation requires approvals
        if (bridgeContract.approvalRequired()) {
            IERC20(_token).forceApprove(_bridgeContract, bridgedAmount);
        }
        
        // Update send param with reduced amount
        ILayerZeroBridge.SendParam memory adjustedSendParam = _sendParam;
        adjustedSendParam.amountLD = bridgedAmount;
        // Ensure user-provided minAmountLD can still be satisfied after fees
        if (adjustedSendParam.minAmountLD > bridgedAmount) {
            revert MinAmountExceedsBridgedAmount(adjustedSendParam.minAmountLD, bridgedAmount);
        }
        
        // Call the actual bridge contract's send function
        (msgReceipt, oftReceipt) = bridgeContract.send{value: msg.value}(
            adjustedSendParam,
            _fee,
            _refundAddress
        );

        // Refund shared-decimals dust: bridge may debit less than bridgedAmount (rounded down
        // to decimalConversionRate). Return the remainder to the user so it does not accumulate
        // in the wrapper or become sweepable by the owner.
        {
            if (bridgedAmount > oftReceipt.amountSentLD) {
                uint256 dust = bridgedAmount - oftReceipt.amountSentLD;
                IERC20(_token).safeTransfer(msg.sender, dust);
                emit DustRefunded(msg.sender, _token, dust);
            }
        }

        // Reset approval if it was set
        if (bridgeContract.approvalRequired()) {
            IERC20(_token).forceApprove(_bridgeContract, 0);
        }
        
        emit BridgeExecuted(
            msg.sender,
            _token,
            _bridgeContract,
            originalAmount,
            feeAmount,
            bridgedAmount
        );
        
        return (msgReceipt, oftReceipt);
    }

    /**
     * @notice Wrapper for the bridge contract's quoteSend function
     * @param _token The token contract address
     * @param _bridgeContract The LayerZero bridge contract address for this token
     * @param _sendParam The send parameters
     * @param _payInLzToken Whether to pay in LZ token
     * @return msgFee The messaging fee (same as bridge contract)
     */
    function quoteSend(
        address _token,
        address _bridgeContract,
        ILayerZeroBridge.SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (ILayerZeroBridge.MessagingFee memory msgFee) {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_bridgeContract == address(0)) revert InvalidBridgeAddress();
        
        ILayerZeroBridge bridgeContract = ILayerZeroBridge(_bridgeContract);
        
        // We need to quote with the adjusted amount (after fee)
        (, uint256 bridgedAmount) = calculateFee(_token, _sendParam.amountLD);
        
        ILayerZeroBridge.SendParam memory adjustedSendParam = _sendParam;
        adjustedSendParam.amountLD = bridgedAmount;
        // Ensure user-provided minAmountLD can still be satisfied after fees
        if (adjustedSendParam.minAmountLD > bridgedAmount) {
            revert MinAmountExceedsBridgedAmount(adjustedSendParam.minAmountLD, bridgedAmount);
        }
        
        // Call the bridge contract's quoteSend
        msgFee = bridgeContract.quoteSend(adjustedSendParam, _payInLzToken);
        return msgFee;
    }

    /**
     * @notice Update the default fee recipient address
     * @param _newFeeRecipient The new fee recipient address
     */
    function setFeeRecipient(address _newFeeRecipient) external onlyOwner {
        if (_newFeeRecipient == address(0)) revert InvalidAddress(_newFeeRecipient);
        address oldRecipient = feeRecipient;
        feeRecipient = _newFeeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _newFeeRecipient);
    }

    /**
     * @notice Update the default fee basis points
     * @param _newFeeBasisPoints The new default fee in basis points
     */
    function setDefaultFeeBasisPoints(uint256 _newFeeBasisPoints) external onlyOwner {
        if (_newFeeBasisPoints > MAX_FEE_BASIS_POINTS) revert FeeTooHigh(_newFeeBasisPoints, MAX_FEE_BASIS_POINTS);
        uint256 oldFee = defaultFeeBasisPoints;
        defaultFeeBasisPoints = _newFeeBasisPoints;
        emit DefaultFeeBasisPointsUpdated(oldFee, _newFeeBasisPoints);
    }

    /**
     * @notice Emergency function to recover tokens sent to this contract
     * @param _token The token address to recover
     * @param _amount The amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}

