// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@cryptoalgebra/integral-farming/contracts/interfaces/IFarmingCenter.sol";
import "./interfaces/ICLRebalancer.sol";
import "./libraries/FarmingExitLib.sol";
import "./interfaces/IZapRouterHelper.sol";
import "./interfaces/IRouter.sol";
import {Zap} from "./libraries/zap.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/*//////////////////////////////////////////////////////////////
                            ROUTER
//////////////////////////////////////////////////////////////*/

interface IRouterSwap {
    function zapToSingleToken(IZapRouterHelper.ZapToSingleTokenParams calldata params) external returns (uint256 amountOut);

    function mintCLAndStake(INonfungiblePositionManager.MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/*//////////////////////////////////////////////////////////////
                        CL REBALANCER
//////////////////////////////////////////////////////////////*/

contract CLRebalancer is ICLRebalancer, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    INonfungiblePositionManager public immutable nfpm;
    IRouterSwap public immutable router;
    IFarmingCenter public immutable farmingCenter;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _nfpm, address _router, address _farmingCenter) {
        require(_nfpm != address(0), "NFPM_ZERO_ADDRESS");
        require(_router != address(0), "ROUTER_ZERO_ADDRESS");
        require(_farmingCenter != address(0), "FARMING_CENTER_ZERO_ADDRESS");

        nfpm = INonfungiblePositionManager(_nfpm);
        router = IRouterSwap(_router);
        farmingCenter = IFarmingCenter(_farmingCenter);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _withdrawAndBurn(uint256 tokenId, address recipient, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        internal
        returns (address token0, address token1)
    {
        uint128 liquidity;
        (,,token0,token1,,,, liquidity,,,,) = nfpm.positions(tokenId);

        require(liquidity > 0, "NO_LIQUIDITY");

        FarmingExitLib.unstakeAndWithdraw(
            farmingCenter, nfpm, tokenId, liquidity, amount0Min, amount1Min, recipient, msg.sender, deadline);
    }

    /*//////////////////////////////////////////////////////////////
                        USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function rebalance(uint256 tokenId, RebalanceParams calldata params) external nonReentrant returns (uint256 newTokenId) {
        nfpm.safeTransferFrom(msg.sender, address(this), tokenId);
        (address token0, address token1) =
            _withdrawAndBurn(tokenId, address(this), params.decreaseAmount0Min, params.decreaseAmount1Min, params.deadline);

        INonfungiblePositionManager.MintParams memory mintParams = params.mintParams;

        require(mintParams.token0 == token0 && mintParams.token1 == token1, "MINT_TOKENS_MISMATCH");

        _trySwap(params);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        mintParams.amount0Desired = balance0 < mintParams.amount0Desired ? balance0 : mintParams.amount0Desired;

        mintParams.amount1Desired = balance1 < mintParams.amount1Desired ? balance1 : mintParams.amount1Desired;

        uint256 amount0Used;
        uint256 amount1Used;
        IERC20(mintParams.token0).forceApprove(address(router), mintParams.amount0Desired);
        IERC20(mintParams.token1).forceApprove(address(router), mintParams.amount1Desired);

        (newTokenId,, amount0Used, amount1Used) = router.mintCLAndStake(mintParams);

        IERC20(mintParams.token0).forceApprove(address(router), 0);
        IERC20(mintParams.token1).forceApprove(address(router), 0);

        emit MintedPosition(newTokenId, mintParams.recipient, amount0Used, amount1Used);

        uint256 leftover0 = IERC20(token0).balanceOf(address(this));
        uint256 leftover1 = IERC20(token1).balanceOf(address(this));

        if (leftover0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, leftover0);
            emit DustRefunded(msg.sender, token0, leftover0);
        }

        if (leftover1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, leftover1);
            emit DustRefunded(msg.sender, token1, leftover1);
        }

        emit PositionRebalanced(tokenId, newTokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL UTILS
    //////////////////////////////////////////////////////////////*/

    function _validateSwapRoutes(RebalanceParams calldata params, address tokenIn, address outputToken) internal pure {
        // Validate all swaps have consistent input and output tokens
        for (uint256 i = 0; i < params.swaps.length; i++) {
            Zap.Swap memory swap = params.swaps[i];
            require(swap.routes.length > 0, "EMPTY_ROUTES");
            
            // Check first route's from matches inputToken
            require(swap.routes[0].from == tokenIn, "INVALID_INPUT_TOKEN");
            
            // Check last route's to matches outputToken
            require(swap.routes[swap.routes.length - 1].to == outputToken, "INVALID_OUTPUT_TOKEN");
        }

        require(tokenIn != outputToken, "SAME_TOKEN");

        // Validate inputToken matches one of mintParams tokens
        require(
            tokenIn == params.mintParams.token0 || tokenIn == params.mintParams.token1,
            "INPUT_NOT_IN_MINT_PARAMS"
        );

        // Validate outputToken matches one of mintParams tokens
        require(
            outputToken == params.mintParams.token0 || outputToken == params.mintParams.token1,
            "OUTPUT_NOT_IN_MINT_PARAMS"
        );
    }

    function _trySwap(RebalanceParams calldata params) internal {
        if (params.swaps.length == 0) return;

        address tokenIn = params.swaps[0].routes[0].from;
        address outputToken = params.swaps[0].routes[params.swaps[0].routes.length - 1].to;

        _validateSwapRoutes(params, tokenIn, outputToken);

        IERC20(tokenIn).forceApprove(address(router), params.swapAmountIn);
        address[] memory inputTokensZap = new address[](1);
        inputTokensZap[0] = tokenIn;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = params.swapAmountIn;

        router.zapToSingleToken(
            IZapRouterHelper.ZapToSingleTokenParams({
                inputTokens: inputTokensZap,
                amounts: amounts,
                outputToken: outputToken,
                swaps: params.swaps,
                minAmountOut: params.swapAmountOutMin,
                unwrapWETH: false,
                usenative: false,
                deadline: params.deadline,
                to: address(this)
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}