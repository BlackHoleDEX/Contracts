require("@nomiclabs/hardhat-waffle");
require('@openzeppelin/hardhat-upgrades');
require("@nomiclabs/hardhat-etherscan");
require("@nomiclabs/hardhat-web3");
require("dotenv").config(); 

module.exports = {
  // Latest Solidity version
  solidity: {
    compilers: [
      {
        version: "0.8.13",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          metadata: {
              useLiteralContent: true
          }
        },
      },
    ],
  },

  networks: {
    avalanche: {
      url: `${process.env.RPC_URL}`, // AVALANCHE Mainnet RPC
      chainId: 43114,
      accounts: [`0x${process.env.PRIVATEKEY}`],
    },
    sepolia: {
      url: `${process.env.RPC_URL}`, // Base Sepolia Testnet RPC
      chainId: 11155111,
      accounts: [`0x${process.env.PRIVATEKEY}`],
    },
    fuji: {
      url: `${process.env.RPC_URL}`, // Fuji Testnet RPC
      chainId: 43113,
      accounts: [`0x${process.env.PRIVATEKEY}`],
    },
  },

  etherscan: {
    apiKey: {
      avalancheFujiTestnet: `${process.env.APIKEY??"UNKNOWN"}`,
      avalanche: `${process.env.APIKEY??"UNKNOWN"}`
    }
  },

  mocha: {
    timeout: 100000000,
  },
};
