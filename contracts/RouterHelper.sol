// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import './interfaces/IPair.sol';
import "./interfaces/IRouter.sol";
import './interfaces/IPairFactory.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/IQuoterV2.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/ISwapRouter.sol';
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import './interfaces/IAlgebraPoolAPIStorage.sol';
import { IERC20 as IERC20WithDecimals } from './interfaces/IERC20.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./libraries/Math.sol";
import "./interfaces/IRouterHelper.sol";
import './interfaces/IGaugeCL.sol';
import './interfaces/IGaugeManager.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraFactory.sol';
import "./libraries/Errors.sol";
import "@cryptoalgebra/integral-farming/contracts/interfaces/IFarmingCenter.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IERC20Minimal.sol";
import "./libraries/FarmingExitLib.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract RouterHelper is IRouterHelper, OwnableUpgradeable, ReentrancyGuardUpgradeable,  IERC721Receiver {
    using SafeERC20 for IERC20;

    uint internal constant MINIMUM_LIQUIDITY = 10**3;

    address public router;

    modifier onlyRouter() {
        if (msg.sender != router) revert NOT_AUTHORIZED();
        _;
    }

    struct PairSwapMetadata {
        uint decimals0;
        uint decimals1;
        uint reserve0;
        uint reserve1;
        bool stable;
        address token0;
        address token1;
        uint balanceA;
        uint balanceB;
        uint reserveA;
        uint reserveB;
        uint decimalsA;
        uint decimalsB;
    }

    address public factory;
    IQuoterV2 public quoterV2;
    IAlgebraPoolAPIStorage public algebraPoolAPIStorage;
    address public swapRouter;
    INonfungiblePositionManager public nfpm;
    IAlgebraFactory public algebraFactory;
    IGaugeManager public gaugeManager;
    IFarmingCenter public farmingCenter;
    event Swap(address indexed sender,uint amount0In, uint amount0Out,address _tokenIn, address indexed to, bool stable);
    error ZA();

    constructor() {}
    
    function initialize(
        address _factory,
        address _quoterV2,
        address _algebraPoolAPIStorage,
        address _swapRouter,
        address _nfpm,
        address _algebraFactory,
        address _gaugeManager,
        address _router,
        address _farmingCenter
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        factory = _factory;
        quoterV2 = IQuoterV2(_quoterV2);
        algebraPoolAPIStorage = IAlgebraPoolAPIStorage(_algebraPoolAPIStorage);
        swapRouter = _swapRouter;
        nfpm = INonfungiblePositionManager(_nfpm);
        algebraFactory = IAlgebraFactory(_algebraFactory);
        gaugeManager = IGaugeManager(_gaugeManager);
        router = _router;
        farmingCenter = IFarmingCenter(_farmingCenter);
    }

    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    /**
     * @notice Returns the output amounts and price information for a given input amount and swap route.
     * @dev For each route, calculates the output amount and price before/after swap.
     *      The price values (priceBeforeSwap and priceAfterSwap) are always quoted as token1 price with respect to token0 (token0 to token1).
     *      For basic pairs, priceBeforeSwap and priceAfterSwap are the reserves ratio (reserve1/reserve0) before and after the swap.
     *      For CL pools, priceBeforeSwap and priceAfterSwap are the sqrt price at the current tick before and after the swap.
     * @param amountIn The input token amount.
     * @param routes The swap route array.
     * @return amounts The resulting amounts after each swap step.
     * @return priceBeforeSwap For basic pairs, this is the reserves ratio before swap; for CL pools, this is the sqrt price at the current tick before swap.
     * @return priceAfterSwap For basic pairs, this is the reserves ratio after swap; for CL pools, this is the sqrt price at the current tick after swap.
     */
    function getAmountsOut(uint amountIn, IRouter.route[] memory routes) public returns (uint[] memory amounts, uint[] memory priceBeforeSwap, uint[] memory priceAfterSwap) {
        uint routesLen = routes.length;
        require(routesLen >= 1, 'INP');
        amounts = new uint[](routesLen+1);
        priceAfterSwap = new uint[](routesLen+1);
        priceBeforeSwap = new uint[](routesLen+1);
        amounts[0] = amountIn;
        priceAfterSwap[0] = 0;
        priceBeforeSwap[0] = 0;

        IQuoterV2.QuoteExactInputSingleParams memory clInputParams;

        for (uint i = 0; i < routesLen; i++) {
            IRouter.route memory route = routes[i];
            if(route.concentrated){
                clInputParams = IQuoterV2.QuoteExactInputSingleParams ({
                    tokenIn: route.from,
                    tokenOut: route.to,
                    deployer: IAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(route.pair),
                    amountIn: amounts[i],
                    limitSqrtPrice: 0
                });
                
                try IQuoterV2(quoterV2).quoteExactInputSingle(clInputParams) returns (
                    uint quotedAmount,uint256, 
                    uint160 sqrtPriceX96After,  
                    uint32, 
                    uint256, 
                    uint16  
                ) {
                    amounts[i+1] = quotedAmount;
                    priceAfterSwap[i+1] = sqrtPriceX96After;
                    (uint160 price, , , , , ) = IAlgebraPool(route.pair).globalState();
                    priceBeforeSwap[i+1] = uint(price);
                } catch {
                    amounts[i+1] = 0;
                    priceAfterSwap[i+1] = 0;
                    priceBeforeSwap[i+1] = 0;
                    break;
                }
            }
            else{
                if (IPairFactory(factory).isPair(route.pair)) {
                    try IPair(route.pair).getAmountOut(amounts[i], route.from) returns (uint outAmt) {
                        (bool swapPossible, uint afterReseve0, uint afterReserve1) = _swapRatio(amounts[i], route.from, route.pair, outAmt);
                        if(!swapPossible) {
                            amounts[i+1] = 0;
                            priceAfterSwap[i+1] = 0;
                            break;
                        }
                        amounts[i+1] = outAmt;
                        uint decimals0 = IERC20WithDecimals(route.from).decimals();
                        uint decimals1 = IERC20WithDecimals(route.to).decimals();

                        if(route.from > route.to) {
                            (decimals0, decimals1) = (decimals1, decimals0);
                        }

                        (uint beforeReserve0, uint beforeReserve1,) = IPair(route.pair).getReserves();

                        // Check if this is a stable pair to use appropriate price formula
                        (, , , , bool stable,,) = IPair(route.pair).metadata();

                        if (stable) {
                            // Use stable swap price formula for both before and after swap
                            priceBeforeSwap[i+1] = _calculateStableSwapPrice(beforeReserve0, beforeReserve1, decimals0, decimals1);
                            priceAfterSwap[i+1] = _calculateStableSwapPrice(afterReseve0, afterReserve1, decimals0, decimals1);
                        } else {
                            // Use standard AMM price formula for volatile pairs
                            // Price = (r1 / decimals1) / (r0 / decimals0) * 1e18
                            // This gives us the price in 18 decimal precision
                            if(18 + decimals0 >= decimals1){
                                priceBeforeSwap[i+1] = (beforeReserve1 * 10**(18 + decimals0 - decimals1)) / (beforeReserve0);
                                priceAfterSwap[i+1] = (afterReserve1 * 10**(18 + decimals0 - decimals1)) / (afterReseve0);
                            } else {
                                priceBeforeSwap[i+1] = (beforeReserve1) / (beforeReserve0 * 10**(decimals1 - decimals0 - 18));
                                priceAfterSwap[i+1] = (afterReserve1) / (afterReseve0 * 10**(decimals1 - decimals0 - 18));
                            }
                        }
                    } catch {
                        amounts[i+1] = 0;
                        priceAfterSwap[i+1] = 0;
                        break;
                    }
                } else {
                    amounts[i+1] = 0;
                    priceAfterSwap[i+1] = 0;
                    break;
                }
            }
        }
    }

    function _swapRatio(uint amountIn, address tokenIn, address pair, uint amountOut) internal view returns (bool, uint, uint){

        PairSwapMetadata memory pairSwapMetaData;
    
        (pairSwapMetaData.decimals0, pairSwapMetaData.decimals1, pairSwapMetaData.reserve0, 
        pairSwapMetaData.reserve1, pairSwapMetaData.stable, pairSwapMetaData.token0, pairSwapMetaData.token1)
         = IPair(pair).metadata();
        uint _balance0 = IERC20(pairSwapMetaData.token0).balanceOf(address(pair));
        uint _balance1 = IERC20(pairSwapMetaData.token1).balanceOf(address(pair));

        (pairSwapMetaData.balanceA, pairSwapMetaData.balanceB) = tokenIn == pairSwapMetaData.token0 ? (_balance0, _balance1) : (_balance1, _balance0);
        (pairSwapMetaData.reserveA, pairSwapMetaData.reserveB) = tokenIn == pairSwapMetaData.token0 ? (pairSwapMetaData.reserve0, pairSwapMetaData.reserve1) : (pairSwapMetaData.reserve1, pairSwapMetaData.reserve0);
        (pairSwapMetaData.decimalsA, pairSwapMetaData.decimalsB) = tokenIn == pairSwapMetaData.token0 ? (pairSwapMetaData.decimals0, pairSwapMetaData.decimals1) : (pairSwapMetaData.decimals1, pairSwapMetaData.decimals0);

        uint actualAmountIn = amountIn + pairSwapMetaData.balanceA - pairSwapMetaData.reserveA;
        uint feeAmount = actualAmountIn * IPairFactory(factory).getFee(pair, pairSwapMetaData.stable) / 10000;
        pairSwapMetaData.balanceA = pairSwapMetaData.balanceA + amountIn - feeAmount;
        pairSwapMetaData.balanceB -= amountOut;

        uint afterReserveA = pairSwapMetaData.reserveA + actualAmountIn - feeAmount;
        uint afterReserveB = pairSwapMetaData.reserveB - amountOut;

        uint afterReserve0 = tokenIn == pairSwapMetaData.token0 ? afterReserveA : afterReserveB;
        uint afterReserve1 = tokenIn == pairSwapMetaData.token0 ? afterReserveB : afterReserveA;

        if(_k(pairSwapMetaData.balanceA, pairSwapMetaData.balanceB, pairSwapMetaData.decimalsA, pairSwapMetaData.decimalsB, pairSwapMetaData.stable) >= _k(pairSwapMetaData.reserveA, pairSwapMetaData.reserveB, pairSwapMetaData.decimalsA, pairSwapMetaData.decimalsB, pairSwapMetaData.stable)){
            return (true, afterReserve0, afterReserve1);
        }
        return (false, afterReserve0, afterReserve1);
    }

    function _k(uint x, uint y, uint decimals0, uint decimals1, bool stable) internal pure returns (uint) {
        if (stable) {
            uint _x = x * 1e18 / decimals0;
            uint _y = y * 1e18 / decimals1;
            uint _a = (_x * _y) / 1e18;
            uint _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
            return _a * _b / 1e18;  // x3y+y3x >= k
        } else {
            return x * y; // xy >= k
        }
    }

    function _getMinimumLiquidity(uint amount0, uint amount1, uint decimals0, uint decimals1) internal pure returns (uint) {
        uint totalLiquidity = Math.sqrt(amount0 * amount1);
        uint minLiquidity0 = (decimals0 * totalLiquidity) / (1e4 * amount0);
        uint minLiquidity1 = (decimals1 * totalLiquidity) / (1e4 * amount1);
        return Math.max(minLiquidity0, minLiquidity1);
    }

    function _calculateStableSwapPrice(
        uint x,
        uint y,
        uint decimals0,
        uint decimals1
    ) internal pure returns (uint) {
        // Normalize reserves to 18 decimals
        uint _x = (x * 1e18) / 10**decimals0;
        uint _y = (y * 1e18) / 10**decimals1;

        if (_x == 0 || _y == 0) return 0;

        // Precompute squared terms, scaled down
        uint r0Sq = (_x * _x) / 1e18;
        uint r1Sq = (_y * _y) / 1e18;

        // Numerator and denominator coefficients (scaled terms)
        uint numeratorCoeff = (3 * r0Sq + r1Sq);
        uint denominatorCoeff = (r0Sq + 3 * r1Sq);

        // Now compute numerator and denominator carefully, dividing early
        uint numerator = (_y * numeratorCoeff) / 1e18;  // scaled down
        uint denominator = (_x * denominatorCoeff) / 1e18;

        if (denominator == 0) return 0;

        // Final scale to 1e18 precision
        return (numerator * 1e18) / denominator;
    }


    // performs chained getAmountOut calculations on any number of pairs
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) public view returns (uint amount, bool stable) {
        address pairStable = pairFor(tokenIn, tokenOut, true);
        address pairVolatile = pairFor(tokenIn, tokenOut, false);
        address pair;
        uint amountStable;
        uint amountVolatile;
        uint amountOut;

        if (IPairFactory(factory).isPair(pairStable) && !IPairFactory(factory).isGenesis(pairStable)) {
            // amountStable = IBaseV1Pair(pairStable).getAmountOut(amountIn, tokenIn);
            
            try IPair(pairStable).getAmountOut(amountIn, tokenIn) returns (uint outAmt) {
                amountStable = outAmt;
            } catch {
                amountStable = 0;
            }
        }

        if (IPairFactory(factory).isPair(pairVolatile) && !IPairFactory(factory).isGenesis(pairVolatile)) {
            //amountVolatile = IBaseV1Pair(pairVolatile).getAmountOut(amountIn, tokenIn);
            
            try IPair(pairVolatile).getAmountOut(amountIn, tokenIn) returns (uint outAmt) {
                amountVolatile = outAmt;
            } catch {
                amountVolatile = 0;
            }
        }

        (amountOut, stable, pair) = amountStable > amountVolatile ? (amountStable, true, pairStable) : (amountVolatile, false, pairVolatile);

        if (pair == address(0)) {
            return (0, true);
        }

        
        (bool swapPossible,,) = _swapRatio(amountIn, tokenIn, pair, amountOut);

        if(swapPossible){
            return (amountOut, stable);
        }

        return (0, true);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountOutForFeeOnTransfer(uint amountIn, address tokenIn, address tokenOut) public view returns (uint amount, bool stable) {
        address pairStable = pairFor(tokenIn, tokenOut, true);
        address pairVolatile = pairFor(tokenIn, tokenOut, false);
        address pair;
        uint amountStable;
        uint amountVolatile;
        uint amountOut;

        if (IPairFactory(factory).isPair(pairStable)) {
            // amountStable = IBaseV1Pair(pairStable).getAmountOut(amountIn, tokenIn);
            
            try IPair(pairStable).getAmountOut(amountIn, tokenIn) returns (uint outAmt) {
                amountStable = outAmt;
            } catch {
                amountStable = 0;
            }
        }

        if (IPairFactory(factory).isPair(pairVolatile)) {
            //amountVolatile = IBaseV1Pair(pairVolatile).getAmountOut(amountIn, tokenIn);
            
            try IPair(pairVolatile).getAmountOut(amountIn, tokenIn) returns (uint outAmt) {
                amountVolatile = outAmt;
            } catch {
                amountVolatile = 0;
            }
        }

        (amountOut, stable, pair) = amountStable > amountVolatile ? (amountStable, true, pairStable) : (amountVolatile, false, pairVolatile);

        if (pair == address(0)) {
            return (0, true);
        }

        
        (bool swapPossible,,) = _swapRatio(0, tokenIn, pair, amountOut);

        if(swapPossible){
            return (amountOut, stable);
        }

        return (0, true);
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB, bool stable) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        return IPairFactory(factory).getPair(token0, token1, stable);
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0) && token0 != token1, 'IA');
    }

    
    function version() external pure returns (string memory) {
        return "1.0.0-patch";
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quoteLiquidity(uint amountA, uint reserveA, uint reserveB) public pure returns (uint amountB) {
        require(amountA > 0 && reserveA > 0 && reserveB > 0, 'INL');
        amountB = amountA * reserveB / reserveA;
    }

    function getReserves(address tokenA, address tokenB, bool stable) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = pairFor(tokenA, tokenB, stable);
        (uint reserve0, uint reserve1,) = IPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired
    ) public view returns (uint amountA, uint amountB, uint liquidity) {
        address _pair = pairFor(tokenA, tokenB, stable);
        (uint reserveA, uint reserveB) = (0,0);
        uint _totalSupply = 0;
        if (_pair != address(0)) {
            _totalSupply = IERC20(_pair).totalSupply();
            (reserveA, reserveB) = getReserves(tokenA, tokenB, stable);
        }
        if (_totalSupply == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
            uint decimalsA = IERC20WithDecimals(tokenA).decimals();
            uint decimalsB = IERC20WithDecimals(tokenB).decimals();
            uint minimumLiquidity = stable 
                ? _getMinimumLiquidity(amountA, amountB, decimalsA, decimalsB) 
                : MINIMUM_LIQUIDITY;
            liquidity = Math.sqrt(amountA * amountB) - minimumLiquidity;
        } else {

            uint amountBOptimal = quoteLiquidity(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
                liquidity = Math.min(amountA * _totalSupply / reserveA, amountB * _totalSupply / reserveB);
            } else {
                uint amountAOptimal = quoteLiquidity(amountBDesired, reserveB, reserveA);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
                liquidity = Math.min(amountA * _totalSupply / reserveA, amountB * _totalSupply / reserveB);
                require(amountAOptimal <= amountADesired, 'IA');
            }
        }
    }

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity
    ) external view returns (uint amountA, uint amountB) {
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);

        if (_pair == address(0)) {
            return (0,0);
        }

        (uint reserveA, uint reserveB) = getReserves(tokenA, tokenB, stable);
        uint _totalSupply = IERC20(_pair).totalSupply();

        amountA = liquidity * reserveA / _totalSupply; // using balances ensures pro-rata distribution
        amountB = liquidity * reserveB / _totalSupply; // using balances ensures pro-rata distribution

    }

    function calculateAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) external view returns (uint amountA, uint amountB) {
        require(amountADesired >= amountAMin && amountBDesired >= amountBMin, 'DLMA');

        // Check if pair exists (view function, just checks)
        address _pair = pairFor(tokenA, tokenB, stable);
        if (_pair == address(0)) {
            revert("Pair not found");
        }
        (amountA, amountB,) = quoteAddLiquidity(tokenA, tokenB, stable, amountADesired, amountBDesired);
        require(amountA >= amountAMin && amountB >= amountBMin, 'IAA');
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function swap(uint[] memory amounts, IRouter.route[] memory routes, uint deadline, address sender) external onlyRouter {
        uint256 routesLen = routes.length;
        for (uint i = 0; i < routesLen; i++) {
            IRouter.route memory route = routes[i];
            if (route.receiver == address(0)) revert ZA();
            if(route.concentrated){
                if (IERC20(route.from).allowance(address(this), swapRouter) < amounts[i]) {
                    IERC20(route.from).forceApprove(swapRouter, amounts[i]);
                }
                ISwapRouter.ExactInputSingleParams memory inputParams;
                inputParams = ISwapRouter.ExactInputSingleParams ({
                    tokenIn: route.from,
                    tokenOut: route.to,
                    deployer: IAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(route.pair),
                    recipient: route.receiver,
                    deadline: deadline,
                    amountIn: amounts[i],
                    amountOutMinimum: 0,
                    limitSqrtPrice: 0
                });

                amounts[i+1] = ISwapRouter(swapRouter).exactInputSingle(inputParams);
            }
            else{
                (address token0,) = sortTokens(route.from, route.to);
                uint amountOut = amounts[i + 1];
                (uint amount0Out, uint amount1Out) = route.from == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
                IPair(pairFor(route.from, route.to, route.stable)).swap(
                    amount0Out, amount1Out, route.receiver, new bytes(0)
                );
            }

            emit Swap(sender, amounts[i], amounts[i+1], route.from, route.receiver, route.stable); 
        }
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function swapSupportingFeeOnTransferTokens(IRouter.route[] memory routes, address _to, address sender) external onlyRouter {
        for (uint i; i < routes.length; i++) {
        	(address input, address output) = (routes[i].from, routes[i].to);
            (address token0,) = sortTokens(input, output);
            IPair pair = IPair(pairFor(routes[i].from, routes[i].to, routes[i].stable));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput,) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
            (amountOutput,) = getAmountOutForFeeOnTransfer(amountInput, input, output);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < routes.length - 1 ? pairFor(routes[i+1].from, routes[i+1].to, routes[i+1].stable) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));

            bool _stable = routes[i].stable;
            emit Swap(sender,amountInput,amountOutput,input,_to,_stable);  
        }
    }

    /**
     * @dev Mint a concentrated-liquidity position, optionally enter farming via GaugeCL,
     *      and then transfer the NFT to the recipient.
     *
     * Flow:
     * - RouterV2 collects tokens from user and transfers them to this helper.
     * - Helper approves NFPM and mints the position to itself.
     * - Helper looks up the gauge address for the pool.
     * - If gauge exists, helper calls `deposit(uint256)` on the GaugeCL contract to enter farming.
     * - Helper transfers the NFT to the recipient.
     * - Any unused tokens are refunded to the recipient.
     */
    function mintCLAndStake(
        INonfungiblePositionManager.MintParams calldata params,
        address sender
    ) external onlyRouter nonReentrant returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        address recipient = params.recipient;
        
        // Approve NFPM to spend tokens from this helper
        if (params.amount0Desired > 0) {
            IERC20(params.token0).forceApprove(address(nfpm), params.amount0Desired);
        }
        if (params.amount1Desired > 0) {
            IERC20(params.token1).forceApprove(address(nfpm), params.amount1Desired);
        }

        // Mint position to this helper so it can perform farming actions
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: params.token0,
            token1: params.token1,
            deployer: params.deployer,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0Desired: params.amount0Desired,
            amount1Desired: params.amount1Desired,
            amount0Min: params.amount0Min,
            amount1Min: params.amount1Min,
            recipient: address(this),
            deadline: params.deadline
        });

        (tokenId, liquidity, amount0, amount1) = nfpm.mint(mintParams);

        // Reset approvals to zero for safety
        if (params.amount0Desired > 0) {
            IERC20(params.token0).forceApprove(address(nfpm), 0);
        }
        if (params.amount1Desired > 0) {
            IERC20(params.token1).forceApprove(address(nfpm), 0);
        }

        // Refund any dust tokens back to the recipient
        uint256 bal0 = IERC20(params.token0).balanceOf(address(this));
        if (bal0 > 0) {
            IERC20(params.token0).safeTransfer(sender, bal0);
        }
        uint256 bal1 = IERC20(params.token1).balanceOf(address(this));
        if (bal1 > 0) {
            IERC20(params.token1).safeTransfer(sender, bal1);
        }

        // Look up the pool address from algebraFactory
        address pool = algebraFactory.customPoolByPair(params.deployer, params.token0, params.token1);
        address gauge = gaugeManager.gauges(pool);
        
        // If gauge exists, deposit the NFT to enter farming
        if (gauge != address(0) && gaugeManager.isAlive(gauge)) {
            INonfungiblePositionManager(nfpm).approve(gauge, tokenId);
            IGaugeCL(gauge).deposit(tokenId);
        }

        // Transfer the NFT to the recipient
        nfpm.safeTransferFrom(address(this), recipient, tokenId);
    }

    function unstakeAndWithdraw(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address sender,
        uint256 deadline
    ) external onlyRouter nonReentrant {
        FarmingExitLib.unstakeAndWithdraw(farmingCenter, nfpm, tokenId, liquidity, amount0Min, amount1Min, recipient, sender, deadline);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL UTILS
    //////////////////////////////////////////////////////////////*/

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
