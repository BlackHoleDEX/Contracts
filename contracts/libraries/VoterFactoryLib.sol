// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

library VoterFactoryLib {
    struct Data {
        address[] pairFactories;
        address[] gaugeFactories;
        mapping(address => bool) isFactory;
        mapping(address => bool) isGaugeFactory;
    }

    event AddPairFactories(address indexed pairfactory);
    event AddGaugeFactories(address indexed gaugefactory);
    event SetGaugeFactory(address indexed old, address indexed latest);
    event SetPairFactory(address indexed old, address indexed latest);


    function addPairFactory(Data storage self, address _pairFactory) external {
        require(_pairFactory != address(0) , 'addr0');
        require(!self.isFactory[_pairFactory], "fact");
        require(_pairFactory.code.length > 0, "!contract");
        self.pairFactories.push(_pairFactory);
        self.isFactory[_pairFactory] = true;
        emit AddPairFactories(_pairFactory);
    }

    function addGaugeFactory(Data storage self, address _gaugeFactory) external {
        require(_gaugeFactory != address(0) , 'addr0');
        require(!self.isGaugeFactory[_gaugeFactory], "gFact");
        require(_gaugeFactory.code.length > 0, "!contract");
        self.gaugeFactories.push(_gaugeFactory);
        self.isGaugeFactory[_gaugeFactory] = true;
        emit AddGaugeFactories(_gaugeFactory);
    }

    function replacePairFactory(Data storage self, address _pairFactory, uint256 _pos) external {
        require(_pairFactory != address(0), 'addr0');
        require(!self.isFactory[_pairFactory], 'fact');
        require(_pairFactory.code.length > 0, "!contract");
        address oldPF = self.pairFactories[_pos];
        self.isFactory[oldPF] = false;
        self.pairFactories[_pos] = _pairFactory;
        self.isFactory[_pairFactory] = true;

        emit SetPairFactory(oldPF, _pairFactory);
    }

    function replaceGaugeFactory(Data storage self, address _gaugeFactory, uint256 _pos) external {
        require(_gaugeFactory != address(0) , 'addr0');
        require(!self.isGaugeFactory[_gaugeFactory], 'gFact');
        require(_gaugeFactory.code.length > 0, "!contract");
        address oldGF = self.gaugeFactories[_pos];
        self.isGaugeFactory[oldGF] = false;
        self.gaugeFactories[_pos] = _gaugeFactory;
        self.isGaugeFactory[_gaugeFactory] = true;

        emit SetGaugeFactory(oldGF, _gaugeFactory);
    }

    function removePairFactory(Data storage self, uint256 _pos) external {
        address oldPF = self.pairFactories[_pos];
        require(self.isFactory[oldPF], "!exists");
        self.isFactory[oldPF] = false;
        self.pairFactories[_pos] = address(0);
        emit SetPairFactory(oldPF, address(0));
    }

    function removeGaugeFactory(Data storage self, uint256 _pos) external {
        address oldGF = self.gaugeFactories[_pos];
        require(self.isGaugeFactory[oldGF], "!exists");
        self.isGaugeFactory[oldGF] = false;
        self.gaugeFactories[_pos] = address(0);
        emit SetGaugeFactory(oldGF, address(0));
    }

}