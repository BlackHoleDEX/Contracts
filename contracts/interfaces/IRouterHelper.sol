pragma solidity 0.8.13;

import "./IRouter.sol";

interface IRouterHelper {
    function getAmountsOut(uint amountIn, IRouter.route[] memory routes) external returns (uint[] memory amounts, uint[] memory priceBeforeSwap, uint[] memory priceAfterSwap);
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);
}