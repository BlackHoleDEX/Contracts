// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./interfaces/IZapRouterHelper.sol";
import {Zap} from "./libraries/zap.sol";

import "./interfaces/IWETH.sol";
import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRouter.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraFactory.sol";
import "./interfaces/IGaugeManager.sol";
import "./interfaces/IGaugeCL.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./libraries/Errors.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract RouterHelperZap is IZapRouterHelper, ReentrancyGuard {
    using Zap for Zap.Swap[];
    using SafeERC20 for IERC20;

    IWETH public immutable wETH;
    INonfungiblePositionManager public immutable nfpm;
    IRouter public immutable router;
    IAlgebraFactory public immutable algebraFactory;
    IGaugeManager public immutable gaugeManager;

    // Single storage slots for callback results (safe because callbacks are synchronous and nonReentrant)
    struct CallbackResult {
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;
    }
    CallbackResult private _callbackResult;

    struct MintCallbackResult {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }
    MintCallbackResult private _mintCallbackResult;

    struct RemoveCallbackResult {
        uint256 amountOut;
    }
    RemoveCallbackResult private _removeCallbackResult;

    event ZapAndAddLiquidity(
        address indexed user,
        address indexed tokenA,
        address indexed tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    event ZapAndMintCL(
        address indexed user,
        address indexed token0,
        address indexed token1,
        address deployer,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event ZapAndIncreaseLiquidity(
        address indexed user,
        uint256 indexed tokenId,
        address token0,
        address token1,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event StakeStatus(address indexed user, uint256 indexed tokenId, address indexed pool, address gauge, bool staked);

    event ZapToSingleToken(
        address indexed user,
        address indexed outputToken,
        address indexed to,
        uint256 amountOut,
        bool unwrapWETH
    );

    modifier onlyRouter() {
        if (msg.sender != address(router)) revert NOT_AUTHORIZED();
        _;
    }

    constructor(
        address _router,
        address _nfpm,
        address _algebraFactory,
        address _gaugeManager
    ) {
        router = IRouter(_router);
        wETH = IWETH(router.wETH());
        nfpm = INonfungiblePositionManager(_nfpm);
        algebraFactory = IAlgebraFactory(_algebraFactory);
        gaugeManager = IGaugeManager(_gaugeManager);
    }

    receive() external payable {
        assert(msg.sender == address(wETH)); // only accept ETH via fallback from the WETH contract; forced ETH transfers are still possible.
    }

    function _validateFinalTokens(
        Zap.Swap[] calldata swaps,
        address tokenA,
        address tokenB
    ) internal pure {
        for (uint256 i = 0; i < swaps.length; i++) {
            if (swaps[i].routes.length == 0) revert ER();
            address finalToken = swaps[i].routes[swaps[i].routes.length - 1].to;
            if (finalToken != tokenA && finalToken != tokenB) revert IIT(finalToken);
        }
    }

    function _adjustSwapAmounts(
        Zap.Swap[] calldata swaps,
        address[] calldata inputTokens,
        address outputToken
    ) internal view returns (Zap.Swap[] memory adjustedSwaps) {

        uint256[] memory amounts = new uint256[](inputTokens.length);
        bool[] memory needsSwap = new bool[](inputTokens.length);
        bool[] memory hasSwap = new bool[](inputTokens.length);
        for (uint256 i = 0; i < inputTokens.length; i++) {
            amounts[i] = IERC20(inputTokens[i]).balanceOf(address(this));
            needsSwap[i] = amounts[i] > 0 && inputTokens[i] != outputToken;
            hasSwap[i] = !needsSwap[i];
        }

        adjustedSwaps = new Zap.Swap[](swaps.length);
        for (uint256 i = 0; i < swaps.length; i++) {
            adjustedSwaps[i] = swaps[i];
            if (swaps[i].routes.length == 0) revert ER();

            address from = swaps[i].routes[0].from;
            uint256 tokenIndex = _indexOf(inputTokens, from);
            if (!needsSwap[tokenIndex]) {
                adjustedSwaps[i].amountIn = 0;
            }
            hasSwap[tokenIndex] = true;
        }

        // Group swaps by input token and calculate proportional amounts
        for (uint256 i = 0; i < inputTokens.length; i++) {
            if (!needsSwap[i]) continue;

            _distributeForInputToken(
                swaps,
                inputTokens[i],
                amounts[i],
                adjustedSwaps
            );
        }

        for (uint256 i = 0; i < inputTokens.length; i++) {
            if (!hasSwap[i]) revert MSFT(inputTokens[i]);
        }
    }

    function _distributeForInputToken(
        Zap.Swap[] calldata swaps,
        address inputToken,
        uint256 balance,
        Zap.Swap[] memory adjustedSwaps
    ) internal pure {
        // Calculate total amountIn needed for this input token across all swaps
        uint256 totalNeeded = 0;
        for (uint256 j = 0; j < swaps.length; j++) {
            if (swaps[j].routes.length > 0 && swaps[j].routes[0].from == inputToken) {
                totalNeeded += swaps[j].amountIn;
            }
        }

        // If no amountIn specified, treat as invalid configuration
        if (totalNeeded == 0) {
            revert ZA();
        }
        // proportionally adjust all swaps using this token to the balance of the input token
        uint256 reminder = balance;
        uint256 lastIdx = type(uint256).max;
        // First, store the index of the last swap for this inputToken
        for (uint256 j = 0; j < swaps.length; j++) {
            if (swaps[j].routes.length > 0 && swaps[j].routes[0].from == inputToken) {
                lastIdx = j;
            }
        }
        for (uint256 j = 0; j < swaps.length; j++) {
            if (swaps[j].routes.length > 0 && swaps[j].routes[0].from == inputToken) {
                if (j != lastIdx) {
                    uint256 amt = Math.mulDiv(swaps[j].amountIn, balance, totalNeeded);
                    adjustedSwaps[j].amountIn = amt;
                    reminder = reminder - amt;
                } else {
                    // Last one: add all remaining (to handle rounding error)
                    adjustedSwaps[j].amountIn = reminder;
                }
            }
        }
    }

    /**
     * @dev Adjusts swap amounts based on actual token balances (handles FOT tokens)
     * This handles two scenarios:
     * 1. If balance >= total needed: use specified amounts, remaining goes to liquidity
     * 2. If balance < total needed: proportionally reduce all swaps using same input token
     * @param swaps Array of swaps to adjust
     * @return adjustedSwaps Adjusted swaps with corrected amountIn values
     */
    function _adjustSwapAmountsForBalance(
        Zap.Swap[] calldata swaps
    ) internal view returns (Zap.Swap[] memory adjustedSwaps) {
        adjustedSwaps = new Zap.Swap[](swaps.length);
        
        // Group swaps by input token to handle proportional splitting
        for (uint256 i = 0; i < swaps.length; i++) {
            adjustedSwaps[i] = swaps[i];
            if (swaps[i].routes.length == 0) revert ER();
            
            address inputToken = swaps[i].routes[0].from;
            uint256 actualBalance = IERC20(inputToken).balanceOf(address(this));
            
            // Calculate total amountIn needed for this input token across all swaps
            uint256 totalNeeded = 0;
            for (uint256 j = 0; j < swaps.length; j++) {
                if (swaps[j].routes.length > 0 && swaps[j].routes[0].from == inputToken) {
                    totalNeeded += swaps[j].amountIn;
                }
            }
            
            // If we have enough balance, use specified amounts (remaining goes to liquidity)
            if (actualBalance >= totalNeeded) {
                // Keep original amountIn - no adjustment needed
                continue;
            }
            
            // If we don't have enough, proportionally reduce
            // This handles FOT tokens where balance < totalNeeded
            if (totalNeeded > 0) {
                adjustedSwaps[i].amountIn = (swaps[i].amountIn * actualBalance) / totalNeeded;
            }
        }
    }

    function _indexOf(address[] memory arr, address t) internal pure returns (uint256) {
        uint256 l = arr.length;
        for (uint256 i = 0; i < l; i++) {
            if (arr[i] == t) return i;
        }
        revert ISTK(t);
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _safeTransferETH(address to, uint value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        if (!success) revert ETF(value);
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
                abi.encodeCall(IERC20.transfer, (to, value))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert IST();
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.transferFrom, (from, to, value))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert ISTF();
    }

    function _refundLeftovers(address[] memory tokens, address to) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) {
                _safeTransfer(token, to, bal);
            }
        }
    }

    // ===== Add Liquidity =====
    function zapAndAddLiquidity(
        IZapRouterHelper.ZapAddParams calldata p
    ) external override onlyRouter nonReentrant returns (uint256, uint256, uint256) {
        if (p.swaps.length == 0) revert NS();
        // Validate final tokens
        _validateFinalTokens(p.swaps, p.tokenA, p.tokenB);

        _executeZapAdd(
            p.tokenA,
            p.tokenB,
            p.stable,
            p.amountAMin,
            p.amountBMin,
            p.deadline,
            p.to,
            p.swaps
        );

        // Read results populated by the callback
        uint256 amountA_ = _callbackResult.amountA;
        uint256 amountB_ = _callbackResult.amountB;
        uint256 liquidity_ = _callbackResult.liquidity;

        emit ZapAndAddLiquidity(
            msg.sender,
            p.tokenA,
            p.tokenB,
            p.stable,
            amountA_,
            amountB_,
            liquidity_
        );

        _refundLeftovers(p.inputTokens, p.to);

        return (amountA_, amountB_, liquidity_);
    }

    function _executeZapAdd(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountAMin,
        uint amountBMin,
        uint256 deadline,
        address to,
        Zap.Swap[] calldata swaps
    ) internal {
        // Adjust swap amounts based on actual balances (handles FOT tokens)
        Zap.Swap[] memory adjustedSwaps = _adjustSwapAmountsForBalance(swaps);

        bytes memory data = abi.encodeCall(
            this.zapAddLiquidityCallback,
            (tokenA, tokenB, stable, amountAMin, amountBMin, to, deadline)
        );
        address[] memory outputTokens = _pair(tokenA, tokenB);
        Zap.execute(address(router), adjustedSwaps, outputTokens, deadline, data, to);
    }

    function zapAddLiquidityCallback(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external {
        if (msg.sender != address(this)) revert CC();

        (
            uint256 amountA_,
            uint256 amountB_,
            uint256 liquidity_
        ) = _addLiquidityForZap(
                tokenA,
                tokenB,
                stable,
                amountAMin,
                amountBMin,
                to,
                deadline
            );

        _callbackResult = CallbackResult({
            amountA: amountA_,
            amountB: amountB_,
            liquidity: liquidity_
        });
    }

    function _addLiquidityForZap(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) internal returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        uint256 amountADesired = IERC20(tokenA).balanceOf(address(this));
        if (amountADesired < amountAMin) revert IB(amountAMin, amountADesired);
        uint256 amountBDesired = IERC20(tokenB).balanceOf(address(this));
        if (amountBDesired < amountBMin) revert IB(amountBMin, amountBDesired);
        // Approve router to spend our tokens
        IERC20(tokenA).forceApprove(address(router), amountADesired);
        IERC20(tokenB).forceApprove(address(router), amountBDesired);

        // Call router's addLiquidity directly
        (amountA, amountB, liquidity) = router.addLiquidity(
            tokenA,
            tokenB,
            stable,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
    }

    function zapRemoveLiquidityCallback(
        address outputToken,
        uint256 minAmountOut,
        bool unwrapWETH,
        address to
    ) external {
        if (msg.sender != address(this)) revert CC();

        uint256 amountOut = IERC20(outputToken).balanceOf(address(this));
        if (amountOut < minAmountOut) revert IOA(minAmountOut, amountOut);
        if (outputToken == address(wETH) && unwrapWETH) {
            wETH.withdraw(amountOut);
            _safeTransferETH(to, amountOut);
        } else {
            _safeTransfer(outputToken, to, amountOut);
        }

        _removeCallbackResult = RemoveCallbackResult({
            amountOut: amountOut
        });
    }

    // ===== Mint CL Position =====
    function zapAndMintCL(
        IZapRouterHelper.ZapMintCLParams calldata p
    )
        external
        override
        onlyRouter
        nonReentrant
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        return _zapAndMintCL(p, p.recipient);
    }

    function _zapAndMintCL(
        IZapRouterHelper.ZapMintCLParams calldata p,
        address dustRecipient
    )
        internal
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        if (address(nfpm) == address(0)) revert NNS();
        if (p.swaps.length == 0) revert NS();

        // Validate final tokens
        _validateFinalTokens(p.swaps, p.token0, p.token1);

        // Execute swaps and mint via callback
        _executeZapMintCL(p, dustRecipient);
        tokenId = _mintCallbackResult.tokenId;
        liquidity = _mintCallbackResult.liquidity;
        amount0 = _mintCallbackResult.amount0;
        amount1 = _mintCallbackResult.amount1;

        _refundLeftovers(p.inputTokens, dustRecipient);

        emit ZapAndMintCL(
            msg.sender,
            p.token0,
            p.token1,
            p.deployer,
            p.tickLower,
            p.tickUpper,
            tokenId,
            liquidity,
            amount0,
            amount1
        );
    }

    function _executeZapMintCL(
        IZapRouterHelper.ZapMintCLParams calldata p,
        address dustRecipient
    ) internal {
        // Adjust swap amounts based on actual balances (handles FOT tokens)
        Zap.Swap[] memory adjustedSwaps = _adjustSwapAmountsForBalance(p.swaps);

        address[] memory outputs = _pair(p.token0, p.token1);
        Zap.execute(
            address(router),
            adjustedSwaps,
            outputs,
            p.deadline,
            abi.encodeCall(
                this.zapMintCLCallback,
                (INonfungiblePositionManager.MintParams({
                    token0: p.token0,
                    token1: p.token1,
                    deployer: p.deployer,
                    tickLower: p.tickLower,
                    tickUpper: p.tickUpper,
                    amount0Desired: 0,
                    amount1Desired: 0,
                    amount0Min: p.amount0Min,
                    amount1Min: p.amount1Min,
                    recipient: p.recipient,
                    deadline: p.deadline
                }))
            ),
            dustRecipient
        );
    }

    struct MintReturn {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }
    function _mintCLForZap(
        INonfungiblePositionManager.MintParams memory m
    ) internal returns (MintReturn memory r) {
        r= MintReturn({
            tokenId: 0,
            liquidity: 0,
            amount0: 0,
            amount1: 0
        });
        m.amount0Desired = IERC20(m.token0).balanceOf(address(this));
        if (m.amount0Desired < m.amount0Min) revert IB(m.amount0Min, m.amount0Desired);
        m.amount1Desired = IERC20(m.token1).balanceOf(address(this));
        if (m.amount1Desired < m.amount1Min) revert IB(m.amount1Min, m.amount1Desired);
        IERC20(m.token0).forceApprove(address(nfpm), m.amount0Desired);
        IERC20(m.token1).forceApprove(address(nfpm), m.amount1Desired);
        (r.tokenId, r.liquidity, r.amount0, r.amount1) = nfpm.mint(m);
        //revoke approval
        IERC20(m.token0).forceApprove(address(nfpm), 0);
        IERC20(m.token1).forceApprove(address(nfpm), 0);
    }

    function zapMintCLCallback(
        INonfungiblePositionManager.MintParams memory m
    ) external {
        if (msg.sender != address(this)) revert CC();
        MintReturn memory mr = _mintCLForZap(m);
        _mintCallbackResult = MintCallbackResult({
            tokenId: mr.tokenId,
            liquidity: mr.liquidity,
            amount0: mr.amount0,
            amount1: mr.amount1
        });
    }

    /**
     * @dev Unified external function to swap tokens to a single output token
     */
    function zapToSingleToken(
        IZapRouterHelper.ZapToSingleTokenParams calldata p
    ) external override onlyRouter nonReentrant returns (uint256 amountOut) {
        if (p.swaps.length == 0) revert NS();
        _validateFinalTokens(p.swaps, p.outputToken, p.outputToken);
        amountOut = _zapToSingleToken(
            p.inputTokens,
            p.swaps,
            p.outputToken,
            p.minAmountOut,
            p.unwrapWETH,
            p.deadline,
            p.to
        );
        emit ZapToSingleToken(
            msg.sender,
            p.outputToken,
            p.to,
            amountOut,
            p.unwrapWETH
        );
    }

    /**
     * @dev Internal function to swap two tokens to a single output token
     * @param inputTokens Input tokens
     * @param swaps Swap routes
     * @param outputToken Target output token
     * @param minAmountOut Minimum output amount
     * @param unwrapWETH Whether to unwrap WETH to ETH
     * @param deadline Transaction deadline
     * @param to Recipient address
     * @return amountOut Amount of output token received
     */
    function _zapToSingleToken(
        address[] calldata inputTokens,
        Zap.Swap[] calldata swaps,
        address outputToken,
        uint256 minAmountOut,
        bool unwrapWETH,
        uint256 deadline,
        address to
    ) internal returns (uint256 amountOut) {
        // Adjust swaps with current balances
        Zap.Swap[] memory adjustedSwaps = _adjustSwapAmounts(
            swaps,
            inputTokens,
            outputToken
        );

        // Execute swaps via callback
        bytes memory data = abi.encodeCall(
            this.zapRemoveLiquidityCallback,
            (outputToken, minAmountOut, unwrapWETH, to)
        );
        Zap.execute(
            address(router),
            adjustedSwaps,
            _single(outputToken),
            deadline,
            data,
            to
        );

        amountOut = _removeCallbackResult.amountOut;
    }

    // ===== Increase Liquidity for CL =====
    function zapAndIncreaseLiquidity(
        IZapRouterHelper.ZapIncreaseLiquidityParams calldata p
    )
        external
        override
        onlyRouter
        nonReentrant
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (address(nfpm) == address(0)) revert NNS();
        if (p.swaps.length == 0) revert NS();
        {
            (, , address token0, address token1, , , , , , , , ) = nfpm
                .positions(p.tokenId);
            if (token0 != p.token0 || token1 != p.token1) revert IT(p.token0, token0, p.token1, token1);
        }
        _validateFinalTokens(p.swaps, p.token0, p.token1);
        address nftOwner = nfpm.ownerOf(p.tokenId);
        _executeZapIncreaseLiquidity(p);
        liquidity = _mintCallbackResult.liquidity;
        amount0 = _mintCallbackResult.amount0;
        amount1 = _mintCallbackResult.amount1;
        _refundLeftovers(p.inputTokens, nftOwner);

        emit ZapAndIncreaseLiquidity(
            msg.sender,
            p.tokenId,
            p.token0,
            p.token1,
            liquidity,
            amount0,
            amount1
        );
    }

    function _executeZapIncreaseLiquidity(
        IZapRouterHelper.ZapIncreaseLiquidityParams calldata p
    ) internal {
        // Adjust swap amounts based on actual balances (handles FOT tokens)
        Zap.Swap[] memory adjustedSwaps = _adjustSwapAmountsForBalance(p.swaps);

        address[] memory outputs = _pair(p.token0, p.token1);
        Zap.execute(
            address(router),
            adjustedSwaps,
            outputs,
            p.deadline,
            abi.encodeCall(
                this.zapIncreaseLiquidityCallback,
                (INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: p.tokenId,
                    amount0Desired: 0,
                    amount1Desired: 0,
                    amount0Min: p.amount0Min,
                    amount1Min: p.amount1Min,
                    deadline: p.deadline
                }))
            ),
            nfpm.ownerOf(p.tokenId)
        );
    }

    function zapIncreaseLiquidityCallback(
        INonfungiblePositionManager.IncreaseLiquidityParams memory p
    ) external {
        if (msg.sender != address(this)) revert CC();
        MintReturn memory mr = _increaseLiquidityForZap(p);
        _mintCallbackResult = MintCallbackResult({
            tokenId: p.tokenId,
            liquidity: mr.liquidity,
            amount0: mr.amount0,
            amount1: mr.amount1
        });
    }

    function _increaseLiquidityForZap(
        INonfungiblePositionManager.IncreaseLiquidityParams memory p
    ) internal returns (MintReturn memory r) {
        r= MintReturn({
            tokenId: 0,
            liquidity: 0,
            amount0: 0,
            amount1: 0
        });
        (, , address token0, address token1, , , , , , , , ) = nfpm.positions(
            p.tokenId
        );
        p.amount0Desired = IERC20(token0).balanceOf(address(this));
        if (p.amount0Desired < p.amount0Min) revert IB(p.amount0Min, p.amount0Desired);
        p.amount1Desired = IERC20(token1).balanceOf(address(this));
        if (p.amount1Desired < p.amount1Min) revert IB(p.amount1Min, p.amount1Desired);
        IERC20(token0).forceApprove(address(nfpm), p.amount0Desired);
        IERC20(token1).forceApprove(address(nfpm), p.amount1Desired);
        (r.liquidity, r.amount0, r.amount1) = nfpm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: p.tokenId,
                amount0Desired: p.amount0Desired,
                amount1Desired: p.amount1Desired,
                amount0Min: p.amount0Min,
                amount1Min: p.amount1Min,
                deadline: p.deadline
            })
        );
        r.tokenId = p.tokenId;
        //revoke approval
        IERC20(token0).forceApprove(address(nfpm), 0);
        IERC20(token1).forceApprove(address(nfpm), 0);
    }

    // ===== Mint And Stake CL Position =====
    function zapMintAndStakeCL(
        IZapRouterHelper.ZapMintCLParams calldata p,
        address recipient
    )
        external
        override
        onlyRouter
        nonReentrant
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        if (recipient == address(0)) revert IR(recipient);
        if (p.recipient != address(this)) revert IR(p.recipient);

        // Pass the actual user recipient for both native ETH and dust refunds (not p.recipient which is set to this contract by RouterV2)
        (tokenId, liquidity, amount0, amount1) = _zapAndMintCL(p, recipient);

        // Look up the pool address from algebraFactory
        address pool = algebraFactory.customPoolByPair(
            p.deployer,
            p.token0,
            p.token1
        );
        address gauge = gaugeManager.gauges(pool);
        bool staked;
        // If gauge exists, deposit the NFT to enter farming
        if (gauge != address(0) && gaugeManager.isAlive(gauge)) {
            INonfungiblePositionManager(nfpm).approve(gauge, tokenId);
            IGaugeCL(gauge).deposit(tokenId);
            staked = true;
        }

        emit StakeStatus(recipient, tokenId, pool, gauge, staked);

        // Transfer the NFT to the recipient
        nfpm.safeTransferFrom(address(this), recipient, tokenId);
    }
}
