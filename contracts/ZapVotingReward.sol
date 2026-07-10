// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IZapRouterHelper.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IZapVotingReward.sol";
import {Zap} from "./libraries/zap.sol";

/*//////////////////////////////////////////////////////////////
                        EXTERNAL INTERFACES
//////////////////////////////////////////////////////////////*/

interface IRouterZap {
    function zapToSingleToken(IZapRouterHelper.ZapToSingleTokenParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface IGaugeManagerBribes {
    function claimBribes(address[] memory _bribes, address[][] memory _tokens, uint256 _tokenId) external;
}

/*//////////////////////////////////////////////////////////////
                          ZAP VOTING REWARD
//////////////////////////////////////////////////////////////*/

/// @notice Claims a veNFT's voting (bribe) rewards and zaps them into a single output token in one call.
/// @dev    Bribes are always paid to `ve.ownerOf(tokenId)` (see Bribes.getReward), and a lock that has
///         voted cannot be transferred, so — unlike CLRebalancer — this contract cannot take custody of
///         the veNFT. Instead the caller (who must be the lock owner) grants:
///           1. a veNFT approval, so this contract can trigger GaugeManager.claimBribes; and
///           2. an ERC20 allowance on each reward token the caller wants zapped; tokens with
///              insufficient allowance are left in the owner's wallet after claiming.
///         Only the exact claimed delta is pulled (snapshot before/after the claim), so pre-existing
///         balances in the owner's wallet are never touched.
contract ZapVotingReward is IZapVotingReward, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IGaugeManagerBribes public immutable gaugeManager;
    IRouterZap public immutable router;
    IVotingEscrow public immutable ve;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _gaugeManager, address _router, address _ve) {
        require(_gaugeManager != address(0), "GAUGE_MANAGER_ZERO_ADDRESS");
        require(_router != address(0), "ROUTER_ZERO_ADDRESS");
        require(_ve != address(0), "VE_ZERO_ADDRESS");

        gaugeManager = IGaugeManagerBribes(_gaugeManager);
        router = IRouterZap(_router);
        ve = IVotingEscrow(_ve);
    }

    /*//////////////////////////////////////////////////////////////
                            USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function zapVotingRewards(ZapVotingRewardParams calldata params)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(params.bribes.length == params.tokens.length, "LENGTH_MISMATCH");
        require(params.outputToken != address(0), "OUTPUT_ZERO_ADDRESS");
        // Bribes are sent to the lock owner; the caller must be that owner so the pull-back
        // only ever moves the caller's own freshly-claimed rewards.
        require(ve.ownerOf(params.tokenId) == msg.sender, "NOT_OWNER");

        // 1. Flatten & dedupe the reward token set across all bribes.
        address[] memory rewardTokens = _flattenUnique(params.tokens);
        require(rewardTokens.length > 0, "NO_REWARD_TOKENS");
        if (_needsSwap(rewardTokens, params.outputToken)) {
            require(params.swaps.length > 0, "EMPTY_SWAPS");
        }

        // 2. Snapshot the owner's balances before claiming.
        uint256[] memory beforeBal = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            beforeBal[i] = IERC20(rewardTokens[i]).balanceOf(msg.sender);
        }

        // 3. Claim bribes — rewards land in the owner's (caller's) wallet.
        gaugeManager.claimBribes(params.bribes, params.tokens, params.tokenId);

        // 4. Pull exactly the claimed delta of each token into this contract.
        //    Rewards already in the output token stay in the owner's wallet (no pull/swap).
        //    amounts[] is set from the contract's actual received balance, so fee-on-transfer
        //    tokens are accounted for correctly.
        address[] memory inputTokens = new address[](rewardTokens.length);
        uint256[] memory amounts = new uint256[](rewardTokens.length);
        uint256 count;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 token = IERC20(rewardTokens[i]);

            uint256 afterBal = token.balanceOf(msg.sender);
            uint256 delta = afterBal > beforeBal[i] ? afterBal - beforeBal[i] : 0;
            if (delta == 0) continue;

            if (rewardTokens[i] == params.outputToken) continue;

            uint256 allowance = token.allowance(msg.sender, address(this));
            if (allowance < delta) continue;

            uint256 balBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), delta);
            uint256 received = token.balanceOf(address(this)) - balBefore;
            if (received == 0) continue;

            inputTokens[count] = rewardTokens[i];
            amounts[count] = received;
            count++;
        }
        require(count > 0, "NOTHING_CLAIMED");

        // Shrink the over-allocated arrays down to the tokens actually claimed.
        assembly {
            mstore(inputTokens, count)
            mstore(amounts, count)
        }

        // 5. Drop swaps for tokens that were not pulled (e.g. insufficient allowance).
        Zap.Swap[] memory swaps = _filterSwaps(params.swaps, inputTokens);
        _validateSwaps(swaps, inputTokens, params.outputToken);

        // 6. Approve the router and zap everything into the single output token, sent to the owner.
        for (uint256 i = 0; i < inputTokens.length; i++) {
            IERC20(inputTokens[i]).forceApprove(address(router), amounts[i]);
        }

        amountOut = router.zapToSingleToken(
            IZapRouterHelper.ZapToSingleTokenParams({
                inputTokens: inputTokens,
                amounts: amounts,
                outputToken: params.outputToken,
                swaps: swaps,
                minAmountOut: params.minAmountOut,
                unwrapWETH: params.unwrapWETH,
                usenative: false,
                deadline: params.deadline,
                to: msg.sender
            })
        );

        // 7. Reset approvals and refund any residual reward tokens back to the owner.
        for (uint256 i = 0; i < inputTokens.length; i++) {
            IERC20 token = IERC20(inputTokens[i]);
            token.forceApprove(address(router), 0);
            uint256 leftover = token.balanceOf(address(this));
            if (leftover > 0) {
                token.safeTransfer(msg.sender, leftover);
                emit DustRefunded(msg.sender, inputTokens[i], leftover);
            }
        }

        emit VotingRewardsZapped(msg.sender, params.tokenId, params.outputToken, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL UTILS
    //////////////////////////////////////////////////////////////*/

