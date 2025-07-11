// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.13;


library VotingDelegationLib {
    /// @notice A checkpoint for marking delegated tokenIds from a given timestamp
    struct Checkpoint {
        uint timestamp;
        uint[] tokenIds;
    }

    // A struct that holds all checkpoint data for different accounts.
    // The calling contract will include one instance of this struct in storage.
    struct Data {
        // For each account, store a mapping from checkpoint index to Checkpoint.
        mapping(address => mapping(uint32 => Checkpoint)) checkpoints;
        // For each account, store the number of checkpoints.
        mapping(address => uint32) numCheckpoints;
    }

    struct TokenHelpers {
        function(uint) view returns (address) ownerOfFn;
        function(address) view returns (uint) ownerToNFTokenCountFn;
        function(address, uint) view returns (uint) tokenOfOwnerByIndex;
    }

    uint public constant MAX_DELEGATES = 1024; // avoid too much gas
    /**
     * @notice Returns the checkpoint index to write for an account.
     * If the most recent checkpoint was created in the current timestamp, returns that index.
     * Otherwise, returns the current number of checkpoints (i.e. a new checkpoint index).
     */
    function findCheckpointToWrite(
        Data storage self,
        address account,
        uint256 currentTimestamp
    ) internal view returns (uint32) {
        uint32 n = self.numCheckpoints[account];
        if (n > 0 && self.checkpoints[account][n - 1].timestamp == currentTimestamp) {
            return n - 1;
        } else {
            return n;
        }
    }

    function moveTokenDelegates(
        Data storage self,
        address srcRep,
        address dstRep,
        uint _tokenId,
        function(uint) view returns (address) ownerOfFn
    ) internal {
        if (srcRep != dstRep && _tokenId > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = self.numCheckpoints[srcRep];
                uint[] storage srcRepOld = srcRepNum > 0
                    ? self.checkpoints[srcRep][srcRepNum - 1].tokenIds
                    : self.checkpoints[srcRep][0].tokenIds;
                uint32 nextSrcRepNum = findCheckpointToWrite(self, srcRep, block.timestamp);
                bool _isCheckpointInNewBlock = (srcRepNum > 0) ? (nextSrcRepNum != srcRepNum - 1) : true;
                Checkpoint storage cpSrcRep = self.checkpoints[srcRep][nextSrcRepNum];
                uint[] storage srcRepNew = cpSrcRep.tokenIds;
                cpSrcRep.timestamp = block.timestamp;
                // All the same except _tokenId
                uint256 length = srcRepOld.length;
                for (uint i = 0; i < length;) {
                    uint tId = srcRepOld[i];
                    if(_isCheckpointInNewBlock) {
                        if(ownerOfFn(tId) == srcRep) {
                            srcRepNew.push(tId);
                        }
                        i++;
                    } else {
                        if(ownerOfFn(tId) != srcRep) {
                            srcRepNew[i] = srcRepNew[length -1];
                            srcRepNew.pop();
                            length--;
                        } else {
                            i++;
                        }
                    }
                }
                self.numCheckpoints[srcRep] = nextSrcRepNum + 1;   
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = self.numCheckpoints[dstRep];
                uint[] storage dstRepOld = dstRepNum > 0
                    ? self.checkpoints[dstRep][dstRepNum - 1].tokenIds
                    : self.checkpoints[dstRep][0].tokenIds;
                uint32 nextDstRepNum = findCheckpointToWrite(self, dstRep, block.timestamp);
                bool _isCheckpointInNewBlock = (dstRepNum > 0) ? (nextDstRepNum != dstRepNum - 1) : true;
                Checkpoint storage cpDstRep = self.checkpoints[dstRep][nextDstRepNum];
                uint[] storage dstRepNew = cpDstRep.tokenIds;
                cpDstRep.timestamp = block.timestamp;
                require(
                    dstRepOld.length + 1 <= MAX_DELEGATES,
                    "tokens>1"
                );
                if(_isCheckpointInNewBlock) {
                    for (uint i = 0; i < dstRepOld.length; i++) {
                        uint tId = dstRepOld[i];
                        dstRepNew.push(tId);
                    }
                }
                dstRepNew.push(_tokenId);
                self.numCheckpoints[dstRep] = nextDstRepNum + 1;
            }
        }
    }

    function _moveAllDelegates(
        Data storage self,
        address owner,
        address srcRep,
        address dstRep,
        TokenHelpers memory tokenHelpers
    ) internal {
        // You can only redelegate what you own
        address _owner = owner;
        Data storage _self = self;
        address _srcRep = srcRep;
        address _dstRep = dstRep;
        TokenHelpers memory _tokenHelper = tokenHelpers;
        if (_srcRep != _dstRep) {
            if (_srcRep != address(0)) {
                uint32 srcRepNum = _self.numCheckpoints[_srcRep];
                uint[] storage srcRepOld = srcRepNum > 0
                    ? _self.checkpoints[_srcRep][srcRepNum - 1].tokenIds
                    : _self.checkpoints[_srcRep][0].tokenIds;
                uint32 nextSrcRepNum = findCheckpointToWrite(_self,_srcRep, block.timestamp);
                bool _isCheckpointInNewBlock = (srcRepNum > 0) ? (nextSrcRepNum != srcRepNum - 1) : true;
                // if(_isCheckpointInNewBlock) {
                Checkpoint storage cpSrcRep = _self.checkpoints[_srcRep][nextSrcRepNum];
                uint[] storage srcRepNew = cpSrcRep.tokenIds;
                cpSrcRep.timestamp = block.timestamp;

                uint256 length = srcRepOld.length;
                for (uint i = 0; i < length;) {
                    uint tId = srcRepOld[i];
                    if(_isCheckpointInNewBlock) {
                        if(_tokenHelper.ownerOfFn(tId) != _owner) {
                            srcRepNew.push(tId);
                        }
                        i++;
                    } else {
                        if(_tokenHelper.ownerOfFn(tId) == _owner) {
                            srcRepNew[i] = srcRepNew[length -1];
                            srcRepNew.pop();
                            length--;
                        } else {
                            i++;
                        }
                    }
                }
                _self.numCheckpoints[_srcRep] = nextSrcRepNum + 1;
            }


            if (_dstRep != address(0)) {
                uint32 dstRepNum = _self.numCheckpoints[_dstRep];
                uint[] storage dstRepOld = dstRepNum > 0
                    ? _self.checkpoints[_dstRep][dstRepNum - 1].tokenIds
                    : _self.checkpoints[_dstRep][0].tokenIds;
                uint32 nextDstRepNum = findCheckpointToWrite(_self,_dstRep, block.timestamp);
                bool _isCheckpointInNewBlock = (dstRepNum > 0) ? (nextDstRepNum != dstRepNum - 1) : true;
                Checkpoint storage cpDstRep = _self.checkpoints[_dstRep][nextDstRepNum];
                uint[] storage dstRepNew = cpDstRep.tokenIds;
                cpDstRep.timestamp = block.timestamp;
                uint ownerTokenCount = _tokenHelper.ownerToNFTokenCountFn(_owner);
                require(
                    dstRepOld.length + ownerTokenCount <= MAX_DELEGATES,
                    "tokens>1"
                );
                if(_isCheckpointInNewBlock) {
                    for (uint i = 0; i < dstRepOld.length; i++) {
                        uint tId = dstRepOld[i];
                        dstRepNew.push(tId);
                    }
                }
                // Plus all that's owned
                for (uint i = 0; i < ownerTokenCount; i++) {
                    uint tId = _tokenHelper.tokenOfOwnerByIndex(_owner,i);
                    dstRepNew.push(tId);
                }
                _self.numCheckpoints[_dstRep] = nextDstRepNum + 1;   
            }
        }
    }

    function getPastVotesIndex(Data storage data, address account, uint timestamp) internal view returns (uint32) {
        uint32 nCheckpoints = data.numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }
        // First check most recent balance
        if (data.checkpoints[account][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (data.checkpoints[account][0].timestamp > timestamp) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            VotingDelegationLib.Checkpoint storage cp = data.checkpoints[account][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

}