// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

/*
    This contract handles the accesses to the various Black contracts.
*/

contract PermissionsRegistry {

    /// @notice Control this contract. This is the main multisig
    address public blackMultisig;

    /// @notice This is the black team multisig 
    address public blackTeamMultisig;

    /// @notice Control emergency functions (set to multisig)
    address public emergencyCouncil;

    /// @notice Check if caller has a role active   (role -> caller -> true/false)
    mapping(bytes => mapping(address => bool)) public hasRole;
    mapping(bytes => bool) internal _checkRole;

    mapping(bytes => address[]) internal _roleToAddresses;
    mapping(address => bytes[]) internal _addressToRoles;

    /// @notice Roles array
    bytes[] internal _roles;

    event RoleAdded(bytes role);
    event RoleRemoved(bytes role);
    event RoleSetFor(address indexed user, bytes indexed role);
    event RoleRemovedFor(address indexed user, bytes indexed role);
    event SetEmergencyCouncil(address indexed council);
    event SetBlackTeamMultisig(address indexed multisig);
    event SetBlackMultisig(address indexed multisig);



    constructor() {
        blackTeamMultisig = msg.sender;
        blackMultisig = msg.sender;
        emergencyCouncil = msg.sender;


        _roles.push(bytes("GOVERNANCE"));
        _checkRole[(bytes("GOVERNANCE"))] = true;

        _roles.push(bytes("VOTER_ADMIN"));
        _checkRole[(bytes("VOTER_ADMIN"))] = true;

        _roles.push(bytes("GAUGE_ADMIN"));
        _checkRole[(bytes("GAUGE_ADMIN"))] = true;

        _roles.push(bytes("BRIBE_ADMIN"));
        _checkRole[(bytes("BRIBE_ADMIN"))] = true;

        _roles.push(bytes("FEE_MANAGER"));
        _checkRole[(bytes("FEE_MANAGER"))] = true;

        _roles.push(bytes("CL_POOL_ADMIN"));
        _checkRole[(bytes("CL_POOL_ADMIN"))] = true;

        _roles.push(bytes("GENESIS_MANAGER"));
        _checkRole[(bytes("GENESIS_MANAGER"))] = true;

        _roles.push(bytes("EPOCH_MANAGER"));
        _checkRole[(bytes("EPOCH_MANAGER"))] = true;
    }

    modifier onlyBlackMultisig() {
        require(msg.sender == blackMultisig, "!blackMultisig");
        _;
    }

    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                    ROLES SETTINGS
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */

    /// @notice add a new role
    /// @param  role    new role's string (eg role = "GAUGE_ADMIN")
    function addRole(string memory role) external onlyBlackMultisig {
        bytes memory _role = bytes(role);
        require(!_checkRole[_role], 'is a role');
        _checkRole[_role] = true;
        _roles.push(_role);
        emit RoleAdded(_role);
    }

    /// @notice Remove a role
    /// @dev    set last one to i_th position then .pop()
    function removeRole(string memory role) external onlyBlackMultisig {
        bytes memory _role = bytes(role);
        require(_checkRole[_role], 'not a role');

        for(uint i = 0; i < _roles.length; i++){
            if(keccak256(_roles[i]) == keccak256(_role)){
                _roles[i] = _roles[_roles.length -1];
                _roles.pop();
                _checkRole[_role] = false;
                emit RoleRemoved(_role);
                break; 
            }
        }

        address[] memory rta = _roleToAddresses[bytes(role)];
        for(uint i = 0; i < rta.length; i++){
            hasRole[bytes(role)][rta[i]] = false;
            bytes[] memory __roles = _addressToRoles[rta[i]];
            for(uint k = 0; k < __roles.length; k++){
                if(keccak256(__roles[k]) == keccak256(bytes(role))){
                    _addressToRoles[rta[i]][k] = __roles[__roles.length -1];
                    _addressToRoles[rta[i]].pop();
                }
            }
        }

    }


    
    /// @notice Set a role for an address
    function setRoleFor(address c, string memory role) external onlyBlackMultisig {
        bytes memory _role = bytes(role);
        require(_checkRole[_role], 'not a role');
        require(!hasRole[_role][c], 'assigned');

        hasRole[_role][c] = true;

        _roleToAddresses[_role].push(c);
        _addressToRoles[c].push(_role);

        emit RoleSetFor(c, _role);

    }

    
    /// @notice remove a role from an address
    function removeRoleFrom(address c, string memory role) external onlyBlackMultisig {
        bytes memory _role = bytes(role);
        require(_checkRole[_role], 'not a role');
        require(hasRole[_role][c], 'not assigned');

        hasRole[_role][c] = false;

        address[] storage rta = _roleToAddresses[_role];
        for(uint i = 0; i < rta.length; i++){
            if(rta[i] == c){
                rta[i] = rta[rta.length -1];
                rta.pop();
            }
        }

        bytes[] storage atr = _addressToRoles[c];
        for(uint i = 0; i < atr.length; i++){
            if(keccak256(atr[i]) == keccak256(_role)){
                atr[i] = atr[atr.length -1];
                atr.pop();
            }
        }

        emit RoleRemovedFor(c, _role);
        
    }

    

  

    /************************************************************
                                VIEW
    *************************************************************/
    
    /// @notice Read roles and return strings
    function rolesToString() external view returns(string[] memory __roles){
        __roles = new string[](_roles.length);
        for(uint i = 0; i < _roles.length; i++){
            __roles[i] = string(_roles[i]);
        }
    }

    
    /// @notice Read roles array and return bytes
    function roles() external view returns(bytes[] memory){
        return _roles;
    }

    /// @notice Read roles length
    function rolesLength() external view returns(uint){
        return _roles.length;
    }

     /// @notice Return addresses for a given role
    function roleToAddresses(string memory role) external view returns(address[] memory _addresses){
        return _roleToAddresses[bytes(role)];
    }

    /// @notice Return roles for a given address
    function addressToRole(address _user) external view returns(string[] memory){
        string[] memory _temp = new string[](_addressToRoles[_user].length);
        uint i = 0;
        for(i; i < _temp.length; i++){
            _temp[i] = string(_addressToRoles[_user][i]);
        }
        return _temp;
    }

    
    /************************************************************
                                HELPERS
    *************************************************************/

    /// @notice Helper function to get bytes from a string
    function helper_stringToBytes(string memory _input) public pure returns(bytes memory){
        return bytes(_input);
    }

    /// @notice Helper function to get string from bytes
    function helper_bytesToString(bytes memory _input) public pure returns(string memory){
        return string(_input);
    }


  
    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                EMERGENCY AND MULTISIG
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */


    /// @notice set emergency counsil
    /// @param _new new address    
    function setEmergencyCouncil(address _new) external {
        require(msg.sender == emergencyCouncil || msg.sender == blackMultisig, "not allowed");
        require(_new != address(0), "addr0");
        require(_new != emergencyCouncil, "same emergencyCouncil");
        emergencyCouncil = _new;

        emit SetEmergencyCouncil(_new);
    }


    /// @notice set black team multisig
    /// @param _new new address    
    function setBlackTeamMultisig(address _new) external {
        require(msg.sender == blackTeamMultisig, "not allowed");
        require(_new != address(0), "addr 0");
        require(_new != blackTeamMultisig, "same multisig");
        blackTeamMultisig = _new;
        
        emit SetBlackTeamMultisig(_new);
    }

    /// @notice set black multisig
    /// @param _new new address    
    function setBlackMultisig(address _new) external {
        require(msg.sender == blackMultisig, "not allowed");
        require(_new != address(0), "addr0");
        require(_new != blackMultisig, "same multisig");
        blackMultisig = _new;
        
        emit SetBlackMultisig(_new);
    }
    


}