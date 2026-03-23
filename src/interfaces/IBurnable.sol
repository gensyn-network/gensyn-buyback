// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface for ERC20 tokens with burn functionality
interface IBurnable {
    /// @notice Burns tokens from the caller's balance, reducing totalSupply
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;
}
