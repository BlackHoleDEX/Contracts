// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IVotingEscrow {

    struct Point {
        int128 bias;
        int128 slope; // # -dweight / dt
        uint256 ts;
        uint256 blk; // block
        uint256 permanent;
        uint smNFT;
        uint smNFTBonus;
    }

    struct LockedBalance {
        int128 amount;
        uint end;
        bool isPermanent;
        bool isSMNFT;
    }

    function create_lock_for(uint _value, uint _lock_duration, address _to, bool isSMSFT) external returns (uint);

    function locked(uint id) external view returns(LockedBalance memory);
    function tokenOfOwnerByIndex(address _owner, uint _tokenIndex) external view returns (uint);

    function token() external view returns (address);
    function team() external returns (address);
    function epoch() external view returns (uint);
    function point_history(uint loc) external view returns (Point memory);
    function user_point_history(uint tokenId, uint loc) external view returns (Point memory);
    function permanentLockBalance() external view returns (uint256);
    function user_point_epoch(uint tokenId) external view returns (uint);

    function ownerOf(uint) external view returns (address);
    function isApprovedOrOwner(address, uint) external view returns (bool);
    function transferFrom(address, address, uint) external;

    function voted(uint) external view returns (bool);
    function attachments(uint) external view returns (uint);
    function voting(uint tokenId) external;
    function abstain(uint tokenId) external;
    function attach(uint tokenId) external;
    function detach(uint tokenId) external;
    function approve(address _approved, uint _tokenId) external;

    function checkpoint() external;
    function deposit_for(uint tokenId, uint value) external;

    function balanceOfNFT(uint _id) external view returns (uint);
    function balanceOfNFTAt(uint _tokenId, uint _t) external view returns (uint);
    function balanceOf(address _owner) external view returns (uint);
    function totalSupply() external view returns (uint);
    function totalSupplyAtT(uint256 _t) external view returns (uint);
    function supply() external view returns (uint);

    function avm() external view returns (address);

    function decimals() external view returns(uint8);


    function lockPermanent(uint _tokenId) external;

    function unlockPermanent(uint _tokenId) external;

    function smNFTBalance() external view returns (uint);
    function calculate_sm_nft_bonus(uint amount) external view returns (uint);
    function calculate_original_sm_nft_amount(uint amount) external view returns (uint);
    function split(uint _from, uint _amount) external returns (uint256 _tokenId1, uint256 _tokenId2);
    function setArtProxy(address _proxy) external;
    function setVoter(address _voter) external;
    function setAVM(address _avm) external;
    function setSmNFTBonus(uint _bonus) external;
    function setTeam(address _team) external;
    function toggleSplit(address _account, bool _bool) external;
}
