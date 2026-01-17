// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title ISwapRouter
/// @notice Interface for Uniswap V3 SwapRouter
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title IQuoterV2
/// @notice Interface for Uniswap V3 QuoterV2
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @title IWETH
/// @notice Interface for WETH
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title UniswapV3Adapter
/// @notice Adapter for Uniswap V3
/// @dev Supports single-hop and multi-hop swaps
contract UniswapV3Adapter is IDexAdapter, Ownable {
    using SafeERC20 for IERC20;

    // Uniswap V3 contracts
    // Ethereum: SwapRouter 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Polygon: 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Arbitrum: 0xE592427A0AEce92De3Edee1F18E0157C05861564
    ISwapRouter public swapRouter;
    IQuoterV2 public quoter;
    IWETH public weth;

    // Fee tiers
    uint24 public constant FEE_LOW = 500; // 0.05%
    uint24 public constant FEE_MEDIUM = 3000; // 0.3%
    uint24 public constant FEE_HIGH = 10000; // 1%

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
    event ContractsUpdated(address router, address quoter, address weth);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Errors
    error InvalidRouter();
    error SwapFailed();
    error InsufficientOutput();
    error UnsupportedPair();

    constructor(address _router, address _quoter, address _weth) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRouter();
        swapRouter = ISwapRouter(_router);
        quoter = IQuoterV2(_quoter);
        weth = IWETH(_weth);

        // ETH always supported
        supportedTokens[address(0)] = true;
        supportedTokens[_weth] = true;
    }

    /// @inheritdoc IDexAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata extraData
    ) external payable override returns (uint256 amountOut) {
        if (address(swapRouter) == address(0)) revert InvalidRouter();

        // Decode swap type and params
        (bool isMultiHop, bytes memory swapData) = abi.decode(extraData, (bool, bytes));

        if (tokenIn == address(0)) {
            // Wrap ETH to WETH
            weth.deposit{value: amountIn}();
            IERC20(address(weth)).forceApprove(address(swapRouter), amountIn);
            tokenIn = address(weth);
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            // Use forceApprove for USDT and similar tokens that require allowance to be 0 first
            IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        }

        if (isMultiHop) {
            // Multi-hop swap
            (bytes memory path) = abi.decode(swapData, (bytes));

            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path: path,
                recipient: tokenOut == address(0) ? address(this) : msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            });

            amountOut = swapRouter.exactInput(params);
        } else {
            // Single-hop swap
            (uint24 fee) = abi.decode(swapData, (uint24));

            address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: actualTokenOut,
                fee: fee,
                recipient: tokenOut == address(0) ? address(this) : msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            amountOut = swapRouter.exactInputSingle(params);
        }

        // Unwrap WETH if output is ETH
        if (tokenOut == address(0)) {
            weth.withdraw(amountOut);
            (bool sent,) = msg.sender.call{value: amountOut}("");
            require(sent, "ETH transfer failed");
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
        if (address(quoter) == address(0)) return (0, "");

        // Convert ETH to WETH for quote
        address actualTokenIn = tokenIn == address(0) ? address(weth) : tokenIn;
        address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

        // Try different fee tiers and find best quote
        uint256 bestAmount = 0;
        uint24 bestFee = FEE_MEDIUM;

        uint24[3] memory fees = [FEE_LOW, FEE_MEDIUM, FEE_HIGH];

        for (uint256 i = 0; i < fees.length; i++) {
            try quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: actualTokenIn,
                    tokenOut: actualTokenOut,
                    amountIn: amountIn,
                    fee: fees[i],
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 amount, uint160, uint32, uint256) {
                if (amount > bestAmount) {
                    bestAmount = amount;
                    bestFee = fees[i];
                }
            } catch {
                // Skip if this fee tier doesn't have liquidity
            }
        }

        amountOut = bestAmount;
        extraData = abi.encode(false, abi.encode(bestFee)); // false = single hop
    }

    /// @inheritdoc IDexAdapter
    function getDexInfo() external view override returns (string memory name, address router) {
        return ("Uniswap V3", address(swapRouter));
    }

    /// @inheritdoc IDexAdapter
    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool supported) {
        // For Uniswap V3, most pairs are supported if tokens are whitelisted
        address actualIn = tokenIn == address(0) ? address(weth) : tokenIn;
        address actualOut = tokenOut == address(0) ? address(weth) : tokenOut;
        return supportedTokens[actualIn] && supportedTokens[actualOut];
    }

    // ============ Admin Functions ============

    /// @notice Update contracts
    function setContracts(address _router, address _quoter, address _weth) external onlyOwner {
        if (_router == address(0)) revert InvalidRouter();
        swapRouter = ISwapRouter(_router);
        quoter = IQuoterV2(_quoter);
        weth = IWETH(_weth);
        emit ContractsUpdated(_router, _quoter, _weth);
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
