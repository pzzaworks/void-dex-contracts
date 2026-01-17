// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title IBalancerVault
/// @notice Interface for Balancer V2 Vault
interface IBalancerVault {
    struct SingleSwap {
        bytes32 poolId;
        uint8 kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external returns (uint256);

    function queryBatchSwap(
        uint8 kind,
        SingleSwap[] memory swaps,
        address[] memory assets,
        FundManagement memory funds
    ) external returns (int256[] memory);
}

/// @title BalancerAdapter
/// @notice Adapter for Balancer V2 weighted pools
/// @dev Uses Balancer Vault for all swaps
contract BalancerAdapter is IDexAdapter, Ownable {
    using SafeERC20 for IERC20;

    IBalancerVault public vault;

    // Pool registry: keccak256(tokenA, tokenB) => poolId
    mapping(bytes32 => bytes32) public poolIds;

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Events
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 indexed poolId
    );
    event PoolRegistered(bytes32 indexed poolId, address tokenA, address tokenB);
    event VaultUpdated(address indexed newVault);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Errors
    error InvalidVault();
    error InvalidPool();
    error SwapFailed();
    error InsufficientOutput();
    error UnsupportedPair();

    constructor(address _vault) Ownable(msg.sender) {
        if (_vault == address(0)) revert InvalidVault();
        vault = IBalancerVault(_vault);
    }

    /// @inheritdoc IDexAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata extraData
    ) external payable override returns (uint256 amountOut) {
        if (address(vault) == address(0)) revert InvalidVault();

        // Decode poolId
        bytes32 poolId = abi.decode(extraData, (bytes32));

        if (poolId == bytes32(0)) revert InvalidPool();

        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Use forceApprove for USDT and similar tokens that require allowance to be 0 first
        IERC20(tokenIn).forceApprove(address(vault), amountIn);

        // Build swap params
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap({
            poolId: poolId,
            kind: uint8(IBalancerVault.SwapKind.GIVEN_IN),
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });

        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(msg.sender),
            toInternalBalance: false
        });

        // Execute swap
        amountOut = vault.swap(
            singleSwap,
            funds,
            minAmountOut,
            block.timestamp + 300 // 5 minute deadline
        );

        if (amountOut < minAmountOut) revert InsufficientOutput();

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, poolId);
        return amountOut;
    }

    /// @inheritdoc IDexAdapter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, bytes memory extraData) {
        if (address(vault) == address(0)) return (0, "");

        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 poolId = poolIds[pairKey];

        if (poolId == bytes32(0)) return (0, "");

        // Balancer quote requires queryBatchSwap which is not view
        // Return estimated output based on pool (simplified)
        // In production, use off-chain query or multicall

        extraData = abi.encode(poolId);
        amountOut = amountIn; // Placeholder - implement proper quote
    }

    /// @inheritdoc IDexAdapter
    function getDexInfo() external view override returns (string memory name, address vaultAddr) {
        return ("Balancer", address(vault));
    }

    /// @inheritdoc IDexAdapter
    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool supported) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        return poolIds[pairKey] != bytes32(0);
    }

    // ============ Admin Functions ============

    /// @notice Register a Balancer pool for a token pair
    function registerPool(
        address tokenA,
        address tokenB,
        bytes32 poolId
    ) external onlyOwner {
        if (poolId == bytes32(0)) revert InvalidPool();

        bytes32 keyAB = keccak256(abi.encodePacked(tokenA, tokenB));
        bytes32 keyBA = keccak256(abi.encodePacked(tokenB, tokenA));

        poolIds[keyAB] = poolId;
        poolIds[keyBA] = poolId;

        emit PoolRegistered(poolId, tokenA, tokenB);
    }

    /// @notice Batch register pools
    function batchRegisterPools(
        address[] calldata tokenAs,
        address[] calldata tokenBs,
        bytes32[] calldata poolIdsArray
    ) external onlyOwner {
        require(tokenAs.length == tokenBs.length, "Length mismatch");
        require(tokenAs.length == poolIdsArray.length, "Length mismatch");

        for (uint256 i = 0; i < tokenAs.length; i++) {
            this.registerPool(tokenAs[i], tokenBs[i], poolIdsArray[i]);
        }
    }

    /// @notice Update vault address
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidVault();
        vault = IBalancerVault(_vault);
        emit VaultUpdated(_vault);
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
