// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title IAggregationRouterV6
/// @notice Interface for 1inch Aggregation Router V6
interface IAggregationRouterV6 {
    struct SwapDescription {
        address srcToken;
        address dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function swap(
        address executor,
        SwapDescription calldata desc,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount);

    function unoswap(
        address srcToken,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools
    ) external payable returns (uint256 returnAmount);
}

/// @title OneInchAdapter
/// @notice Adapter for 1inch DEX aggregator
/// @dev Integrates with 1inch Aggregation Router V6
contract OneInchAdapter is IDexAdapter, Ownable {
    using SafeERC20 for IERC20;

    // 1inch Router addresses per chain
    // Ethereum: 0x111111125421cA6dc452d289314280a0f8842A65
    // Polygon: 0x111111125421cA6dc452d289314280a0f8842A65
    // Arbitrum: 0x111111125421cA6dc452d289314280a0f8842A65
    // BSC: 0x111111125421cA6dc452d289314280a0f8842A65
    IAggregationRouterV6 public aggregationRouter;

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Events
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Errors
    error InvalidRouter();
    error SwapFailed();
    error InsufficientOutput();
    error UnsupportedPair();

    constructor(address _router) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRouter();
        aggregationRouter = IAggregationRouterV6(_router);

        // ETH always supported
        supportedTokens[address(0)] = true;
    }

    /// @inheritdoc IDexAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata extraData
    ) external payable override returns (uint256 amountOut) {
        if (address(aggregationRouter) == address(0)) revert InvalidRouter();

        // Decode 1inch swap data
        (address executor, IAggregationRouterV6.SwapDescription memory desc, bytes memory data) =
            abi.decode(extraData, (address, IAggregationRouterV6.SwapDescription, bytes));

        // Handle token transfers
        if (tokenIn == address(0)) {
            // ETH swap
            (amountOut,) = aggregationRouter.swap{value: amountIn}(executor, desc, data);
        } else {
            // ERC20 swap
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            // Use forceApprove for USDT and similar tokens that require allowance to be 0 first
            IERC20(tokenIn).forceApprove(address(aggregationRouter), amountIn);
            (amountOut,) = aggregationRouter.swap(executor, desc, data);
        }

        if (amountOut < minAmountOut) revert InsufficientOutput();

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, msg.sender);
        return amountOut;
    }

    /// @inheritdoc IDexAdapter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external override returns (uint256 amountOut, bytes memory extraData) {
        // Note: 1inch quotes are fetched off-chain via their API
        // This is a placeholder - actual implementation would use oracle or off-chain data
        // Return 0 to indicate quote should be fetched from 1inch API
        return (0, "");
    }

    /// @inheritdoc IDexAdapter
    function getDexInfo() external view override returns (string memory name, address router) {
        return ("1inch", address(aggregationRouter));
    }

    /// @inheritdoc IDexAdapter
    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool supported) {
        return supportedTokens[tokenIn] && supportedTokens[tokenOut];
    }

    // ============ Admin Functions ============

    /// @notice Update 1inch router
    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert InvalidRouter();
        address oldRouter = address(aggregationRouter);
        aggregationRouter = IAggregationRouterV6(_router);
        emit RouterUpdated(oldRouter, _router);
    }

    /// @notice Set token support
    function setTokenSupport(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
        emit TokenSupportUpdated(token, supported);
    }

    /// @notice Batch set token support
    function batchSetTokenSupport(address[] calldata tokens, bool[] calldata supported) external onlyOwner {
        require(tokens.length == supported.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            supportedTokens[tokens[i]] = supported[i];
            emit TokenSupportUpdated(tokens[i], supported[i]);
        }
    }

    /// @notice Emergency withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Receive ETH
    receive() external payable {}
}
