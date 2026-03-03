// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Zap} from "../libraries/zap.sol";
import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

interface IZapRouterHelper {

    struct ZapRemoveCLParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        address outputToken;
        Zap.Swap[] swaps;
        uint256 minAmountOut;
        bool unwrapWETH;
        uint256 deadline;
        address to;
    }

    struct ZapRemoveParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        address outputToken;
        Zap.Swap[] swaps;
        uint256 minAmountOut;
        bool unwrapWETH;
        uint256 deadline;
        address to;
    }

    function nfpm() external view returns (INonfungiblePositionManager nfpm);
    struct ZapAddParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint amountAMin;
        uint amountBMin;
        address to; // receiver
        uint deadline;
        Zap.Swap[] swaps;
        bool usenative;
        address[] inputTokens;
        uint256[] amounts;
    }

    function zapAndAddLiquidity(
        ZapAddParams calldata p
    )
        external
        returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    struct ZapMintCLParams {
        address token0;
        address token1;
        address deployer;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        Zap.Swap[] swaps;
        bool usenative;
        address[] inputTokens;
        uint256[] amounts;
    }

    function zapAndMintCL(
        ZapMintCLParams calldata p
    )
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    struct ZapToSingleTokenParams {
        address[] inputTokens;
        uint256[] amounts;
        address outputToken;
        Zap.Swap[] swaps;
        uint256 minAmountOut;
        bool unwrapWETH;
        bool usenative;
        uint256 deadline;
        address to;
    }

    function zapToSingleToken(
        ZapToSingleTokenParams calldata p
    ) external returns (uint256 amountOut);

    struct ZapIncreaseLiquidityParams {
        uint256 tokenId;
        address token0;
        address token1;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        Zap.Swap[] swaps;
        bool usenative;
        address[] inputTokens;
        uint256[] amounts;
    }

    function zapAndIncreaseLiquidity(
        ZapIncreaseLiquidityParams calldata p
    )
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function zapMintAndStakeCL(
        ZapMintCLParams calldata p,
        address recipient
    )
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );
}
