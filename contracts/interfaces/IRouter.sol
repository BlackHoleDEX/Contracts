// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IRouter {
    struct route {
        address pair;
        address from;
        address to;
        bool stable;
        bool concentrated;
        address receiver;
    }
    function factory() external view returns (address);
    function wETH() external view returns (address);
    function routerHelper() external view returns (address);
    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);
    function swapExactTokensForTokens(uint amountIn,uint amountOutMin,route[] calldata routes,address to,uint deadline) external returns (uint[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        IRouter.route[] calldata routes,
        address to,
        uint deadline
    ) external;
    function addLiquidity(address tokenA,address tokenB,bool stable,uint amountADesired,uint amountBDesired,uint amountAMin,uint amountBMin,address to,uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
    function removeLiquidity(address tokenA,address tokenB,bool stable,uint liquidity,uint amountAMin,uint amountBMin,address to,uint deadline) external returns (uint amountA, uint amountB);
    function getReserves(address tokenA, address tokenB, bool stable) external view returns (uint reserveA, uint reserveB);
    function getPoolAmountOut(uint amountIn, address tokenIn, address pair) external view returns (uint amount);
}
