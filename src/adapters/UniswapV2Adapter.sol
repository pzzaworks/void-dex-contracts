// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title IUniswapV2Router
/// @notice Interface for Uniswap V2 Router
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/// @title UniswapV2Adapter
/// @notice Adapter for Uniswap V2 and forks (SushiSwap, PancakeSwap, QuickSwap, etc.)
/// @dev Supports multi-hop routing
contract UniswapV2Adapter is IDexAdapter, Ownable {
    using SafeERC20 for IERC20;

    IUniswapV2Router public router;
    string public dexName;

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Events
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event RouterUpdated(address indexed newRouter);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Errors
    error InvalidRouter();
    error SwapFailed();
    error InsufficientOutput();
    error UnsupportedPair();

    constructor(address _router, string memory _dexName) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRouter();
        router = IUniswapV2Router(_router);
        dexName = _dexName;
    }

    /// @inheritdoc IDexAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata extraData
    ) external payable override returns (uint256 amountOut) {
        if (address(router) == address(0)) revert InvalidRouter();

        // Decode path from extraData
        address[] memory path = abi.decode(extraData, (address[]));

        // Validate path
        require(path.length >= 2, "Invalid path");
        require(path[0] == tokenIn, "Path must start with tokenIn");
        require(path[path.length - 1] == tokenOut, "Path must end with tokenOut");

        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Use forceApprove for USDT and similar tokens that require allowance to be 0 first
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Execute swap
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            msg.sender,
            block.timestamp + 300 // 5 minute deadline
        );

        amountOut = amounts[amounts.length - 1];

        if (amountOut < minAmountOut) revert InsufficientOutput();

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
        return amountOut;
    }

    /// @inheritdoc IDexAdapter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, bytes memory extraData) {
        if (address(router) == address(0)) return (0, "");

        // Build direct path (can be enhanced with intermediate tokens)
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        try router.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
            extraData = abi.encode(path);
        } catch {
            return (0, "");
        }
    }

    /// @inheritdoc IDexAdapter
    function getDexInfo() external view override returns (string memory name, address routerAddr) {
        return (dexName, address(router));
    }

    /// @inheritdoc IDexAdapter
    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool supported) {
        return supportedTokens[tokenIn] && supportedTokens[tokenOut];
    }

    // ============ Admin Functions ============

    /// @notice Update router address
    function setRouter(address _router, string memory _dexName) external onlyOwner {
        if (_router == address(0)) revert InvalidRouter();
        router = IUniswapV2Router(_router);
        dexName = _dexName;
        emit RouterUpdated(_router);
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

    /// @notice Emergency withdraw (supports both ETH and ERC20)
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
