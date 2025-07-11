// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IBlackholePairApiV2 {

    struct pairInfo {
        // pair info
        address pair_address; 			// pair contract address
        string symbol; 				    // pair symbol
        string name;                    // pair name
        uint decimals; 			        // pair decimals
        bool stable; 				    // pair pool type (stable = false, means it's a variable type of pool)
        uint total_supply; 			    // pair tokens supply
    
        // token pair info
        address token0; 				// pair 1st token address
        string token0_symbol; 			// pair 1st token symbol
        uint token0_decimals; 		    // pair 1st token decimals
        uint reserve0; 			        // pair 1st token reserves (nr. of tokens in the contract)
        uint claimable0;                // claimable 1st token from fees (for unstaked positions)

        address token1; 				// pair 2nd token address
        string token1_symbol;           // pair 2nd token symbol
        uint token1_decimals;    		// pair 2nd token decimals
        uint reserve1; 			        // pair 2nd token reserves (nr. of tokens in the contract)
        uint claimable1; 			    // claimable 2nd token from fees (for unstaked positions)

        // pairs gauge
        address gauge; 				    // pair gauge address
        uint gauge_total_supply; 		// pair staked tokens (less/eq than/to pair total supply)
        uint emissions; 			    // pair emissions (per second)
        address emissions_token; 		// pair emissions token address
        uint emissions_token_decimals; 	// pair emissions token decimals

        // User deposit
        uint account_lp_balance; 		// account LP tokens balance
        uint account_token0_balance; 	// account 1st token balance
        uint account_token1_balance; 	// account 2nd token balance
        uint account_gauge_balance;     // account pair staked in gauge balance
        uint account_gauge_earned; 		// account earned emissions for this pair

        // votes
        uint votes;

        // fees
        uint staked_token0_fees;      // staked token 0 fees accumulated till now
        uint staked_token1_fees;      // staked token 1 fees accumulated till now

        // bribes
        Bribes internal_bribes;
        Bribes external_bribes;
    }


    struct Bribes {
        address bribeAddress;
        address[] tokens;
        string[] symbols;
        uint[] decimals;
        uint[] amounts;
    }

    function getAllPair(address _user, uint _amounts, uint _offset) external view returns(uint totPairs, bool hasNext, pairInfo[] memory pairs);
}