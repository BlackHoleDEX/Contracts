// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import '@cryptoalgebra/integral-farming/contracts/base/IncentiveKey.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IAlgebraEternalFarming.sol';

interface IAlgebraEternalFarmingCustom {
  function createEternalFarming(
    IncentiveKey memory key,
    IAlgebraEternalFarming.IncentiveParams memory params,
    address plugin,
    address deployer
  ) external returns (address virtualPool);

  function deactivateIncentive(IncentiveKey memory key, address deployer) external;

  function getRewardInfo(IncentiveKey memory key, uint256 tokenId) external view returns (uint256 reward, uint256 bonusReward);

}