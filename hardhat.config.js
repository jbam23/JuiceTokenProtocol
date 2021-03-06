/**
 * @type import('hardhat/config').HardhatUserConfig
 */
const { utils, BigNumber, constants } = require("ethers");
require('@nomiclabs/hardhat-waffle');
require('hardhat-deploy');
require("@nomiclabs/hardhat-ethers");
require('hardhat-deploy');
// require("hardhat-gas-reporter");
module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
    }
  },
  solidity: {
    settings: {
      optimizer: {
        enabled: true,
        runs: 100
      }
    },
    compilers: [
      {
        version: "0.4.24",
        settings: { } 
      },
      {
        version: "0.5.12",
        settings: { } 
      },
      {
        version: "0.8.0",
        settings: { } 
      },
      {
        version: "0.6.12",
        settings: { } 
      },
      {
        version: "0.7.3",
        settings: { } 
      }
     
    ],
    overrides: {
      "contracts/SportsBook.sol": {
        version: "0.6.12",
        settings: { }
    }
   }
  }
};
