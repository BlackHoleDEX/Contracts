// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@cryptoalgebra/integral-core/contracts/interfaces/IERC20Minimal.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import "@cryptoalgebra/integral-farming/contracts/interfaces/IFarmingCenter.sol";
import "@cryptoalgebra/integral-farming/contracts/base/IncentiveKey.sol";
import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

library FarmingExitLib {

    function exitAndClaim(IFarmingCenter farmingCenter, uint256 tokenId, address recipient) internal {
        bytes32 incentiveId = farmingCenter.deposits(tokenId);
        if (incentiveId == bytes32(0)) return;

        (IERC20Minimal rewardToken, IERC20Minimal bonusToken, IAlgebraPool pool, uint256 nonce) =
            farmingCenter.incentiveKeys(incentiveId);

        IncentiveKey memory key = IncentiveKey(rewardToken, bonusToken, pool, nonce);

        (uint256 reward, uint256 bonusReward) = farmingCenter.collectRewards(key, tokenId);

        farmingCenter.exitFarming(key, tokenId);

        farmingCenter.claimReward(rewardToken, recipient, reward);
        if (address(bonusToken) != address(0) && bonusReward > 0) {
            farmingCenter.claimReward(bonusToken, recipient, bonusReward);
        }
    }

    /// @notice Exits farming, decreases liquidity, collects tokens, then burns the NFT if no liquidity left or returns it to sender.
    /// @param sender The address that sent the NFT to the contract. If it's complete withdrawal, claim emission in sender's account.
    /// @param recipient The address that received the tokens and will receive the NFT back after rebalance. If it's complete withdrawal, it will receive the NFT.
    function unstakeAndWithdraw(
        IFarmingCenter farmingCenter,
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address sender,
        uint256 deadline
    ) internal {
        uint128 addedLiquidity;
        (,,,,,,, addedLiquidity,,,,) = nfpm.positions(tokenId);
        if (addedLiquidity == liquidity) {
            exitAndClaim(farmingCenter, tokenId, sender);
        }
        decreaseLiquidityCollectAndFinalize(nfpm, tokenId, liquidity, amount0Min, amount1Min, recipient, sender, deadline);
    }

    /// @notice Decreases liquidity, collects tokens, then burns the NFT if no liquidity left or transfers it to nftReturnTo.
    /// @return token0 The position's token0 address (from positions() before decrease).
    /// @return token1 The position's token1 address (from positions() before decrease).
    function decreaseLiquidityCollectAndFinalize(
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address nftReturnTo,
        uint256 deadline
    ) internal returns (address token0, address token1) {
        (,, token0, token1,,,,,,,,) = nfpm.positions(tokenId);

        nfpm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        nfpm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint128 liquidityPositionAfter;
        (,,,,,,, liquidityPositionAfter,,,,) = nfpm.positions(tokenId);

        if (liquidityPositionAfter == 0) {
            nfpm.burn(tokenId);
        } else if (nftReturnTo != address(0)) {
            nfpm.safeTransferFrom(address(this), nftReturnTo, tokenId);
        }
    }
}
