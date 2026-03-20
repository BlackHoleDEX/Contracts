// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IRouter.sol";
import "./Errors.sol";

library Zap {
    using SafeERC20 for IERC20;
    /**
     * @dev Performs a zap conversion from multiple input ERC-20 tokens to multiple output ERC-20 tokens using provided swap routes.
     * Routes are calculated off-chain to achieve desired output ratios, allowing for multi-hop and mixed pool types.
     * Assumes address(this) already holds the input tokens; performs swaps to this contract, checks total min outputs.
     * If callbackData is provided (length > 0), executes a low-level call to address(this) with the callbackData (e.g., for depositing outputs).
     * Finally, cleans up by transferring any remaining balances of input and output tokens to dustRecipient.
     */
    struct Swap {
        bool feeOnTransfer;
        uint256 amountIn;
        uint256 amountOutMin; // Minimum output for this specific swap
        IRouter.route[] routes;
    }

    function execute(
        address routerAddr,
        Swap[] memory swaps,
        address[] memory outputTokens,
        uint deadline,
        bytes memory callbackData,
        address recipient
    ) internal {
        if (swaps.length == 0) revert NS();

        uint256[] memory startingBalance = new uint256[](outputTokens.length);
        for (uint256 i = 0; i < outputTokens.length; i++) {
            startingBalance[i] = IERC20(outputTokens[i]).balanceOf(address(this));
        }

        // Perform each swap
        for (uint256 i = 0; i < swaps.length; i++) {
            Swap memory s = swaps[i];
            if (s.routes.length == 0) revert ER();
            if (!_contains(outputTokens, s.routes[s.routes.length - 1].to)) revert IOT();

            // Copy routes to memory and override last receiver
            IRouter.route[] memory routesMem = new IRouter.route[](s.routes.length);
            for (uint256 j = 0; j < s.routes.length; j++) {
                routesMem[j] = s.routes[j];
            }
            routesMem[s.routes.length - 1].receiver = address(this);

            // Execute swap
            address inputToken = s.routes[0].from;
            IERC20(inputToken).forceApprove(routerAddr, type(uint256).max);
            if(!s.feeOnTransfer) {
                IRouter(routerAddr).swapExactTokensForTokens(s.amountIn, s.amountOutMin, routesMem, address(this), deadline);
            } else {
                IRouter(routerAddr).swapExactTokensForTokensSupportingFeeOnTransferTokens(s.amountIn, s.amountOutMin, routesMem, address(this), deadline);
            }
            IERC20(inputToken).forceApprove(routerAddr, 0);
        }

        // Only execute callback if callbackData is provided
        if (callbackData.length > 0) {
            (bool success, bytes memory returndata) = address(this).call(callbackData);
            if (!success) {
                if (returndata.length == 0) revert CF();
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
        }

        // Cleanup: transfer remaining balances to dustRecipient
        for (uint256 i = 0; i < outputTokens.length; i++) {
            address token = outputTokens[i];
            // Skip non-contract addresses to avoid calling non-existent functions
            if (token.code.length == 0) continue;
            uint256 current = IERC20(token).balanceOf(address(this));
            uint256 balance = current > startingBalance[i] ? current - startingBalance[i] : 0;
            if (balance > 0) {
                _safeTransfer(token, recipient, balance);
            }
        }
    }

    function _contains(address[] memory arr, address t) private pure returns (bool) {
        uint256 l = arr.length;
        for (uint256 i = 0; i < l; i++) {
            if (arr[i] == t) return true;
        }
        return false;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        if (token.code.length == 0) revert CL();
        (bool success, bytes memory data) =
        token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert IST();
    }
}