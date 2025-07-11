// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '../interfaces/IAuctionFactory.sol';

contract AuctionFactory is IAuctionFactory, OwnableUpgradeable {

    address[] public auctions;
    mapping(address => bool) public isAuction;

    event AddAuction(address indexed auction);
    event SetAuction(address indexed old, address indexed latest);

    modifier onlyManager() {
        require(msg.sender == owner());
        _;
    }

    constructor() {}

    // _auction is a fixed auction (default auction assigned to GPs)
    function initialize(address _auction) public initializer {
        __Ownable_init();

        isAuction[_auction] = true;
        auctions.push(_auction);
    }

     function addAuction(address _auction) external onlyManager {
        require(_auction != address(0), 'addr0');
        require(!isAuction[_auction], 'fact');
        require(_auction.code.length > 0, "!contract");

        auctions.push(_auction);
        isAuction[_auction] = true;
        emit AddAuction(_auction);
    }

    function replaceAuction(address _auction, uint256 _pos) external onlyManager {
        require(_auction != address(0), 'addr0');
        require(!isAuction[_auction], '!fact');
        require(_auction.code.length > 0, "!contract");
        address oldPF = auctions[_pos];
        isAuction[oldPF] = false;

        auctions[_pos] = _auction;
        isAuction[_auction] = true;

        emit SetAuction(oldPF, _auction);
    }

    function removeAuction(uint256 _pos) external onlyManager {
        address oldPF = auctions[_pos];
        require(isAuction[oldPF], '!fact');

        auctions[_pos] = address(0);
        isAuction[oldPF] = false;

        emit SetAuction(oldPF, address(0));
    }

    function auctionsLength() external view returns (uint256){
        return auctions.length;
    }

    function allAuctions() external view returns (address[] memory){
        return auctions;
    }
}