    /// @dev Keeps only swaps whose input token was actually pulled into this contract.
    function _filterSwaps(Zap.Swap[] calldata swaps, address[] memory inputTokens)
        internal
        pure
        returns (Zap.Swap[] memory filtered)
    {
        uint256 n;
        for (uint256 i = 0; i < swaps.length; i++) {
            if (swaps[i].routes.length > 0 && _contains(inputTokens, swaps[i].routes[0].from)) {
                n++;
            }
        }

        filtered = new Zap.Swap[](n);
        uint256 j;
        for (uint256 i = 0; i < swaps.length; i++) {
            if (swaps[i].routes.length > 0 && _contains(inputTokens, swaps[i].routes[0].from)) {
                filtered[j] = swaps[i];
                j++;
            }
        }
    }

    /// @dev Validates that every route ends at the output token and every pulled token
    ///      (other than the output token itself) has a route.
    function _validateSwaps(Zap.Swap[] memory swaps, address[] memory inputTokens, address outputToken)
        internal
        pure
    {
        for (uint256 i = 0; i < swaps.length; i++) {
            require(swaps[i].routes.length > 0, "EMPTY_ROUTES");
            require(swaps[i].routes[swaps[i].routes.length - 1].to == outputToken, "INVALID_OUTPUT_TOKEN");
        }

        for (uint256 i = 0; i < inputTokens.length; i++) {
            if (inputTokens[i] == outputToken) continue;
            bool found;
            for (uint256 j = 0; j < swaps.length; j++) {
                if (swaps[j].routes[0].from == inputTokens[i]) {
                    found = true;
                    break;
                }
            }
            require(found, "MISSING_SWAP_FOR_TOKEN");
        }
    }

    /// @dev Flattens `tokens[][]` into a unique, non-zero list of reward token addresses.
    function _flattenUnique(address[][] calldata tokens) internal pure returns (address[] memory unique) {
        uint256 total;
        for (uint256 i = 0; i < tokens.length; i++) {
            total += tokens[i].length;
        }

        address[] memory buf = new address[](total);
        uint256 n;
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
                address t = tokens[i][j];
                if (t == address(0)) continue;
                if (_contains(buf, t)) continue;
                buf[n] = t;
                n++;
            }
        }

        unique = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            unique[i] = buf[i];
        }
    }

    function _contains(address[] memory arr, address t) private pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == t) return true;
        }
        return false;
    }

    function _needsSwap(address[] memory tokens, address outputToken) private pure returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != outputToken) return true;
        }
        return false;
    }
}
