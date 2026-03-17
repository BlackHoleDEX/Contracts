// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

// Shared custom errors across router, helpers, and zap library
error EXP();   // Expired
error IA();    // Invalid Address/Amount
error INL();   // Insufficient Liquidity
error DLMA();  // Desired Liquidity More than Allowed
error IAA();   // Insufficient Amount A
error ITFM();  // TransferFrom failed
error IR(address recipient); // Invalid recipient/route receiver
error IOA(uint256 required, uint256 available); // Insufficient output amount
error INP();   // Invalid Path
error ZA();    // Zero Amount
error ETF(uint256 amount); // ETH transfer failed
error CODELEN(); // Code length zero
error ZERO_LIQUIDITY_MINTED(); // Mint returned zero liquidity
error NOT_AUTHORIZED(); // Caller not authorized
error NA();    // Not Allowed / Genesis guard

error IST();   // Insufficient transfer
error ISTF();  // Insufficient transferFrom
error NS();    // No swaps provided
error ER();    // Empty routes
error IOT();   // Incomplete output tokens list
error CF();    // Callback failed
error CL();    // Code length

error IIT(address token); // Invalid input token
error ALM(uint256 expected, uint256 actual); // Array length mismatch
error BE(uint256 required, uint256 available); // Bad ETH provided
error ISTK(address token); // Invalid swap token
error MSFT(address token); // Missing swap for token
error CC();    // Invalid callback caller
error IB(uint256 required, uint256 available); // Insufficient balance
error NNS();   // NFPM not set
error IT(address expected0, address actual0, address expected1, address actual1); // Invalid tokens

