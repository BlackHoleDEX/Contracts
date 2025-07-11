// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IAlgebraCustomVaultPoolEntryPoint {

  function setCommunityFee(address pool, uint16 newCommunityFee) external;
}