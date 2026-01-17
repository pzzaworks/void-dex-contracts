// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDexAdapter
/// @notice Interface for DEX adapters (Uniswap, SushiSwap, Curve, etc.)
/// @dev Used by VoidDexRouter to execute swaps on different DEXes
interface IDexAdapter {
    /// @notice Swap tokens
    /// @param tokenIn Input token address (WETH for native ETH)
    /// @param tokenOut Output token address
    /// @param amountIn Amount of input tokens
    /// @param minAmountOut Minimum output amount (slippage protection)
    /// @param extraData DEX-specific data (routes, pools, fee tiers, etc.)
    /// @return amountOut Actual output amount received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata extraData
    ) external payable returns (uint256 amountOut);

    /// @notice Get quote for a swap
    /// @dev May make external calls, so not marked as view
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Amount of input tokens
    /// @return amountOut Expected output amount
    /// @return extraData Data to pass to swap function
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (uint256 amountOut, bytes memory extraData);

    /// @notice Get DEX info
    /// @return name DEX name (e.g., "Uniswap V3")
    /// @return router Router contract address
    function getDexInfo() external view returns (string memory name, address router);

    /// @notice Check if a token pair is supported
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @return supported Whether the pair is supported
    function isPairSupported(address tokenIn, address tokenOut) external view returns (bool supported);
}
