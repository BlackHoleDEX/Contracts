// SPDX-License-Identifier: GPL-3.0-or-later
// BlackHole Foundation 2025

pragma solidity 0.8.13;

import { IAlgebraCommunityVault } from '@cryptoalgebra/integral-core/contracts/interfaces/vault/IAlgebraCommunityVault.sol';

interface IAlgebraCustomCommunityVault is IAlgebraCommunityVault {
    function algebraFee() external view returns (uint16);
}
