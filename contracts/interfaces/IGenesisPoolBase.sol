// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IGenesisPoolBase {
    struct TokenAllocation {
        uint256 proposedNativeAmount;
        uint256 proposedFundingAmount;
        uint256 allocatedNativeAmount;
        uint256 allocatedFundingAmount;

        uint256 refundableNativeAmount;
    }

    struct TokenIncentiveInfo{
        address[] incentivesToken;
        uint256[] incentivesAmount;
    }

    struct GenesisInfo{
        address tokenOwner;
        address nativeToken;
        address fundingToken;
        bool stable;
        uint256 duration;
        uint256 threshold; // multiplied by 100 to support 2 decimals
        uint256 supplyPercent; 
        uint256 startPrice;
        uint256 startTime;
        uint256 maturityTime;
    }

    struct LiquidityPool {
        address pairAddress;
        address gaugeAddress;
        address internal_bribe;
        address external_bribe;
    }

    enum PoolStatus{
        DEFAULT,
        NATIVE_TOKEN_DEPOSITED,
        PRE_LISTING,
        PRE_LAUNCH,
        PRE_LAUNCH_DEPOSIT_DISABLED,
        LAUNCH,
        PARTIALLY_LAUNCHED,
        NOT_QUALIFIED
    }
}