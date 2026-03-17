// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Zap} from "../libraries/zap.sol";

interface ICLRebalancer {
    struct RebalanceParams {
        uint256 deadline;
        uint256 swapAmountIn;
        uint256 swapAmountOutMin;
        uint256 decreaseAmount0Min;
        uint256 decreaseAmount1Min;
        Zap.Swap[] swaps;
        INonfungiblePositionManager.MintParams mintParams;
    }

    event PositionRebalanced(uint256 oldTokenId, uint256 newTokenId);

    event MintedPosition(uint256 indexed tokenId, address indexed recipient, uint256 amount0Used, uint256 amount1Used);

    event DustRefunded(address indexed user, address indexed token, uint256 amount);

    function rebalance(uint256 tokenId, RebalanceParams calldata params) external returns (uint256 newTokenId);
}