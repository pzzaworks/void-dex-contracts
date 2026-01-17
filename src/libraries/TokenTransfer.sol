// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenTransfer
/// @notice Library for safe token transfers supporting both native ETH and ERC20
library TokenTransfer {
    using SafeERC20 for IERC20;

    error TransferFailed();
    error InsufficientValue();

    /// @notice Transfer tokens from sender to recipient
    /// @param token Token address (address(0) for native ETH)
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transferFrom(address token, address from, address to, uint256 amount) internal {
        if (token == address(0)) {
            // Native ETH - must be sent with msg.value
            if (from != address(this)) {
                revert TransferFailed();
            }
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    /// @notice Transfer tokens from this contract to recipient
    /// @param token Token address (address(0) for native ETH)
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Get balance of this contract
    /// @param token Token address (address(0) for native ETH)
    /// @return balance The balance
    function balanceOf(address token) internal view returns (uint256 balance) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }
}
