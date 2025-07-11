// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import './libraries/Math.sol';
import './interfaces/IERC20.sol';
import './interfaces/IRewardsDistributor.sol';
import './AVM/interfaces/IAutoVotingEscrowManager.sol';
import './interfaces/IVotingEscrow.sol';
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

/*

@title Curve Fee Distribution modified for ve(3,3) emissions
@author Curve Finance, andrecronje
@license MIT

*/

contract RewardsDistributor is IRewardsDistributor {

    event CheckpointToken(
        uint time,
        uint tokens
    );

    event Claimed(
        uint tokenId,
        uint amount,
        uint claim_epoch,
        uint max_epoch
    );

    uint256 public WEEK;

    uint public start_time;
    uint public time_cursor;
    mapping(uint => uint) public time_cursor_of;

    uint public last_token_time;
    uint[1000000000000000] public tokens_per_week;
    uint public token_last_balance;
    uint[1000000000000000] public ve_supply;

    address public owner;
    address public voting_escrow;
    address public token;
    address public depositor;

    IAutoVotingEscrowManager public avm;

    constructor(address _voting_escrow) {
        WEEK = BlackTimeLibrary.WEEK;
        uint _t = block.timestamp / WEEK * WEEK;
        start_time = _t;
        last_token_time = _t;
        time_cursor = _t;
        address _token = IVotingEscrow(_voting_escrow).token();
        token = _token;
        voting_escrow = _voting_escrow;
        depositor = msg.sender; //0x86069feb223ee303085a1a505892c9d4bdbee996
        owner = msg.sender;
        require(IERC20(_token).approve(_voting_escrow, type(uint).max), "approval failed");
    }

    modifier onlyOwner {
        require(msg.sender == owner, 'not owner');
        _;
    }

    function timestamp() external view returns (uint) {
        return block.timestamp / WEEK * WEEK;
    }

    function _checkpoint_token() internal {
        uint token_balance = IERC20(token).balanceOf(address(this));
        uint to_distribute = token_balance - token_last_balance;
        token_last_balance = token_balance;

        uint t = last_token_time;
        uint since_last = block.timestamp - t;
        last_token_time = block.timestamp;
        uint this_week = t / WEEK * WEEK;
        uint next_week = 0;

        for (uint i = 0; i < 20; i++) {
            next_week = this_week + WEEK;
            if (block.timestamp < next_week) {
                if (since_last == 0 && block.timestamp == t) {
                    tokens_per_week[this_week] += to_distribute;
                } else {
                    tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last;
                }
                break;
            } else {
                if (since_last == 0 && next_week == t) {
                    tokens_per_week[this_week] += to_distribute;
                } else {
                    tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last;
                }
            }
            t = next_week;
            this_week = next_week;
        }
        emit CheckpointToken(block.timestamp, to_distribute);
    }

    function checkpoint_token() external {
        assert(msg.sender == depositor);
        _checkpoint_token();
    }

    function _find_timestamp_user_epoch(address ve, uint tokenId, uint _timestamp, uint max_user_epoch) internal view returns (uint) {
        uint _min = 0;
        uint _max = max_user_epoch;
        for (uint i = 0; i < 128; i++) {
            if (_min >= _max) break;
            uint _mid = (_min + _max + 2) / 2;
            IVotingEscrow.Point memory pt = IVotingEscrow(ve).user_point_history(tokenId, _mid);
            if (pt.ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid -1;
            }
        }
        return _min;
    }

    function _claim(uint _tokenId, address ve, uint _last_token_time) internal returns (uint) {
        uint to_distribute = 0;

        uint max_user_epoch = IVotingEscrow(ve).user_point_epoch(_tokenId);
        uint _start_time = start_time;

        if (max_user_epoch == 0) return 0;

        uint week_cursor = time_cursor_of[_tokenId];
        if (week_cursor == 0) {
            IVotingEscrow.Point memory user_point = IVotingEscrow(ve).user_point_history(_tokenId, 1);
            week_cursor = user_point.ts / WEEK * WEEK;
        }

        if (week_cursor >= last_token_time) return 0;
        if (week_cursor < _start_time) week_cursor = _start_time;

        uint supply;

        for (uint i = 0; i < 50; i++) {
            if (week_cursor >= _last_token_time) break;
            uint balance_of = IVotingEscrow(ve).balanceOfNFTAt(_tokenId, week_cursor + WEEK - 1);
            supply = IVotingEscrow(ve).totalSupplyAtT(week_cursor + WEEK - 1);
            supply = supply == 0 ? 1 : supply;
            to_distribute += balance_of * tokens_per_week[week_cursor] / supply;
            week_cursor += WEEK;
        }
        time_cursor_of[_tokenId] = week_cursor;

        emit Claimed(_tokenId, to_distribute, week_cursor, max_user_epoch);

        return to_distribute;
    }

    function _claimable(uint _tokenId, address ve, uint _last_token_time) internal view returns (uint) {
        uint to_distribute = 0;

        uint max_user_epoch = IVotingEscrow(ve).user_point_epoch(_tokenId);
        uint _start_time = start_time;

        if (max_user_epoch == 0) return 0;

        uint week_cursor = time_cursor_of[_tokenId];
        if (week_cursor == 0) {
            IVotingEscrow.Point memory user_point = IVotingEscrow(ve).user_point_history(_tokenId, 1);
            week_cursor = user_point.ts / WEEK * WEEK;
        }

        if (week_cursor >= last_token_time) return 0;
        if (week_cursor < _start_time) week_cursor = _start_time;
        uint supply;

        for (uint i = 0; i < 50; i++) {
            if (week_cursor >= _last_token_time) break;
            uint balance_of = IVotingEscrow(ve).balanceOfNFTAt(_tokenId, week_cursor + WEEK - 1);
            supply = IVotingEscrow(ve).totalSupplyAtT(week_cursor + WEEK - 1);
            supply = supply == 0 ? 1 : supply;
            to_distribute += balance_of * tokens_per_week[week_cursor] / supply;
            week_cursor += WEEK;
        }

        return to_distribute;
    }

    function claimable(uint _tokenId) external view returns (uint) {
        uint _last_token_time = last_token_time / WEEK * WEEK;
        return _claimable(_tokenId, voting_escrow, _last_token_time);
    }

    function claim(uint256 _tokenId) external returns (uint256) {
        uint _last_token_time = last_token_time;
        _last_token_time = _last_token_time / WEEK * WEEK;
        uint amount = _claim(_tokenId, voting_escrow, _last_token_time);
        if (amount != 0) {
            // if locked.end then send directly
            IVotingEscrow.LockedBalance memory _locked = IVotingEscrow(voting_escrow).locked(_tokenId);
            // If lock has expired and is not permanent, transfer tokens directly
            if (_locked.end < block.timestamp && !_locked.isPermanent) {
                address _nftOwner = IVotingEscrow(voting_escrow).ownerOf(_tokenId);
                if (address(avm) != address(0) && avm.tokenIdToAVMId(_tokenId) != 0) {
                    _nftOwner = avm.getOriginalOwner(_tokenId);
                }
                IERC20(token).transfer(_nftOwner, amount);
            } else {
                IVotingEscrow(voting_escrow).deposit_for(_tokenId, amount);
            }
            token_last_balance -= amount;
        }
        return amount;
    }

    function claim_many(uint[] memory _tokenIds) external returns (bool) {
        uint _last_token_time = last_token_time;
        _last_token_time = _last_token_time / WEEK * WEEK;
        address _voting_escrow = voting_escrow;
        uint total = 0;
        uint tokenIdsLen = _tokenIds.length;

        for (uint i = 0; i < tokenIdsLen; i++) {
            uint _tokenId = _tokenIds[i];
            if (_tokenId == 0) break;
            uint amount = _claim(_tokenId, _voting_escrow, _last_token_time);
            if (amount != 0) {
                // if locked.end then send directly
                IVotingEscrow.LockedBalance memory _locked = IVotingEscrow(_voting_escrow).locked(_tokenId);
                if(_locked.end < block.timestamp && !_locked.isPermanent){
                    address _nftOwner = IVotingEscrow(_voting_escrow).ownerOf(_tokenId);
                    if (address(avm) != address(0) && avm.tokenIdToAVMId(_tokenId) != 0) {
                        _nftOwner = avm.getOriginalOwner(_tokenId);
                    }
                    IERC20(token).transfer(_nftOwner, amount);
                } else {
                    IVotingEscrow(_voting_escrow).deposit_for(_tokenId, amount);
                }
                total += amount;
            }
        }
        if (total != 0) {
            token_last_balance -= total;
        }

        return true;
    }

    function setDepositor(address _depositor) external {
        require(msg.sender == owner);
        depositor = _depositor;
    }

    function setOwner(address _owner) external {
        require(msg.sender == owner);
        owner = _owner;
    }

    function withdrawERC20(address _token) external {
        require(msg.sender == owner);
        require(_token != address(0));
        uint256 _balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(msg.sender, _balance);
    }

    function setAVM(address _avm) external onlyOwner {
        require(_avm != address(0), "ZA");
        avm = IAutoVotingEscrowManager(_avm);
    }
}
