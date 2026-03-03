// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './interfaces/IPair.sol';
import './interfaces/IRouterHelper.sol';
import './interfaces/IZapRouterHelper.sol';
import './interfaces/IGaugeCL.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPairFactory.sol";
import "./interfaces/IWETH.sol";
import "./libraries/Errors.sol";

contract RouterV2 is ReentrancyGuard {

	using SafeERC20 for IERC20;
    address public factory;
    IWETH public wETH;

    address public routerHelper;
    address public zapRouterHelper;

    // swap event for the rebate system
    event Swap(address indexed sender,uint amount0In, uint amount0Out,address _tokenIn, address indexed to, bool stable);

    event RouterHelperUpdated(address indexed oldRouterHelper, address indexed newRouterHelper);
    event ZapRouterHelperUpdated(address indexed oldZapRouterHelper, address indexed newZapRouterHelper);

    modifier ensure(uint deadline) {
        if (deadline < block.timestamp) revert EXP();
        _;
    }

    constructor(address _factory, address _wETH) {
        factory = _factory;
        wETH = IWETH(_wETH);
        routerHelper = msg.sender;
        zapRouterHelper = msg.sender;
    }

    receive() external payable {
        assert(msg.sender == address(wETH)); // only accept ETH via fallback from the WETH contract; forced ETH transfers are still possible.
    }

    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0) || token0 == token1) revert IA();
    }

    function pairFor(address tokenA, address tokenB, bool stable) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = IPairFactory(factory).getPair(token0, token1, stable);
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB, bool stable) public view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IPair(pairFor(tokenA, tokenB, stable)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal view returns (uint amountA, uint amountB) {
        // Calculate optimal amounts using helper
        (amountA, amountB) = IRouterHelper(routerHelper).calculateAddLiquidity(
            tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin
        );
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external ensure(deadline) nonReentrant returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = pairFor(tokenA, tokenB, stable);
        if((IPairFactory(factory).isGenesis(pair) && IPair(pair).totalSupply() == 0)) revert NA();
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IPair(pair).mint(to);

        // Additional check: ensure we received liquidity tokens
        if (liquidity == 0) revert ZERO_LIQUIDITY_MINTED();
    }

    function addLiquidityETH(
        address token,
        bool stable,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable ensure(deadline) nonReentrant returns (uint amountToken, uint amountETH, uint liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token,
            address(wETH),
            stable,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = pairFor(token, address(wETH), stable);
        _safeTransferFrom(token, msg.sender, pair, amountToken);
        wETH.deposit{value: amountETH}();
        assert(wETH.transfer(pair, amountETH));
        liquidity = IPair(pair).mint(to);

        // Additional check: ensure we received liquidity tokens
        if (liquidity == 0) revert ZERO_LIQUIDITY_MINTED();

        // refund dust ETH, if any
        if (msg.value > amountETH) _safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    /// @dev Internal helper, no reentrancy guard. Public/externals must be `nonReentrant`
    ///      and delegate to this to avoid nested `nonReentrant` calls.
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to
    ) internal returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB, stable);
        if (!IPair(pair).transferFrom(msg.sender, pair, liquidity)) revert ITFM();
        (uint amount0, uint amount1) = IPair(pair).burn(to);
        (address token0,) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin || amountB < amountBMin) revert IAA();
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) nonReentrant returns (uint amountA, uint amountB) {
        (amountA, amountB) = _removeLiquidity(
            tokenA,
            tokenB,
            stable,
            liquidity,
            amountAMin,
            amountBMin,
            to
        );
    }

    function removeLiquidityETH(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public ensure(deadline) nonReentrant returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = _removeLiquidity(
            token,
            address(wETH),
            stable,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this)
        );
        _safeTransfer(token, to, amountToken);
        wETH.withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    /// @dev Internal function to get pair and check permit/allowance for regular token pairs
    function _getPairAndCheckPermit(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (address pair) {
        pair = pairFor(tokenA, tokenB, stable);
        try IPair(pair).permit(
            msg.sender, 
            address(this), 
            approveMax ? type(uint).max : liquidity, 
            deadline, 
            v, 
            r, 
            s
        ) {
            // Permit succeeded
        } catch {
            // Permit failed, check if we have sufficient allowance
            if (IPair(pair).allowance(msg.sender, address(this)) < liquidity) revert IA();
        }
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external ensure(deadline) nonReentrant returns (uint amountA, uint amountB) {
        _getPairAndCheckPermit(tokenA, tokenB, stable, liquidity, deadline, approveMax, v, r, s);

        (amountA, amountB) = _removeLiquidity(
            tokenA,
            tokenB,
            stable,
            liquidity,
            amountAMin,
            amountBMin,
            to
        );
    }

    function removeLiquidityETHWithPermit(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external ensure(deadline) nonReentrant returns (uint amountToken, uint amountETH) {
        _getPairAndCheckPermit(token, address(wETH), stable, liquidity, deadline, approveMax, v, r, s);

        (amountToken, amountETH) = _removeLiquidity(
            token,
            address(wETH),
            stable,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to
        );
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        IRouter.route[] calldata routes,
        address to,
        uint deadline
    ) external ensure(deadline) nonReentrant returns (uint[] memory amounts) {
        if (routes[routes.length - 1].receiver != to) revert IR(routes[routes.length - 1].receiver);
        (amounts,,) = IRouterHelper(routerHelper).getAmountsOut(amountIn, routes);
        if (amounts[amounts.length - 1] < amountOutMin) revert IOA(amountOutMin, amounts[amounts.length - 1]);
        if(!routes[0].concentrated)
        {
            _safeTransferFrom(
                routes[0].from, msg.sender, routes[0].pair, amounts[0]
            );
        }
        else{
            _safeTransferFrom(routes[0].from, msg.sender, routerHelper, amounts[0]);
        }
        IRouterHelper(routerHelper).swap(amounts, routes, deadline, msg.sender);
    }

    function swapExactETHForTokens(uint amountOutMin, IRouter.route[] calldata routes, address to, uint deadline) external payable ensure(deadline) nonReentrant returns (uint[] memory amounts) {
        if (routes[0].from != address(wETH)) revert INP();
        if (routes[routes.length - 1].receiver != to) revert IR(routes[routes.length - 1].receiver);
        (amounts,,) = IRouterHelper(routerHelper).getAmountsOut(msg.value, routes);
        if (amounts[amounts.length - 1] < amountOutMin) revert IOA(amountOutMin, amounts[amounts.length - 1]);
        wETH.deposit{value: amounts[0]}();

        if (!routes[0].concentrated) {
            assert(wETH.transfer(pairFor(routes[0].from, routes[0].to, routes[0].stable),amounts[0]));
        } else {
            assert(wETH.transfer(routerHelper, amounts[0]));
        }
        IRouterHelper(routerHelper).swap(amounts, routes, deadline, msg.sender);
    }

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, IRouter.route[] calldata routes, address to, uint deadline)
    external
    ensure(deadline)
    nonReentrant
    returns (uint[] memory amounts)
    {
        if (routes[routes.length - 1].to != address(wETH)) revert INP();
        if (routes[routes.length - 1].receiver != address(this)) revert IR(routes[routes.length - 1].receiver);

        (amounts,,) = IRouterHelper(routerHelper).getAmountsOut(amountIn, routes);
        if (amounts[amounts.length - 1] < amountOutMin) revert IOA(amountOutMin, amounts[amounts.length - 1]);

        if(!routes[0].concentrated)
        {
            _safeTransferFrom(
                routes[0].from, msg.sender, pairFor(routes[0].from, routes[0].to, routes[0].stable), amounts[0]
            );
        }
        else{
            _safeTransferFrom(routes[0].from, msg.sender, routerHelper, amounts[0]);
        }
        IRouterHelper(routerHelper).swap(amounts, routes, deadline, msg.sender);
        wETH.withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function UNSAFE_swapExactTokensForTokens(
        uint[] memory amounts,
        IRouter.route[] calldata routes,
        address to,
        uint deadline
    ) external ensure(deadline) nonReentrant returns (uint[] memory) {
        if (routes[routes.length - 1].receiver != to) revert IR(routes[routes.length - 1].receiver);
        if (routes[0].concentrated) {
            _safeTransferFrom(routes[0].from, msg.sender, routerHelper, amounts[0]);
        } else {
            _safeTransferFrom(routes[0].from, msg.sender, pairFor(routes[0].from, routes[0].to, routes[0].stable), amounts[0]);
        }
        IRouterHelper(routerHelper).swap(amounts, routes, deadline, msg.sender);
        return amounts;
    }

    function _safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        if (!success) revert ETF(value);
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        if (token.code.length == 0) revert CODELEN();
        (bool success, bytes memory data) =
        token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert IST();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        if (token.code.length == 0) revert CODELEN();
        (bool success, bytes memory data) =
        token.call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert ISTF();
    }

    // Experimental Extension [ETH.guru/solidly/BaseV1Router02]

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens)****
    function _removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to
    ) internal returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = _removeLiquidity(
            token,
            address(wETH),
            stable,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this)
        );
        _safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        wETH.withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public ensure(deadline) nonReentrant returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = _removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            stable,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to
        );
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external ensure(deadline) nonReentrant returns (uint amountToken, uint amountETH) {
        _getPairAndCheckPermit(token, address(wETH), stable, liquidity, deadline, approveMax, v, r, s);
        (amountToken, amountETH) = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, stable, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }
    
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        IRouter.route[] calldata routes,
        address to,
        uint deadline
    ) external ensure(deadline) nonReentrant {
        _safeTransferFrom(
        	routes[0].from,
        	msg.sender,
        	pairFor(routes[0].from, routes[0].to, routes[0].stable),
        	amountIn
        );
        uint routesLen = routes.length;
        uint balanceBefore = IERC20(routes[routesLen - 1].to).balanceOf(to);
        IRouterHelper(routerHelper).swapSupportingFeeOnTransferTokens(routes, to, msg.sender);
        uint amountOut = IERC20(routes[routesLen - 1].to).balanceOf(to) - balanceBefore;
        if (amountOut < amountOutMin) revert IOA(amountOutMin, amountOut);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        IRouter.route[] calldata routes,
        address to,
        uint deadline
    )
        external
        payable
        ensure(deadline)
        nonReentrant
    {
        if (routes[0].from != address(wETH)) revert INP();
        uint amountIn = msg.value;
        wETH.deposit{value: amountIn}();
        uint routesLen = routes.length;
        assert(wETH.transfer(pairFor(routes[0].from, routes[0].to, routes[0].stable), amountIn));
        uint balanceBefore = IERC20(routes[routesLen - 1].to).balanceOf(to);
        IRouterHelper(routerHelper).swapSupportingFeeOnTransferTokens(routes, to, msg.sender);
        uint amountOut = IERC20(routes[routesLen - 1].to).balanceOf(to) - balanceBefore;
        if (amountOut < amountOutMin) revert IOA(amountOutMin, amountOut);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        IRouter.route[] calldata routes,
        address to,
        uint deadline
    )
        external
        ensure(deadline)
        nonReentrant
    {
        if (routes[routes.length - 1].to != address(wETH)) revert INP();
        if (routes[routes.length - 1].receiver != address(this)) revert IR(routes[routes.length - 1].receiver);
        _safeTransferFrom(
            routes[0].from, msg.sender, pairFor(routes[0].from, routes[0].to, routes[0].stable), amountIn
        );
        IRouterHelper(routerHelper).swapSupportingFeeOnTransferTokens(routes, address(this), msg.sender);
        uint amountOut = IERC20(address(wETH)).balanceOf(address(this));
        if (amountOut < amountOutMin) revert IOA(amountOutMin, amountOut);
        wETH.withdraw(amountOut);
        _safeTransferETH(to, amountOut);
    }

    /**
     * @dev Add liquidity by providing only one token, automatically swapping to get the other
     * @param p Parameters:
     *        - tokenA: first token of the pair
     *        - tokenB: second token of the pair
     *        - stable: whether the pair is stable
     *        - swaps: swap operations to convert inputs into tokenA/tokenB
     *        - amountAMin/amountBMin: minimums for addLiquidity
     *        - deadline: transaction deadline
     *        - to: recipient of liquidity tokens and dust
     *        - usenative: whether to wrap msg.value into WETH according to swaps
     * @return amountA Amount of tokenA used
     * @return amountB Amount of tokenB used
     * @return liquidity Amount of liquidity tokens minted
     */
    function zapAndAddLiquidity(IZapRouterHelper.ZapAddParams calldata p)
        external
        payable
        ensure(p.deadline)
        returns (uint256, uint256, uint256)
    {
        _collectInputTokens(p.inputTokens, p.amounts, p.usenative, zapRouterHelper);

        // Delegate the zap add flow to helper;
        (uint256 amountA_, uint256 amountB_, uint256 liquidity_) = IZapRouterHelper(zapRouterHelper).zapAndAddLiquidity(p);
        return (amountA_, amountB_, liquidity_);
    }

    /**
     * @dev Remove liquidity and convert one token back to a single output token
     * @param p Parameters:
     *        - tokenA/tokenB/stable/liquidity
     *        - outputToken: token to receive
     *        - swaps: swap routes to convert the other token into outputToken
     *        - minAmountOut: minimum expected output
     *        - unwrapWETH: whether to unwrap WETH to ETH for output
     *        - deadline/to
     * @return amountOut Amount of output token received
     */
    function zapAndRemoveLiquidity(
        IZapRouterHelper.ZapRemoveParams calldata p
    ) external ensure(p.deadline) returns (uint256 amountOut) {
          // Remove liquidity
        removeLiquidity(
            p.tokenA, p.tokenB, p.stable, p.liquidity, p.amount0Min, p.amount1Min, address(zapRouterHelper), p.deadline
        );
        // Swap two tokens to single output
        address[] memory tokens = _pair(p.tokenA, p.tokenB);
        amountOut = IZapRouterHelper(zapRouterHelper).zapToSingleToken(
            IZapRouterHelper.ZapToSingleTokenParams({
                inputTokens: tokens,
                amounts: new uint256[](0), // Not used
                outputToken: p.outputToken,
                swaps: p.swaps,
                minAmountOut: p.minAmountOut,
                unwrapWETH: p.unwrapWETH,
                usenative: false,
                deadline: p.deadline,
                to: p.to
            })
        );
    }

    /**
     * @dev Mint a concentrated-liquidity position by zapping inputs to token0/token1
     */
    function zapAndMintCL(
        IZapRouterHelper.ZapMintCLParams calldata p
    ) external payable ensure(p.deadline) returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Collect inputs to this contract and forward to helper
        _collectInputTokens(p.inputTokens, p.amounts, p.usenative, zapRouterHelper);
        (tokenId, liquidity, amount0, amount1) = IZapRouterHelper(zapRouterHelper).zapAndMintCL(p);
    }

    function zapMintAndStakeCL(
        IZapRouterHelper.ZapMintCLParams calldata p
    ) external payable ensure(p.deadline) returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Collect inputs to this contract and forward to helper
        _collectInputTokens(p.inputTokens, p.amounts, p.usenative, zapRouterHelper);
        IZapRouterHelper.ZapMintCLParams memory params = p;
        params.recipient = address(zapRouterHelper);
        (tokenId, liquidity, amount0, amount1) = IZapRouterHelper(zapRouterHelper).zapMintAndStakeCL(params, p.recipient);
    }

    /**
     * @dev Mint a concentrated-liquidity position, optionally enter farming via GaugeCL,
     *      and then transfer the NFT to the user.
     *
     * Flow:
     * - User approves this router for token0 and token1.
     * - Router pulls `amount0Desired`/`amount1Desired` from user and transfers to RouterHelper.
     * - RouterHelper handles minting, optionally staking in gauge (if exists), refunding dust, and transferring NFT to user.
     *
     * Note: Any unused token0/token1 remaining after mint are refunded to the user by RouterHelper.
     * If user sent native ETH, it will be wrapped into WETH and used for the mint. Any excess native ETH will be refunded to the user as WETH.
     */
    function mintCLAndStake(
        INonfungiblePositionManager.MintParams calldata params
    )
        external
        payable
        ensure(params.deadline)
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.token0 == params.token1) revert INP(); // no double-WETH pool

        // Build input arrays for unified collection logic
        address[] memory inputTokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        inputTokens[0] = params.token0;
        inputTokens[1] = params.token1;
        amounts[0] = params.amount0Desired;
        amounts[1] = params.amount1Desired;

        // Decide whether to use native ETH for WETH based on msg.value and desired amount
        bool usenative =
            (params.token0 == address(wETH) && msg.value >= params.amount0Desired) ||
            (params.token1 == address(wETH) && msg.value >= params.amount1Desired);

        // Collect tokens from user and transfer directly to RouterHelper
        _collectInputTokens(inputTokens, amounts, usenative, routerHelper);

        // Delegate to RouterHelper to handle minting, optional staking, and NFT transfer
        (tokenId, liquidity, amount0, amount1) = IRouterHelper(routerHelper).mintCLAndStake(params, msg.sender);
    }

    /**
     * @dev Decrease liquidity on a CL position NFT and swap proceeds to a single output token
     */
    function zapAndRemoveCL(
        IZapRouterHelper.ZapRemoveCLParams calldata p
    ) external ensure(p.deadline) returns (uint256 amountOut) {
        INonfungiblePositionManager nfpm = IZapRouterHelper(zapRouterHelper).nfpm();
        if (nfpm.ownerOf(p.tokenId) != msg.sender) revert NOT_AUTHORIZED();
        // Get token addresses from position
        (, , address token0, address token1, , , , , , , , ) = nfpm.positions(p.tokenId);
        bool isZapRequired = p.swaps.length > 0 && p.outputToken != address(0);
        address recipient = isZapRequired ? zapRouterHelper : p.to;
        
        require(nfpm.isApprovedOrOwner(address(this), p.tokenId), "NOT_APPROVED");
        nfpm.safeTransferFrom(msg.sender, routerHelper, p.tokenId);

        IRouterHelper(routerHelper)
            .unstakeAndWithdraw(p.tokenId, p.liquidity, p.amount0Min, p.amount1Min, recipient, msg.sender, p.deadline);
        if (isZapRequired) {    
            // Swap two tokens to single output
            address[] memory tokens = _pair(token0, token1);
            amountOut = IZapRouterHelper(zapRouterHelper).zapToSingleToken(
                IZapRouterHelper.ZapToSingleTokenParams({
                    inputTokens: tokens,
                    amounts: new uint256[](0), // Not used
                    outputToken: p.outputToken,
                    swaps: p.swaps,
                    minAmountOut: p.minAmountOut,
                    unwrapWETH: p.unwrapWETH,
                    usenative: false,
                    deadline: p.deadline,
                    to: p.to
                })
            );
        }
    }

    /**
     * @dev Increase liquidity on a CL position NFT by zapping inputs to token0/token1
     */
    function zapAndIncreaseLiquidity(
        IZapRouterHelper.ZapIncreaseLiquidityParams calldata p
    ) external payable ensure(p.deadline) returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        _collectInputTokens(p.inputTokens, p.amounts, p.usenative, zapRouterHelper);
        (liquidity, amount0, amount1) = IZapRouterHelper(zapRouterHelper).zapAndIncreaseLiquidity(p);
    }

    /**
     * @dev Collect input tokens and zap them to a single output token
     * @param p Parameters struct containing all zap configuration
     * @return amountOut Amount of output token received
     */
    function zapToSingleToken(
        IZapRouterHelper.ZapToSingleTokenParams calldata p
    ) external payable ensure(p.deadline) returns (uint256 amountOut) {
        _collectInputTokens(p.inputTokens, p.amounts, p.usenative, zapRouterHelper);
        amountOut = IZapRouterHelper(zapRouterHelper).zapToSingleToken(p);
    }

    /**
     * @dev Collect input tokens from user
     * @param inputTokens Array of tokens to collect
     * @param amounts Array of corresponding amounts for each token
     * @param usenative Whether to use native ETH (skip WETH transfers)
     */
    function _collectInputTokens(
        address[] memory inputTokens,
        uint256[] memory amounts,
        bool usenative,
        address recipient
    ) internal {
        if (inputTokens.length != amounts.length) revert ALM(inputTokens.length, amounts.length);
        uint256 requiredEth = 0;
        for (uint256 i = 0; i < inputTokens.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            address token = inputTokens[i];
            if (usenative && token == address(wETH)) {
                // Track how much ETH we need to wrap into WETH for the helper.
                requiredEth += amount;
            } else {
                // Standard ERC20 path (including WETH when not using native ETH)
                _safeTransferFrom(token, msg.sender, recipient, amount);
            }
        }

        if (msg.value < requiredEth) revert BE(requiredEth, msg.value);
        if (requiredEth > 0) {
            wETH.deposit{value: requiredEth}();
            assert(wETH.transfer(recipient, requiredEth));
        }
        // Refund any leftover ETH (or all ETH when requiredEth == 0).
        if (msg.value > requiredEth) {
            _safeTransferETH(msg.sender, msg.value - requiredEth);
        }
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function setRouterHelper(address _routerHelper) external {
        if (msg.sender != zapRouterHelper) revert NOT_AUTHORIZED();
        emit RouterHelperUpdated(routerHelper, _routerHelper);
        routerHelper = _routerHelper;
    }

    function setZapRouterHelper(address _zapRouterHelper) external {
        if (msg.sender != zapRouterHelper) revert NOT_AUTHORIZED();
        emit ZapRouterHelperUpdated(zapRouterHelper, _zapRouterHelper);
        zapRouterHelper = _zapRouterHelper;
    }
}