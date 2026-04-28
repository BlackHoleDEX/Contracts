pragma solidity 0.8.13;

import "@cryptoalgebra/integral-base-plugin/contracts/interfaces/IBasePluginV1Factory.sol";

interface IAlgebraBasePluginV1FactoryCustom is IBasePluginV1Factory{
    function createPluginForExistingCustomPool(address token0, address token1, address customPoolDeployer) external returns (address);
}