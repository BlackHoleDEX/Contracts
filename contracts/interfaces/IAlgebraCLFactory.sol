// SPDX-License-Identifier: GPL-3.0-or-later
// BlackHole Foundation 2025

pragma solidity 0.8.13;

import { IAlgebraFactory } from '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraFactory.sol';

interface IAlgebraCLFactory is IAlgebraFactory{
    function allPairsLength() external view returns (uint);
    function allPairs(uint256 index) external view returns (address);
}