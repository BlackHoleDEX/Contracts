// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "./IRouter.sol";
import '@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

interface IRouterHelper {
    function getAmountsOut(uint amountIn, IRouter.route[] memory routes) external returns (uint[] memory amounts, uint[] memory priceBeforeSwap, uint[] memory priceAfterSwap);
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);
    function getAmountOutForFeeOnTransfer(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);
    
    // Add liquidity calculation
    function calculateAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) external view returns (uint amountA, uint amountB);

    function quoteLiquidity(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired
    ) external view returns (uint amountA, uint amountB, uint liquidity);

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity
    ) external view returns (uint amountA, uint amountB);

    function swap(
        uint[] memory amounts,
        IRouter.route[] memory routes,
        uint deadline,
        address sender
    ) external;

    function swapSupportingFeeOnTransferTokens(
        IRouter.route[] memory routes,
        address to,
        address sender
    ) external;

    function mintCLAndStake(
        INonfungiblePositionManager.MintParams calldata params,
        address sender
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);


    function unstakeAndWithdraw(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address sender,
        uint256 deadline
    ) external;

    function version() external pure returns (string memory);
}