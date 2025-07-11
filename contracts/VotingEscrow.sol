// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import {IERC721, IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import "./interfaces/IBlack.sol";
import {IBlackHoleVotes} from "./interfaces/IBlackHoleVotes.sol";
import {IVeArtProxy} from "./interfaces/IVeArtProxy.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IAutomatedVotingManager} from "./interfaces/IAutomatedVotingManager.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";
import {VotingDelegationLib} from "./libraries/VotingDelegationLib.sol";
import {VotingBalanceLogic} from "./libraries/VotingBalanceLogic.sol";

/// @title Voting Escrow
/// @notice veNFT implementation that escrows ERC-20 tokens in the form of an ERC-721 NFT
/// @notice Votes have a weight depending on time, so that users are committed to the future of (whatever they are voting for)
/// @author Modified from Solidly (https://github.com/solidlyexchange/solidly/blob/master/contracts/ve.sol)
/// @author Modified from Curve (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
/// @author Modified from Nouns DAO (https://github.com/withtally/my-nft-dao-project/blob/main/contracts/ERC721Checkpointable.sol)
/// @dev Vote weight decays linearly over time. Lock time cannot be more than `MAXTIME` (2 years).
contract VotingEscrow is IERC721, IERC721Metadata, IBlackHoleVotes {
    enum DepositType {
        DEPOSIT_FOR_TYPE,
        CREATE_LOCK_TYPE,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        address indexed provider,
        uint tokenId,
        uint value,
        uint indexed locktime,
        DepositType deposit_type,
        uint ts
    );

    event Merge(
        address indexed _sender,
        uint256 indexed _from,
        uint256 indexed _to,
        uint256 _amountFrom,
        uint256 _amountTo,
        uint256 _amountFinal,
        uint256 _locktime,
        uint256 _ts
    );
    event Split(
        uint256 indexed _from,
        uint256 indexed _tokenId1,
        uint256 indexed _tokenId2,
        address _sender,
        uint256 _splitAmount1,
        uint256 _splitAmount2,
        uint256 _locktime,
        uint256 _ts
    );
    
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    event Withdraw(address indexed provider, uint tokenId, uint value, uint ts);
    event LockPermanent(address indexed _owner, uint256 indexed _tokenId, uint256 amount, uint256 _ts);
    event UnlockPermanent(address indexed _owner, uint256 indexed _tokenId, uint256 amount, uint256 _ts);
    event Supply(uint prevSupply, uint supply);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    address public immutable token;
    address public voter;
    address public team;
    address public artProxy;
    address public avm;
    // address public burnTokenAddress=0x000000000000000000000000000000000000dEaD;

    uint public SMNFT_BONUS = 1000;
    uint public PRECISISON = 10000;

    /// @dev Mapping of interface id to bool about whether or not it's supported
    mapping(bytes4 => bool) internal supportedInterfaces;

    /// @dev ERC165 interface ID of ERC165
    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    /// @dev ERC165 interface ID of ERC721
    bytes4 internal constant ERC721_INTERFACE_ID = 0x80ac58cd;

    /// @dev ERC165 interface ID of ERC721Metadata
    bytes4 internal constant ERC721_METADATA_INTERFACE_ID = 0x5b5e139f;

    /// @dev Current count of token
    uint internal tokenId;

    uint internal WEEK;

    uint internal MAXTIME;
    int128 internal iMAXTIME;
    IBlack public _black;

    // Instance of the library's storage struct
    VotingDelegationLib.Data private cpData;

    VotingBalanceLogic.Data private votingBalanceLogicData;

    /// @notice Contract constructor
    /// @param token_addr `BLACK` token address
    constructor(address token_addr, address art_proxy, address _avm) {
        token = token_addr;
        voter = msg.sender;
        team = msg.sender;
        artProxy = art_proxy;
        avm = _avm;
        WEEK = BlackTimeLibrary.WEEK;
        MAXTIME = BlackTimeLibrary.MAX_LOCK_DURATION;
        iMAXTIME = int128(int256(BlackTimeLibrary.MAX_LOCK_DURATION));

        votingBalanceLogicData.point_history[0].blk = block.number;
        votingBalanceLogicData.point_history[0].ts = block.timestamp;

        supportedInterfaces[ERC165_INTERFACE_ID] = true;
        supportedInterfaces[ERC721_INTERFACE_ID] = true;
        supportedInterfaces[ERC721_METADATA_INTERFACE_ID] = true;
        _black = IBlack(token);

        // mint-ish
        emit Transfer(address(0), address(this), tokenId);
        // burn-ish
        emit Transfer(address(this), address(0), tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev reentrancy guard
    uint8 internal constant _not_entered = 1;
    uint8 internal constant _entered = 2;
    uint8 internal _entered_state = 1;
    modifier nonreentrant() {
        require(_entered_state == _not_entered);
        _entered_state = _entered;
        _;
        _entered_state = _not_entered;
    }

    /*///////////////////////////////////////////////////////////////
                             METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string constant public name = "veBlack";
    string constant public symbol = "veBLACK";
    string constant public version = "1.0.0";
    uint8 constant public decimals = 18;

    function setTeam(address _team) external {
        require(msg.sender == team);
        team = _team;
    }

    function setArtProxy(address _proxy) external {
        require(msg.sender == team);
        artProxy = _proxy;
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @dev Returns current token URI metadata
    /// @param _tokenId Token ID to fetch URI for.
    function tokenURI(uint _tokenId) external view returns (string memory) {
        require(idToOwner[_tokenId] != address(0), "DNE");
        IVotingEscrow.LockedBalance memory _locked = locked[_tokenId];
        
        return IVeArtProxy(artProxy)._tokenURI(_tokenId,VotingBalanceLogic.balanceOfNFT(_tokenId, block.timestamp, votingBalanceLogicData),_locked.end,uint(int256(_locked.amount)), _locked.isSMNFT);
    }

    /*//////////////////////////////////////////////////////////////
                      ERC721 BALANCE/OWNER STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from NFT ID to the address that owns it.
    mapping(uint => address) internal idToOwner;

    /// @dev Mapping from owner address to count of his tokens.
    mapping(address => uint) internal ownerToNFTokenCount;

    /// @dev Returns the address of the owner of the NFT.
    /// @param _tokenId The identifier for an NFT.
    function ownerOf(uint _tokenId) public view returns (address) {
        return idToOwner[_tokenId];
    }

    function ownerToNFTokenCountFn(address owner) public view returns (uint) {
        
        return ownerToNFTokenCount[owner];
    }

    /// @dev Returns the number of NFTs owned by `_owner`.
    ///      Throws if `_owner` is the zero address. NFTs assigned p to the zero address are considered invalid.
    /// @param _owner Address for whom to query the balance.
    function _balance(address _owner) internal view returns (uint) {
        return ownerToNFTokenCount[_owner];
    }

    /// @dev Returns the number of NFTs owned by `_owner`.
    ///      Throws if `_owner` is the zero address. NFTs assigned to the zero address are considered invalid.
    /// @param _owner Address for whom to query the balance.
    function balanceOf(address _owner) external view returns (uint) {
        return _balance(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                         ERC721 APPROVAL STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from NFT ID to approved address.
    mapping(uint => address) internal idToApprovals;

    /// @dev Mapping from owner address to mapping of operator addresses.
    mapping(address => mapping(address => bool)) internal ownerToOperators;

    mapping(uint => uint) public ownership_change;

    /// @dev Get the approved address for a single NFT.
    /// @param _tokenId ID of the NFT to query the approval of.
    function getApproved(uint _tokenId) external view returns (address) {
        return idToApprovals[_tokenId];
    }

    /// @dev Checks if `_operator` is an approved operator for `_owner`.
    /// @param _owner The address that owns the NFTs.
    /// @param _operator The address that acts on behalf of the owner.
    function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
        return (ownerToOperators[_owner])[_operator];
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Set or reaffirm the approved address for an NFT. The zero address indicates there is no approved address.
    ///      Throws unless `msg.sender` is the current NFT owner, or an authorized operator of the current owner.
    ///      Throws if `_tokenId` is not a valid NFT. (NOTE: This is not written the EIP)
    ///      Throws if `_approved` is the current owner. (NOTE: This is not written the EIP)
    /// @param _approved Address to be approved for the given NFT ID.
    /// @param _tokenId ID of the token to be approved.
    function approve(address _approved, uint _tokenId) public {
        address owner = idToOwner[_tokenId];
        // Throws if `_tokenId` is not a valid NFT
        require(owner != address(0), "ZA");
        // Throws if `_approved` is the current owner
        require(_approved != owner, "IA");
        // Check requirements
        bool senderIsOwner = (idToOwner[_tokenId] == msg.sender);
        bool senderIsApprovedForAll = (ownerToOperators[owner])[msg.sender];
        require(senderIsOwner || senderIsApprovedForAll, "NAO");
        // Set the approval
        idToApprovals[_tokenId] = _approved;
        emit Approval(owner, _approved, _tokenId);
    }

    /// @dev Enables or disables approval for a third party ("operator") to manage all of
    ///      `msg.sender`'s assets. It also emits the ApprovalForAll event.
    ///      Throws if `_operator` is the `msg.sender`. (NOTE: This is not written the EIP)
    /// @notice This works even if sender doesn't own any tokens at the time.
    /// @param _operator Address to add to the set of authorized operators.
    /// @param _approved True if the operators is approved, false to revoke approval.
    function setApprovalForAll(address _operator, bool _approved) external {
        // Throws if `_operator` is the `msg.sender`
        assert(_operator != msg.sender);
        ownerToOperators[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    /* TRANSFER FUNCTIONS */
    /// @dev Clear an approval of a given address
    ///      Throws if `_owner` is not the current owner.
    function _clearApproval(address _owner, uint _tokenId) internal {
        // Throws if `_owner` is not the current owner
        assert(idToOwner[_tokenId] == _owner);
        if (idToApprovals[_tokenId] != address(0)) {
            // Reset approvals
            idToApprovals[_tokenId] = address(0);
        }
    }

    /// @dev Returns whether the given spender can transfer a given token ID
    /// @param _spender address of the spender to query
    /// @param _tokenId uint ID of the token to be transferred
    /// @return bool whether the msg.sender is approved for the given token ID, is an operator of the owner, or is the owner of the token
    function _isApprovedOrOwner(address _spender, uint _tokenId) internal view returns (bool) {
        address owner = idToOwner[_tokenId];
        bool spenderIsOwner = owner == _spender;
        bool spenderIsApproved = _spender == idToApprovals[_tokenId];
        bool spenderIsApprovedForAll = (ownerToOperators[owner])[_spender];
        return spenderIsOwner || spenderIsApproved || spenderIsApprovedForAll;
    }

    function isApprovedOrOwner(address _spender, uint _tokenId) external view returns (bool) {
        return _isApprovedOrOwner(_spender, _tokenId);
    }

    /// @dev Exeute transfer of a NFT.
    ///      Throws unless `msg.sender` is the current owner, an authorized operator, or the approved
    ///      address for this NFT. (NOTE: `msg.sender` not allowed in internal function so pass `_sender`.)
    ///      Throws if `_to` is the zero address.
    ///      Throws if `_from` is not the current owner.
    ///      Throws if `_tokenId` is not a valid NFT.
    function _transferFrom(
        address _from,
        address _to,
        uint _tokenId,
        address _sender
    ) internal {
        require(attachments[_tokenId] == 0 && !voted[_tokenId], "ATT");
        // Check requirements
        require(_isApprovedOrOwner(_sender, _tokenId), "NAO");

        // Clear approval. Throws if `_from` is not the current owner
        _clearApproval(_from, _tokenId);
        // Remove NFT. Throws if `_tokenId` is not a valid NFT
        _removeTokenFrom(_from, _tokenId);
        // auto re-delegate
        VotingDelegationLib.moveTokenDelegates(cpData, delegates(_from), delegates(_to), _tokenId, ownerOf);
        // Add NFT
        _addTokenTo(_to, _tokenId);
        // Set the block of ownership transfer (for Flash NFT protection)
        ownership_change[_tokenId] = block.number;

        if (_to == avm) { 
            // dont need additional check on originalOwner mapping
            // Store original owner before AVM takes control
            // used a setter fucntion and exposed that through the method, any ohter better method 
            IAutomatedVotingManager(avm).setOriginalOwner(_tokenId, _from);
        } 
        // Log the transfer
        emit Transfer(_from, _to, _tokenId);
    }

    /// @dev Throws unless `msg.sender` is the current owner, an authorized operator, or the approved address for this NFT.
    ///      Throws if `_from` is not the current owner.
    ///      Throws if `_to` is the zero address.
    ///      Throws if `_tokenId` is not a valid NFT.
    /// @notice The caller is responsible to confirm that `_to` is capable of receiving NFTs or else
    ///        they maybe be permanently lost.
    /// @param _from The current owner of the NFT.
    /// @param _to The new owner.
    /// @param _tokenId The NFT to transfer.
    function transferFrom(
        address _from,
        address _to,
        uint _tokenId
    ) external {
        _transferFrom(_from, _to, _tokenId, msg.sender);
    }

    /// @dev Transfers the ownership of an NFT from one address to another address.
    ///      Throws unless `msg.sender` is the current owner, an authorized operator, or the
    ///      approved address for this NFT.
    ///      Throws if `_from` is not the current owner.
    ///      Throws if `_to` is the zero address.
    ///      Throws if `_tokenId` is not a valid NFT.
    ///      If `_to` is a smart contract, it calls `onERC721Received` on `_to` and throws if
    ///      the return value is not `bytes4(keccak256("onERC721Received(address,address,uint,bytes)"))`.
    /// @param _from The current owner of the NFT.
    /// @param _to The new owner.
    /// @param _tokenId The NFT to transfer.
    function safeTransferFrom(
        address _from,
        address _to,
        uint _tokenId
    ) external {
        safeTransferFrom(_from, _to, _tokenId, "");
    }

    function _isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.
        uint size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /// @dev Transfers the ownership of an NFT from one address to another address.
    ///      Throws unless `msg.sender` is the current owner, an authorized operator, or the
    ///      approved address for this NFT.
    ///      Throws if `_from` is not the current owner.
    ///      Throws if `_to` is the zero address.
    ///      Throws if `_tokenId` is not a valid NFT.
    ///      If `_to` is a smart contract, it calls `onERC721Received` on `_to` and throws if
    ///      the return value is not `bytes4(keccak256("onERC721Received(address,address,uint,bytes)"))`.
    /// @param _from The current owner of the NFT.
    /// @param _to The new owner.
    /// @param _tokenId The NFT to transfer.
    /// @param _data Additional data with no specified format, sent in call to `_to`.
    function safeTransferFrom(
        address _from,
        address _to,
        uint _tokenId,
        bytes memory _data
    ) public {
        _transferFrom(_from, _to, _tokenId, msg.sender);

        if (_isContract(_to)) {
            // Throws if transfer destination is a contract which does not implement 'onERC721Received'
            try IERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data) returns (bytes4 response) {
                if (response != IERC721Receiver(_to).onERC721Received.selector) {
                    revert("E721_RJ");
                }
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert('E721_NRCV');
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Interface identification is specified in ERC-165.
    /// @param _interfaceID Id of the interface
    function supportsInterface(bytes4 _interfaceID) external view returns (bool) {
        return supportedInterfaces[_interfaceID];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from owner address to mapping of index to tokenIds
    mapping(address => mapping(uint => uint)) internal ownerToNFTokenIdList;

    /// @dev Mapping from NFT ID to index of owner
    mapping(uint => uint) internal tokenToOwnerIndex;

    /// @dev  Get token by index
    function tokenOfOwnerByIndex(address _owner, uint _tokenIndex) public view returns (uint) {
        return ownerToNFTokenIdList[_owner][_tokenIndex];
    }

    /// @dev Add a NFT to an index mapping to a given address
    /// @param _to address of the receiver
    /// @param _tokenId uint ID Of the token to be added
    function _addTokenToOwnerList(address _to, uint _tokenId) internal {
        uint current_count = _balance(_to);

        ownerToNFTokenIdList[_to][current_count] = _tokenId;
        tokenToOwnerIndex[_tokenId] = current_count;
    }

    /// @dev Add a NFT to a given address
    ///      Throws if `_tokenId` is owned by someone.
    function _addTokenTo(address _to, uint _tokenId) internal {
        // Throws if `_tokenId` is owned by someone
        assert(idToOwner[_tokenId] == address(0));
        // Change the owner
        idToOwner[_tokenId] = _to;
        // Update owner token index tracking
        _addTokenToOwnerList(_to, _tokenId);
        // Change count tracking
        ownerToNFTokenCount[_to] += 1;
    }

    /// @dev Function to mint tokens
    ///      Throws if `_to` is zero address.
    ///      Throws if `_tokenId` is owned by someone.
    /// @param _to The address that will receive the minted tokens.
    /// @param _tokenId The token id to mint.
    /// @return A boolean that indicates if the operation was successful.
    function _mint(address _to, uint _tokenId) internal returns (bool) {
        // Throws if `_to` is zero address
        assert(_to != address(0));
        // checkpoint for gov
        VotingDelegationLib.moveTokenDelegates(cpData, address(0), delegates(_to), _tokenId, ownerOf);
        // Add NFT. Throws if `_tokenId` is owned by someone
        _addTokenTo(_to, _tokenId);
        emit Transfer(address(0), _to, _tokenId);
        return true;
    }

    /// @dev Remove a NFT from an index mapping to a given address
    /// @param _from address of the sender
    /// @param _tokenId uint ID Of the token to be removed
    function _removeTokenFromOwnerList(address _from, uint _tokenId) internal {
        // Delete
        uint current_count = _balance(_from) - 1;
        uint current_index = tokenToOwnerIndex[_tokenId];

        if (current_count == current_index) {
            // update ownerToNFTokenIdList
            ownerToNFTokenIdList[_from][current_count] = 0;
            // update tokenToOwnerIndex
            tokenToOwnerIndex[_tokenId] = 0;
        } else {
            uint lastTokenId = ownerToNFTokenIdList[_from][current_count];

            // Add
            // update ownerToNFTokenIdList
            ownerToNFTokenIdList[_from][current_index] = lastTokenId;
            // update tokenToOwnerIndex
            tokenToOwnerIndex[lastTokenId] = current_index;

            // Delete
            // update ownerToNFTokenIdList
            ownerToNFTokenIdList[_from][current_count] = 0;
            // update tokenToOwnerIndex
            tokenToOwnerIndex[_tokenId] = 0;
        }
    }

    /// @dev Remove a NFT from a given address
    ///      Throws if `_from` is not the current owner.
    function _removeTokenFrom(address _from, uint _tokenId) internal {
        // Throws if `_from` is not the current owner
        assert(idToOwner[_tokenId] == _from);
        // Change the owner
        idToOwner[_tokenId] = address(0);
        // Update owner token index tracking
        _removeTokenFromOwnerList(_from, _tokenId);
        // Change count tracking
        ownerToNFTokenCount[_from] -= 1;
    }

    function _burn(uint _tokenId) internal {
        require(_isApprovedOrOwner(msg.sender, _tokenId), "NAO");

        address owner = ownerOf(_tokenId);

        // Clear approval
        delete idToApprovals[_tokenId];
        // Remove token
        //_removeTokenFrom(msg.sender, _tokenId);
        _removeTokenFrom(owner, _tokenId);
        // checkpoint for gov
        VotingDelegationLib.moveTokenDelegates(cpData, delegates(owner), address(0), _tokenId, ownerOf);

        emit Transfer(owner, address(0), _tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                             ESCROW STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint => IVotingEscrow.LockedBalance) public locked;
    uint public permanentLockBalance;
    uint public smNFTBalance;
    uint public epoch;
    mapping(uint => int128) public slope_changes; // time -> signed slope change
    uint public supply;
    mapping(address => bool) public canSplit;


    uint internal constant MULTIPLIER = 1 ether;

    /*//////////////////////////////////////////////////////////////
                              ESCROW LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the most recently recorded rate of voting power decrease for `_tokenId`
    /// @param _tokenId token of the NFT
    /// @return Value of the slope
    function get_last_user_slope(uint _tokenId) external view returns (int128) {
        uint uepoch = votingBalanceLogicData.user_point_epoch[_tokenId];
        return votingBalanceLogicData.user_point_history[_tokenId][uepoch].slope;
    }

    /// @notice Get the timestamp for checkpoint `_idx` for `_tokenId`
    /// @param _tokenId token of the NFT
    /// @param _idx User epoch number
    /// @return Epoch time of the checkpoint
    function user_point_history(uint _tokenId, uint _idx) external view returns (IVotingEscrow.Point memory) {
        return votingBalanceLogicData.user_point_history[_tokenId][_idx];
    }

    function point_history(uint epoch) external view returns (IVotingEscrow.Point memory) {
        return votingBalanceLogicData.point_history[epoch];
    }

    function user_point_epoch(uint tokenId) external view returns (uint) {
        return votingBalanceLogicData.user_point_epoch[tokenId];
    }

    /// @notice Record global and per-user data to checkpoint
    /// @param _tokenId NFT token ID. No user checkpoint if 0
    /// @param old_locked Pevious locked amount / end lock time for the user
    /// @param new_locked New locked amount / end lock time for the user
    function _checkpoint(
        uint _tokenId,
        IVotingEscrow.LockedBalance memory old_locked,
        IVotingEscrow.LockedBalance memory new_locked
    ) internal {
        IVotingEscrow.Point memory u_old;
        IVotingEscrow.Point memory u_new;
        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint _epoch = epoch;

        if (_tokenId != 0) {
            u_new.permanent = 0;
            u_new.smNFT = 0;
            u_new.smNFTBonus = 0;

            if(new_locked.isSMNFT){
                u_new.smNFT = calculate_original_sm_nft_amount(uint(int256(new_locked.amount)));
                u_new.smNFTBonus = uint(int256(new_locked.amount)) - u_new.smNFT;
            }
            else if(new_locked.isPermanent){
                u_new.permanent = uint(int256(new_locked.amount));
            }

            // Calculate slopes and biases
            // Kept at zero when they have to
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                u_old.slope = old_locked.amount / iMAXTIME;
                u_old.bias = u_old.slope * int128(int256(old_locked.end - block.timestamp));
            }
            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope = new_locked.amount / iMAXTIME;
                u_new.bias = u_new.slope * int128(int256(new_locked.end - block.timestamp));
            }

            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            old_dslope = slope_changes[old_locked.end];
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) {
                    new_dslope = old_dslope;
                } else {
                    new_dslope = slope_changes[new_locked.end];
                }
            }
        }

        IVotingEscrow.Point memory last_point = IVotingEscrow.Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number, permanent: 0, smNFT : 0, smNFTBonus : 0});
        if (_epoch > 0) {
            last_point = votingBalanceLogicData.point_history[_epoch];
        }
        uint last_checkpoint = last_point.ts;
        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        IVotingEscrow.Point memory initial_last_point = last_point;
        uint block_slope = 0; // dblock/dt
        if (block.timestamp > last_point.ts) {
            block_slope = (MULTIPLIER * (block.number - last_point.blk)) / (block.timestamp - last_point.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        {
            uint t_i = (last_checkpoint / WEEK) * WEEK;
            for (uint i = 0; i < 255; ++i) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += WEEK;
                int128 d_slope = 0;
                if (t_i > block.timestamp) {
                    t_i = block.timestamp;
                } else {
                    d_slope = slope_changes[t_i];
                }
                last_point.bias -= last_point.slope * int128(int256(t_i - last_checkpoint));
                last_point.slope += d_slope;
                if (last_point.bias < 0) {
                    // This can happen
                    last_point.bias = 0;
                }
                if (last_point.slope < 0) {
                    // This cannot happen - just in case
                    last_point.slope = 0;
                }
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
                _epoch += 1;
                if (t_i == block.timestamp) {
                    last_point.blk = block.number;
                    break;
                } else {
                    votingBalanceLogicData.point_history[_epoch] = last_point;
                }
            }
        }

        epoch = _epoch;
        // Now point_history is filled until t=now

        if (_tokenId != 0) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            }
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
            last_point.permanent = permanentLockBalance;
            last_point.smNFT = smNFTBalance;
            last_point.smNFTBonus = calculate_sm_nft_bonus(smNFTBalance);
        }

        // Record the changed point into history
        votingBalanceLogicData.point_history[_epoch] = last_point;

        if (_tokenId != 0) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (old_locked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) {
                    old_dslope -= u_new.slope; // It was a new deposit, not extension
                }
                slope_changes[old_locked.end] = old_dslope;
            }

            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope; // old slope disappeared at this point
                    slope_changes[new_locked.end] = new_dslope;
                }
                // else: we recorded it already in old_dslope
            }
            // Now handle user history
            uint user_epoch = votingBalanceLogicData.user_point_epoch[_tokenId] + 1;

            votingBalanceLogicData.user_point_epoch[_tokenId] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            votingBalanceLogicData.user_point_history[_tokenId][user_epoch] = u_new;
        }
    }

    /// @notice Deposit and lock tokens for a user
    /// @param _tokenId NFT that holds lock
    /// @param _value Amount to deposit
    /// @param unlock_time New time when to unlock the tokens, or 0 if unchanged
    /// @param locked_balance Previous locked amount / timestamp
    /// @param deposit_type The type of deposit
    function _deposit_for(
        uint _tokenId,
        uint _value,
        uint unlock_time,
        IVotingEscrow.LockedBalance memory locked_balance,
        DepositType deposit_type
    ) internal {
        IVotingEscrow.LockedBalance memory _locked = locked_balance;
        uint supply_before = supply;

        supply = supply_before + _value;
        IVotingEscrow.LockedBalance memory old_locked;
        (old_locked.amount, old_locked.end, old_locked.isPermanent, old_locked.isSMNFT) = (_locked.amount, _locked.end, _locked.isPermanent, _locked.isSMNFT);
        // Adding to existing lock, or if a lock is expired - creating a new one
        if(old_locked.isSMNFT) {
            _locked.amount += int128(int256(_value + calculate_sm_nft_bonus(_value)));
        } else {
            _locked.amount += int128(int256(_value));
        }
           
        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_tokenId] = _locked;

        // Possibilities:
        // Both old_locked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(_tokenId, old_locked, _locked);

        address from = msg.sender;
        if (_value != 0) {
            if(old_locked.isSMNFT) {
                // assert(IERC20(token).transferFrom(from, burnTokenAddress, _value));
                assert(_black.burnFrom(from,_value));
            } else {
                assert(IERC20(token).transferFrom(from, address(this), _value));
            }
        }

        emit Deposit(from, _tokenId, _value, _locked.end, deposit_type, block.timestamp);
        emit Supply(supply_before, supply_before + _value);
    }

    /// @notice Record global data to checkpoint
    function checkpoint() external {
        _checkpoint(0, IVotingEscrow.LockedBalance(0, 0, false, false), IVotingEscrow.LockedBalance(0, 0, false, false));
    }

    /// @notice Deposit `_value` tokens for `_tokenId` and add to the lock
    /// @dev Anyone (even a smart contract) can deposit for someone else, but
    ///      cannot extend their locktime and deposit for a brand new user
    /// @param _tokenId lock NFT
    /// @param _value Amount to add to user's lock
    function deposit_for(uint _tokenId, uint _value) external nonreentrant {
        IVotingEscrow.LockedBalance memory _locked = locked[_tokenId];

        require(_value > 0, "ZV"); // dev: need non-zero value
        require(_locked.amount > 0, 'ZL');
        require(_locked.end > block.timestamp || _locked.isPermanent, 'EXP');

        if (_locked.isSMNFT) smNFTBalance += _value;
        else if (_locked.isPermanent) permanentLockBalance += _value;

        _deposit_for(_tokenId, _value, 0, _locked, DepositType.DEPOSIT_FOR_TYPE);
            
        if(voted[_tokenId]) {
            IVoter(voter).poke(_tokenId);
        }
    }

    /// @notice Deposit `_value` tokens for `_to` and lock for `_lock_duration`
    /// @param _value Amount to deposit
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week)
    /// @param _to Address to deposit
    function _create_lock(uint _value, uint _lock_duration, address _to, bool isSMNFT) internal returns (uint) {
        uint unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK; // Locktime is rounded down to weeks

        require(_value > 0, "ZV"); // dev: need non-zero value
        require(unlock_time > block.timestamp && (unlock_time <= block.timestamp + MAXTIME), 'IUT');

        ++tokenId;
        uint _tokenId = tokenId;
        _mint(_to, _tokenId);

        IVotingEscrow.LockedBalance memory _locked = locked[_tokenId];
        if(isSMNFT) {
            _locked.isPermanent = true;
            _locked.isSMNFT = true;
            _locked.end = 0;
            unlock_time = 0;
            smNFTBalance += _value;
        }

        _deposit_for(_tokenId, _value, unlock_time, _locked, DepositType.CREATE_LOCK_TYPE);
        return _tokenId;
    }

    /// @notice Deposit `_value` tokens for `msg.sender` and lock for `_lock_duration`
    /// @param _value Amount to deposit
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week)
    function create_lock(uint _value, uint _lock_duration, bool isSMNFT) external nonreentrant returns (uint) {
        return _create_lock(_value, _lock_duration, msg.sender, isSMNFT);
    }

    /// @notice Deposit `_value` tokens for `_to` and lock for `_lock_duration`
    /// @param _value Amount to deposit
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week)
    /// @param _to Address to deposit
    function create_lock_for(uint _value, uint _lock_duration, address _to, bool isSMNFT) external nonreentrant returns (uint) {
        return _create_lock(_value, _lock_duration, _to, isSMNFT);
    }

    /// @notice Deposit `_value` additional tokens for `_tokenId` without modifying the unlock time
    /// @param _value Amount of tokens to deposit and add to the lock
    function increase_amount(uint _tokenId, uint _value) external nonreentrant {
        assert(_isApprovedOrOwner(msg.sender, _tokenId));

        IVotingEscrow.LockedBalance memory _locked = locked[_tokenId];

        assert(_value > 0); // dev: need non-zero value
        require(_locked.amount > 0, 'ZL');
        require(_locked.end > block.timestamp || _locked.isPermanent, 'EXP');
        
        if (_locked.isSMNFT) smNFTBalance += _value;
        else if (_locked.isPermanent) permanentLockBalance += _value;
        _deposit_for(_tokenId, _value, 0, _locked, DepositType.INCREASE_LOCK_AMOUNT);

        // poke for the gained voting power 
        if(voted[_tokenId]) {
            IVoter(voter).poke(_tokenId);
        }
        emit MetadataUpdate(_tokenId);
    }

    /// @notice Extend the unlock time for `_tokenId`
    /// @param _lock_duration New number of seconds until tokens unlock
    function increase_unlock_time(uint _tokenId, uint _lock_duration, bool isSMNFT) external nonreentrant {
        assert(_isApprovedOrOwner(msg.sender, _tokenId));

        IVotingEscrow.LockedBalance memory _locked = locked[_tokenId];
        require(!_locked.isSMNFT && !_locked.isPermanent, "!NORM");
        uint unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK; // Locktime is rounded down to weeks

        require(_locked.end > block.timestamp && _locked.amount > 0, 'EXP||ZV');
        require((isSMNFT || unlock_time > _locked.end) && (unlock_time <= block.timestamp + MAXTIME), 'IUT'); // IUT -> invalid unlock time

        if(isSMNFT) {
            updateToSMNFT(_tokenId, _locked);
        } else {
            _deposit_for(_tokenId, 0, unlock_time, _locked, DepositType.INCREASE_UNLOCK_TIME);
        }

        // poke for the gained voting power 
        if(voted[_tokenId]) {
            IVoter(voter).poke(_tokenId);
        }
        emit MetadataUpdate(_tokenId);
    }

    function updateToSMNFT (uint _tokenId, IVotingEscrow.LockedBalance memory _locked) internal {
        _locked.isPermanent = true;
        _locked.isSMNFT = true;
        uint _amount = uint(int256(_locked.amount));
        smNFTBalance += _amount;
        _locked.end = 0;
        uint _value = uint256(uint128(_locked.amount));
        _locked.amount = int128(int256(_value + calculate_sm_nft_bonus(_value)));
        _checkpoint(_tokenId, locked[_tokenId], _locked);
        locked[_tokenId] = _locked;
        // assert(IERC20(token).transfer(burnTokenAddress, _value));
        assert(_black.burn(_value));
    }

    /// @notice Withdraw all tokens for `_tokenId`
    /// @dev Only possible if the lock has expired
    function withdraw(uint _tokenId) external nonreentrant {
        assert(_isApprovedOrOwner(msg.sender, _tokenId));
        require(attachments[_tokenId] == 0 && !voted[_tokenId], "ATT");

        IVotingEscrow.LockedBalance memory _locked = locked[_tokenId];
        require(!_locked.isSMNFT && !_locked.isPermanent, "!NORM");
        require(block.timestamp >= _locked.end, "!EXP");
        uint value = uint(int256(_locked.amount));

        locked[_tokenId] = IVotingEscrow.LockedBalance(0, 0, false, false);
        uint supply_before = supply;
        supply = supply_before - value;

        // old_locked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(_tokenId, _locked, IVotingEscrow.LockedBalance(0, 0, false, false));

        assert(IERC20(token).transfer(msg.sender, value));

        // Burn the NFT
        _burn(_tokenId);

        emit Withdraw(msg.sender, _tokenId, value, block.timestamp);
        emit Supply(supply_before, supply_before - value);
    }

    function lockPermanent(uint _tokenId) external {
        address sender = msg.sender;
        require(_isApprovedOrOwner(sender, _tokenId), "NAO");
        
        IVotingEscrow.LockedBalance memory _newLocked = locked[_tokenId];
        require(!_newLocked.isSMNFT && !_newLocked.isPermanent, "!NORM");
        require(_newLocked.end > block.timestamp, "EXP");
        require(_newLocked.amount > 0, "ZV");

        uint _amount = uint(int256(_newLocked.amount));
        permanentLockBalance += _amount;
        _newLocked.end = 0;
        _newLocked.isPermanent = true;
        _checkpoint(_tokenId, locked[_tokenId], _newLocked);
        locked[_tokenId] = _newLocked;
        if(voted[_tokenId]) {
            IVoter(voter).poke(_tokenId);
        }
        emit LockPermanent(sender, _tokenId, _amount, block.timestamp);
        emit MetadataUpdate(_tokenId);
    }

    function unlockPermanent(uint _tokenId) external {
        address sender = msg.sender;
        require(_isApprovedOrOwner(msg.sender, _tokenId), "NAO");

        require(attachments[_tokenId] == 0 && !voted[_tokenId], "ATT");
        IVotingEscrow.LockedBalance memory _newLocked = locked[_tokenId];
        require(!_newLocked.isSMNFT && _newLocked.isPermanent, "!NORM");
        uint _amount = uint(int256(_newLocked.amount));
        permanentLockBalance -= _amount;
        _newLocked.end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        _newLocked.isPermanent = false;

        _checkpoint(_tokenId, locked[_tokenId], _newLocked);
        locked[_tokenId] = _newLocked;

        emit UnlockPermanent(sender, _tokenId, _amount, block.timestamp);
        emit MetadataUpdate(_tokenId);
    }


    /*///////////////////////////////////////////////////////////////
                           GAUGE VOTING STORAGE
    //////////////////////////////////////////////////////////////*/

    // The following ERC20/minime-compatible methods are not real balanceOf and supply!
    // They measure the weights for the purpose of voting, so they don't represent
    // real coins.

    function balanceOfNFT(uint _tokenId) external view returns (uint) {
        if (ownership_change[_tokenId] == block.number) return 0;
        return VotingBalanceLogic.balanceOfNFT(_tokenId, block.timestamp, votingBalanceLogicData);
    }

    function balanceOfNFTAt(uint _tokenId, uint _t) external view returns (uint) {
        return VotingBalanceLogic.balanceOfNFT(_tokenId, _t, votingBalanceLogicData);
    }

    function balanceOfAtNFT(uint _tokenId, uint _block) external view returns (uint) {
        return VotingBalanceLogic.balanceOfAtNFT(_tokenId, _block, votingBalanceLogicData, epoch);
    }

    /// @notice Calculate total voting power at some point in the past
    /// @param _block Block to calculate the total voting power at
    /// @return Total voting power at `_block`
    function totalSupplyAt(uint _block) external view returns (uint) {
        return VotingBalanceLogic.totalSupplyAt(_block, epoch, votingBalanceLogicData, slope_changes);
    }

    function totalSupply() external view returns (uint) {
        return totalSupplyAtT(block.timestamp);
    }

    /// @notice Calculate total voting power
    /// @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
    /// @return Total voting power
    function totalSupplyAtT(uint t) public view returns (uint) {
        return VotingBalanceLogic.totalSupplyAtT(t, epoch, slope_changes,  votingBalanceLogicData);
    }


    /*///////////////////////////////////////////////////////////////
                            GAUGE VOTING LOGIC
    //////////////////////////////////////////////////////////////*/

    mapping(uint => uint) public attachments;
    mapping(uint => bool) public voted;

    function setVoter(address _voter) external {
        require(msg.sender == team);
        voter = _voter;
    }

    function setAVM(address _avm) external {
        require(msg.sender == team);
        avm = _avm;
    }

    function voting(uint _tokenId) external {
        require(msg.sender == voter);
        voted[_tokenId] = true;
    }

    function abstain(uint _tokenId) external {
        require(msg.sender == voter, "NA");
        voted[_tokenId] = false;
    }

    function attach(uint _tokenId) external {
        require(msg.sender == voter, "NA");
        attachments[_tokenId] = attachments[_tokenId] + 1;
    }

    function detach(uint _tokenId) external {
        require(msg.sender == voter, "NA");
        attachments[_tokenId] = attachments[_tokenId] - 1;
    }

    function merge(uint _from, uint _to) external nonreentrant {
        require(attachments[_from] == 0 && !voted[_from], "ATT");
        require(_from != _to, "SAME");
        require(_isApprovedOrOwner(msg.sender, _from) && 
        _isApprovedOrOwner(msg.sender, _to), "NAO");

        IVotingEscrow.LockedBalance memory _locked0 = locked[_from];
        IVotingEscrow.LockedBalance memory _locked1 = locked[_to];
        require(_locked1.end > block.timestamp ||  _locked1.isPermanent,"EXP||PERM");
        require(_locked0.isPermanent ? (_locked0.isSMNFT ? _locked1.isSMNFT :  _locked1.isPermanent && !_locked1.isSMNFT) : true, "!MERGE");
        
        uint value0 = uint(int256(_locked0.amount));
        uint end = _locked0.end >= _locked1.end ? _locked0.end : _locked1.end;

        locked[_from] = IVotingEscrow.LockedBalance(0, 0, false, false);
        _checkpoint(_from, _locked0, IVotingEscrow.LockedBalance(0, 0, false, false));
        _burn(_from);

        IVotingEscrow.LockedBalance memory newLockedTo;
        newLockedTo.isPermanent = _locked1.isPermanent;
        newLockedTo.isSMNFT = _locked1.isSMNFT;

        if(newLockedTo.isSMNFT){
            if (!_locked0.isSMNFT) {
                // If source wasn't SMNFT, add bonus for its amount
                newLockedTo.amount = _locked1.amount + _locked0.amount + int128(int256(calculate_sm_nft_bonus(value0)));
                smNFTBalance += value0;
                assert(_black.burn(value0));
            } else {
                // If source was already SMNFT, just add amounts (both already include their bonuses)
                newLockedTo.amount = _locked1.amount + _locked0.amount;
            }
        } else if (newLockedTo.isPermanent){
            newLockedTo.amount = _locked1.amount + _locked0.amount;
            if (!_locked0.isPermanent) {  // Only add if source wasn't already permanent
                permanentLockBalance += value0;
            }
        }else{
            newLockedTo.amount = _locked1.amount + _locked0.amount;
            newLockedTo.end = end;
        }

        //_checkpointDelegatee(_delegates[_to], value0, true);
        _checkpoint(_to, _locked1, newLockedTo);
        locked[_to] = newLockedTo;

        if(voted[_to]) {
            IVoter(voter).poke(_to);
        }
        emit Merge(
            msg.sender,
            _from,
            _to,
            uint(int256(_locked0.amount)),
            uint(int256(_locked1.amount)),
            uint(int256(newLockedTo.amount)),
            newLockedTo.end,
            block.timestamp
        );
        emit MetadataUpdate(_to);
    }


    function split(
        uint _from,
        uint _amount
    ) external nonreentrant returns (uint256 _tokenId1, uint256 _tokenId2) {
        address owner = idToOwner[_from];
        require(canSplit[msg.sender] || canSplit[address(0)], "!SPLIT");
        require(attachments[_from] == 0 && !voted[_from], "ATT");
        require(_isApprovedOrOwner(msg.sender, _from), "NAO");

        IVotingEscrow.LockedBalance memory newLocked = locked[_from];
        require(newLocked.end > block.timestamp || newLocked.isPermanent, "EXP");
        
        int128 _splitAmount = newLocked.isSMNFT ? 
            int128(int256(_amount + calculate_sm_nft_bonus(_amount))) : 
            int128(int256(_amount));
        
        require(_splitAmount != 0, "ZV");
        require(newLocked.amount > _splitAmount, "BIGVAL");

        locked[_from] = IVotingEscrow.LockedBalance(0, 0, false, false);
        _checkpoint(_from, newLocked, IVotingEscrow.LockedBalance(0, 0, false, false));
        _burn(_from);

        newLocked.amount -= _splitAmount;
        _tokenId1 = _createSplitNFT(owner, newLocked);

        newLocked.amount = _splitAmount;
        _tokenId2 = _createSplitNFT(owner, newLocked);

        emit Split(
            _from,
            _tokenId1,
            _tokenId2,
            msg.sender,
            uint(int256(locked[_tokenId1].amount)),
            uint(int256(_splitAmount)),
            newLocked.end,
            block.timestamp
        );
    }

    function _createSplitNFT(address _to, IVotingEscrow.LockedBalance memory _newLocked) private returns (uint256 _tokenId) {
        _tokenId = ++tokenId;
        locked[_tokenId] = _newLocked;
        _checkpoint(_tokenId, IVotingEscrow.LockedBalance(0, 0, false, false), _newLocked);
        _mint(_to, _tokenId);
    }

    function toggleSplit(address _account, bool _bool) external {
        require(msg.sender == team);
        canSplit[_account] = _bool;
    }

    /*///////////////////////////////////////////////////////////////
                            DAO VOTING STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice A record of each accounts delegate
    mapping(address => address) private _delegates;

    /// @notice A record of states for signing / validating signatures
    mapping(address => uint) public nonces;

    /**
     * @notice Overrides the standard `Comp.sol` delegates mapping to return
     * the delegator's own address if they haven't delegated.
     * This avoids having to delegate to oneself.
     */
    function delegates(address delegator) public view returns (address) {
        address current = _delegates[delegator];
        return current == address(0) ? delegator : current;
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getVotes(address account) external view returns (uint) {
        uint32 nCheckpoints = cpData.numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }
        uint[] storage _tokenIds = cpData.checkpoints[account][nCheckpoints - 1].tokenIds;
        uint votes = 0;
        for (uint i = 0; i < _tokenIds.length; i++) {
            uint tId = _tokenIds[i];
            votes = votes + VotingBalanceLogic.balanceOfNFT(tId, block.timestamp, votingBalanceLogicData);
        }
        return votes;
    }

    function getPastVotes(address account, uint timestamp)
        public
        view
        returns (uint)
    {
        uint32 _checkIndex = VotingDelegationLib.getPastVotesIndex(cpData, account, timestamp);
        // Sum votes
        uint[] storage _tokenIds = cpData.checkpoints[account][_checkIndex].tokenIds;
        uint votes = 0;
        for (uint i = 0; i < _tokenIds.length; i++) {
            uint tId = _tokenIds[i];
            // Use the provided input timestamp here to get the right decay
            votes = votes + VotingBalanceLogic.balanceOfNFT(tId, timestamp,  votingBalanceLogicData);
        }

        return votes;
    }

    function getsmNFTPastVotes(address account, uint timestamp) 
        public
        view
        returns (uint)
    {
        uint32 _checkIndex = VotingDelegationLib.getPastVotesIndex(cpData, account, timestamp);
        // Sum votes
        uint[] storage _tokenIds = cpData.checkpoints[account][_checkIndex].tokenIds;
        uint votes = 0;
        for (uint i = 0; i < _tokenIds.length; i++) {
            uint tId = _tokenIds[i];
            if(!locked[tId].isSMNFT) continue;
            // Use the provided input timestamp here to get the right decay
            votes = votes + VotingBalanceLogic.balanceOfNFT(tId, timestamp, votingBalanceLogicData);
        }
        return votes;
    }

    function getPastTotalSupply(uint256 timestamp) external view returns (uint) {
        return totalSupplyAtT(timestamp);
    }

    function getsmNFTPastTotalSupply() external view returns (uint) {
        return smNFTBalance;
    }

    /*///////////////////////////////////////////////////////////////
                             DAO VOTING LOGIC
    //////////////////////////////////////////////////////////////*/
    function _delegate(address delegator, address delegatee) internal {
        /// @notice differs from `_delegate()` in `Comp.sol` to use `delegates` override method to simulate auto-delegation
        address currentDelegate = delegates(delegator);

        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);
        VotingDelegationLib.TokenHelpers memory tokenHelpers = VotingDelegationLib.TokenHelpers({
            ownerOfFn: ownerOf,
            ownerToNFTokenCountFn: ownerToNFTokenCountFn,
            tokenOfOwnerByIndex:tokenOfOwnerByIndex
        });
        VotingDelegationLib._moveAllDelegates(cpData, delegator, currentDelegate, delegatee, tokenHelpers);
    }

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegatee The address to delegate votes to
     */
    function delegate(address delegatee) public {
        if (delegatee == address(0)) delegatee = msg.sender;
        return _delegate(msg.sender, delegatee);
    }

    function delegateBySig(
        address delegatee,
        uint nonce,
        uint expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(delegatee != msg.sender, "NA");
        require(delegatee != address(0), "ZA");
        
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        address signatory = ecrecover(digest, v, r, s);
        require(
            signatory != address(0),
            "ZA"
        );
        require(
            nonce == nonces[signatory]++,
            "!NONCE"
        );
        require(
            block.timestamp <= expiry,
            "EXP"
        );
        return _delegate(signatory, delegatee);
    }

    function setSmNFTBonus(uint _bonus) external {
        require(msg.sender == team);
        require(_bonus <= PRECISISON);
        SMNFT_BONUS = _bonus;
    }

    function calculate_sm_nft_bonus(uint amount) public view returns (uint){
        return (SMNFT_BONUS * amount) / PRECISISON;
    }

    function calculate_original_sm_nft_amount(uint amount) public view returns (uint){
        return (amount * PRECISISON) / (SMNFT_BONUS + PRECISISON);
    }
}
