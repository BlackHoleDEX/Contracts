// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.13;

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {BlackTimeLibrary} from "./BlackTimeLibrary.sol";

library VotingBalanceLogic {

    struct Data {
        mapping(uint => IVotingEscrow.Point) point_history;
        mapping(uint => uint) user_point_epoch;
        mapping(uint => IVotingEscrow.Point[1000000000]) user_point_history; // user -> Point[user_epoch]
    }

    /// @notice Get the current voting power for `_tokenId`
    /// @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    /// @param _tokenId NFT for lock
    /// @param _t Epoch time to return voting power at
    /// @return User voting power
    function balanceOfNFT(uint _tokenId, uint _t, 
        Data storage VotingBalanceLogicData
        ) external view returns (uint) {
        uint _epoch = VotingBalanceLogicData.user_point_epoch[_tokenId];
        if (_epoch == 0) {
            return 0;
        } else {
            uint userEpoch = getPastUserPointIndex(_epoch, _tokenId, _t, VotingBalanceLogicData);
            IVotingEscrow.Point memory last_point = VotingBalanceLogicData.user_point_history[_tokenId][userEpoch];
            if (last_point.smNFT != 0){
                return last_point.smNFT + last_point.smNFTBonus;
            }
            else if (last_point.permanent != 0) {
                return last_point.permanent;
            }
            else {
                last_point.bias -= last_point.slope * int128(int256(_t) - int256(last_point.ts));
                if (last_point.bias < 0) {
                    last_point.bias = 0;
                }
                return uint(int256(last_point.bias));
            }
        }
    }


    function getPastUserPointIndex(uint _epoch, 
    uint _tokenId,
    uint _t,
    Data storage votingBalanceLogicData
    ) internal view returns (uint256){
        uint lower = 0;
        uint upper = _epoch;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            IVotingEscrow.Point memory userPoint = votingBalanceLogicData.user_point_history[_tokenId][center];
            if (userPoint.ts == _t) {
                return center;
            } else if (userPoint.ts < _t) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    /// @notice Measure voting power of `_tokenId` at block height `_block`
    /// @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
    /// @param _tokenId User's wallet NFT
    /// @param _block Block to calculate the voting power at
    /// @return Voting power
    function balanceOfAtNFT(uint _tokenId, 
        uint _block,
        Data storage VotingBalanceLogicData,
        uint epoch
        ) external view returns (uint) {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        assert(_block <= block.number);

        // Binary search
        uint _min = 0;
        uint _max = VotingBalanceLogicData.user_point_epoch[_tokenId];
        for (uint i = 0; i < 128; ++i) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint _mid = (_min + _max + 1) / 2;
            if (VotingBalanceLogicData.user_point_history[_tokenId][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        IVotingEscrow.Point memory upoint = VotingBalanceLogicData.user_point_history[_tokenId][_min];

        if (upoint.permanent > 0){
            return upoint.permanent;
        }
        else if(upoint.smNFT > 0){
            return upoint.smNFT + upoint.smNFTBonus;
        }

        uint max_epoch = epoch;
        uint _epoch = _find_block_epoch(_block, max_epoch, VotingBalanceLogicData);
        IVotingEscrow.Point memory point_0 = VotingBalanceLogicData.point_history[_epoch];
        uint d_block = 0;
        uint d_t = 0;
        if (_epoch < max_epoch) {
            IVotingEscrow.Point memory point_1 = VotingBalanceLogicData.point_history[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint block_time = point_0.ts;
        if (d_block != 0) {
            block_time += (d_t * (_block - point_0.blk)) / d_block;
        }

        upoint.bias -= upoint.slope * int128(int256(block_time - upoint.ts));
        if (upoint.bias >= 0) {
            return uint(uint128(upoint.bias));
        } else {
            return 0;
        }
    }

    function totalSupplyAt(uint _block, uint epoch,
        Data storage VotingBalanceLogicData,
        mapping(uint => int128) storage slope_changes) public view returns (uint) {
        assert(_block <= block.number);
        uint _epoch = epoch;
        uint target_epoch = _find_block_epoch(_block, _epoch, VotingBalanceLogicData);

        IVotingEscrow.Point memory point = VotingBalanceLogicData.point_history[target_epoch];
        uint dt = 0;
        if (target_epoch < _epoch) {
            IVotingEscrow.Point memory point_next = VotingBalanceLogicData.point_history[target_epoch + 1];
            if (point.blk != point_next.blk) {
                dt = ((_block - point.blk) * (point_next.ts - point.ts)) / (point_next.blk - point.blk);
            }
        } else {
            if (point.blk != block.number) {
                dt = ((_block - point.blk) * (block.timestamp - point.ts)) / (block.number - point.blk);
            }
        }
        // Now dt contains info on how far are we beyond point
        return _supply_at(point, point.ts + dt, slope_changes);

    }

         /// @notice Binary search to estimate timestamp for block number
    /// @param _block Block to find
    /// @param max_epoch Don't go beyond this epoch
    /// @return Approximate timestamp for block
    function _find_block_epoch(uint _block, 
        uint max_epoch,
        Data storage VotingBalanceLogicData
        ) internal view returns (uint) {
        // Binary search
        uint _min = 0;
        uint _max = max_epoch;
        for (uint i = 0; i < 128; ++i) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint _mid = (_min + _max + 1) / 2;
            if (VotingBalanceLogicData.point_history[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    /// @notice Calculate total voting power at some point in the past
    /// @param point The point (bias/slope) to start search from
    /// @param t Time to calculate the total voting power at
    /// @return Total voting power at that time
    function _supply_at(IVotingEscrow.Point memory point, 
        uint t,
        mapping(uint => int128) storage slope_changes) internal view returns (uint) {
        uint WEEK = BlackTimeLibrary.WEEK;
        IVotingEscrow.Point memory last_point = point;
        uint t_i = (last_point.ts / WEEK) * WEEK;
        for (uint i = 0; i < 255; ++i) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }
            last_point.bias -= last_point.slope * int128(int256(t_i - last_point.ts));
            if (t_i == t) {
                break;
            }
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            last_point.bias = 0;
        }
        return uint(uint128(last_point.bias)) + last_point.permanent + last_point.smNFT + last_point.smNFTBonus;
    }

    function getPastGlobalPointIndex(uint _epoch,
        uint _t,
        Data storage VotingBalanceLogicData) internal view returns (uint256){
        uint lower = 0;
        uint upper = _epoch;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            IVotingEscrow.Point memory point = VotingBalanceLogicData.point_history[center];
            if (point.ts == _t) {
                return center;
            } else if (point.ts < _t) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

        /// @notice Calculate total voting power
    /// @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
    /// @return Total voting power
    function totalSupplyAtT(uint t, uint epoch,
        mapping(uint => int128) storage slope_changes,
        Data storage VotingBalanceLogicData) external view returns (uint) {
        uint _epoch = epoch;
        if(_epoch == 0) {
            return 0;
        } else {
            uint globalEpoch = getPastGlobalPointIndex(_epoch, t, VotingBalanceLogicData);
            IVotingEscrow.Point memory last_point = VotingBalanceLogicData.point_history[globalEpoch];
            return _supply_at(last_point, t, slope_changes);
        }
    }
}