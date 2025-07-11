// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IGaugeFactory {
    function createGauge(address _rewardToken,address _ve,address _token,address _distribution, address _internal_bribe, address _external_bribe, bool _isPair, address _genesisManager) external returns (address) ;
    function gauges(uint256 i) external view returns(address);
    function length() external view returns(uint);
}
