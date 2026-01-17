// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title ICurvePool
/// @notice Interface for Curve pools (simplified)
interface ICurvePool {
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);
}

/// @title CurveAdapter
/// @notice Adapter for Curve Finance stablecoin pools
/// @dev Optimized for low-slippage stablecoin swaps
contract CurveAdapter is IDexAdapter, Ownable {
    using SafeERC20 for IERC20;

    // Curve pool registry
    mapping(bytes32 => address) public pools; // keccak256(tokenA, tokenB) => pool
    mapping(bytes32 => PoolInfo) public poolInfo;

    struct PoolInfo {
        address pool;
        int128 tokenInIndex;
        int128 tokenOutIndex;
    }

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Events
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed pool
    );
    event PoolRegistered(address indexed pool, address tokenA, address tokenB);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Errors
    error InvalidPool();
    error SwapFailed();
    error InsufficientOutput();
    error UnsupportedPair();

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IDexAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata extraData
    ) external payable override returns (uint256 amountOut) {
        // Decode pool info
        (address pool, int128 i, int128 j) = abi.decode(extraData, (address, int128, int128));

        if (pool == address(0)) revert InvalidPool();

        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Use forceApprove for USDT and similar tokens that require allowance to be 0 first
        IERC20(tokenIn).forceApprove(pool, amountIn);

        // Execute swap on Curve pool
        ICurvePool curvePool = ICurvePool(pool);
        amountOut = curvePool.exchange(i, j, amountIn, minAmountOut);

        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Transfer output to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, pool);
        return amountOut;
    }

    /// @inheritdoc IDexAdapter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, bytes memory extraData) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        PoolInfo memory info = poolInfo[pairKey];

        if (info.pool == address(0)) return (0, "");

        try ICurvePool(info.pool).get_dy(info.tokenInIndex, info.tokenOutIndex, amountIn) returns (uint256 dy) {
            amountOut = dy;
            extraData = abi.encode(info.pool, info.tokenInIndex, info.tokenOutIndex);
        } catch {
            return (0, "");
        }
    }

    /// @inheritdoc IDexAdapter
    function getDexInfo() external pure override returns (string memory name, address router) {
        return ("Curve", address(0)); // Curve uses individual pools
    }

    /// @inheritdoc IDexAdapter
    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool supported) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        return poolInfo[pairKey].pool != address(0);
    }

    // ============ Admin Functions ============

    /// @notice Register a Curve pool for a token pair
    function registerPool(
        address tokenA,
        address tokenB,
        address pool,
        int128 indexA,
        int128 indexB
    ) external onlyOwner {
        if (pool == address(0)) revert InvalidPool();

        bytes32 keyAB = keccak256(abi.encodePacked(tokenA, tokenB));
        bytes32 keyBA = keccak256(abi.encodePacked(tokenB, tokenA));

        pools[keyAB] = pool;
        pools[keyBA] = pool;

        poolInfo[keyAB] = PoolInfo({
            pool: pool,
            tokenInIndex: indexA,
            tokenOutIndex: indexB
        });

        poolInfo[keyBA] = PoolInfo({
            pool: pool,
            tokenInIndex: indexB,
            tokenOutIndex: indexA
        });

        emit PoolRegistered(pool, tokenA, tokenB);
    }

    /// @notice Batch register pools
    function batchRegisterPools(
        address[] calldata tokenAs,
        address[] calldata tokenBs,
        address[] calldata poolAddrs,
        int128[] calldata indexAs,
        int128[] calldata indexBs
    ) external onlyOwner {
        require(tokenAs.length == tokenBs.length, "Length mismatch");
        require(tokenAs.length == poolAddrs.length, "Length mismatch");
        require(tokenAs.length == indexAs.length, "Length mismatch");
        require(tokenAs.length == indexBs.length, "Length mismatch");

        for (uint256 i = 0; i < tokenAs.length; i++) {
            this.registerPool(tokenAs[i], tokenBs[i], poolAddrs[i], indexAs[i], indexBs[i]);
        }
    }

    /// @notice Set token support
    function setTokenSupport(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
        emit TokenSupportUpdated(token, supported);
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
