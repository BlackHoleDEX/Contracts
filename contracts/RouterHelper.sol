// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import './interfaces/IPair.sol';
import "./interfaces/IRouter.sol";
import './interfaces/IPairFactory.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/IQuoterV2.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/ISwapRouter.sol';
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import './interfaces/IAlgebraPoolAPIStorage.sol';
import './interfaces/IERC20.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract RouterHelper is OwnableUpgradeable {

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

    constructor() {}
    
    function initialize(address _factory, address _quoterV2, address _algebraPoolAPIStorage) public initializer {
        __Ownable_init();
        factory = _factory;
        quoterV2 = IQuoterV2(_quoterV2);
        algebraPoolAPIStorage = IAlgebraPoolAPIStorage(_algebraPoolAPIStorage);
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

            if(routes[i].concentrated){
                clInputParams = IQuoterV2.QuoteExactInputSingleParams ({
                    tokenIn: routes[i].from,
                    tokenOut: routes[i].to,
                    deployer: IAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(routes[i].pair),
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
                    (uint160 price, , , , , ) = IAlgebraPool(routes[i].pair).globalState();
                    priceBeforeSwap[i+1] = uint(price);
                } catch {
                    amounts[i+1] = 0;
                    priceAfterSwap[i+1] = 0;
                    priceBeforeSwap[i+1] = 0;
                }
            }
            else{
                if (IPairFactory(factory).isPair(routes[i].pair)) {
                    try IPair(routes[i].pair).getAmountOut(amounts[i], routes[i].from) returns (uint outAmt) {
                        (bool swapPossible, uint afterReseve0, uint afterReserve1) = _swapRatio(amounts[i], routes[i].from, routes[i].pair, outAmt);
                        if(!swapPossible) {
                            amounts[i+1] = 0;
                            priceAfterSwap[i+1] = 0;
                            break;
                        }
                        amounts[i+1] = outAmt;
                        // Get pair metadata to access decimal information
                        (uint decimals0, uint decimals1, , , , , ) = IPair(routes[i].pair).metadata();
                        (uint beforeReserve0, uint beforeReserve1,) = IPair(routes[i].pair).getReserves();
                        // Calculate price with proper decimal handling
                        // Price = (r1 / decimals1) / (r0 / decimals0) * 1e18
                        // This gives us the price in 18 decimal precision
                        priceBeforeSwap[i+1] = (beforeReserve1 * 1e18 / decimals1) / (beforeReserve0 / decimals0);
                        priceAfterSwap[i+1] = (afterReserve1 * 1e18 / decimals1) / (afterReseve0 / decimals0);
                    } catch {
                        amounts[i+1] = 0;
                        priceAfterSwap[i+1] = 0;
                    }
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

        pairSwapMetaData.balanceA += (amountIn - (amountIn * IPairFactory(factory).getFee(pair, pairSwapMetaData.stable) / 10000));
        pairSwapMetaData.balanceB -= amountOut;

        uint afterReserveA = pairSwapMetaData.reserveA + (amountIn - (amountIn * IPairFactory(factory).getFee(pair, pairSwapMetaData.stable) / 10000));
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
}
