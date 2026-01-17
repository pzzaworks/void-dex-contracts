// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title Currency
/// @notice Currency library for handling native ETH and ERC20 tokens
type Currency is address;

/// @title PoolKey
/// @notice Pool identification struct for Uniswap V4
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title IPoolManager
/// @notice Interface for Uniswap V4 PoolManager (singleton)
interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (int256, int256);

    function unlock(bytes calldata data) external returns (bytes memory);
}

/// @title IV4Router
/// @notice Interface for Uniswap V4 Router
interface IV4Router {
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMinimum;
        bytes hookData;
    }

    function swapExactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/// @title UniswapV4Adapter
/// @notice Adapter for Uniswap V4 pools using singleton PoolManager
/// @dev Uses V4's new architecture with hooks and flash accounting
contract UniswapV4Adapter is IDexAdapter, Ownable {
    using SafeERC20 for IERC20;

    IPoolManager public poolManager;
    IV4Router public router;

    // Pool registry: keccak256(currency0, currency1, fee) => PoolKey
    mapping(bytes32 => PoolKey) public poolKeys;

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Events
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 indexed poolKeyHash
    );
    event PoolRegistered(
        bytes32 indexed poolKeyHash,
        address currency0,
        address currency1,
        uint24 fee
    );
    event PoolManagerUpdated(address indexed newPoolManager);
    event RouterUpdated(address indexed newRouter);
    event TokenSupportUpdated(address indexed token, bool supported);

    // Errors
    error InvalidPoolManager();
    error InvalidRouter();
    error InvalidPool();
    error SwapFailed();
    error InsufficientOutput();
    error UnsupportedPair();

    constructor(address _poolManager, address _router) Ownable(msg.sender) {
        if (_poolManager == address(0)) revert InvalidPoolManager();
        if (_router == address(0)) revert InvalidRouter();
        poolManager = IPoolManager(_poolManager);
        router = IV4Router(_router);
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

        // Decode PoolKey and swap direction
        (PoolKey memory key, bool zeroForOne) = abi.decode(
            extraData,
            (PoolKey, bool)
        );

        // Validate pool key
        bytes32 poolKeyHash = getPoolKeyHash(key);
        if (Currency.unwrap(poolKeys[poolKeyHash].currency0) == address(0)) {
            revert InvalidPool();
        }

        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Use forceApprove for USDT and similar tokens that require allowance to be 0 first
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Execute swap through V4 Router
        IV4Router.ExactInputSingleParams memory params = IV4Router
            .ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: ""
            });

        amountOut = router.swapExactInputSingle(params);

        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Transfer output tokens to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, poolKeyHash);
        return amountOut;
    }

    /// @inheritdoc IDexAdapter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, bytes memory extraData) {
        if (address(poolManager) == address(0)) return (0, "");

        // Try to find a registered pool
        (PoolKey memory key, bool zeroForOne) = findPoolKey(tokenIn, tokenOut);

        bytes32 poolKeyHash = getPoolKeyHash(key);
        if (Currency.unwrap(poolKeys[poolKeyHash].currency0) == address(0)) {
            return (0, "");
        }

        // V4 doesn't have a simple quote function due to flash accounting
        // This is a simplified estimation - in production, use off-chain simulation
        // or implement a quoter contract
        amountOut = amountIn; // Placeholder

        extraData = abi.encode(key, zeroForOne);
    }

    /// @inheritdoc IDexAdapter
    function getDexInfo()
        external
        view
        override
        returns (string memory name, address managerAddr)
    {
        return ("Uniswap V4", address(poolManager));
    }

    /// @inheritdoc IDexAdapter
    function isPairSupported(
        address tokenIn,
        address tokenOut
    ) external view override returns (bool supported) {
        (PoolKey memory key, ) = findPoolKey(tokenIn, tokenOut);
        bytes32 poolKeyHash = getPoolKeyHash(key);
        return Currency.unwrap(poolKeys[poolKeyHash].currency0) != address(0);
    }

    // ============ Admin Functions ============

    /// @notice Register a Uniswap V4 pool
    function registerPool(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) external onlyOwner {
        // Ensure currency0 < currency1
        if (currency0 >= currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });

        bytes32 poolKeyHash = getPoolKeyHash(key);
        poolKeys[poolKeyHash] = key;

        emit PoolRegistered(poolKeyHash, currency0, currency1, fee);
    }

    /// @notice Batch register pools
    function batchRegisterPools(
        address[] calldata currency0s,
        address[] calldata currency1s,
        uint24[] calldata fees,
        int24[] calldata tickSpacings,
        address[] calldata hooksAddrs
    ) external onlyOwner {
        require(currency0s.length == currency1s.length, "Length mismatch");
        require(currency0s.length == fees.length, "Length mismatch");
        require(currency0s.length == tickSpacings.length, "Length mismatch");
        require(currency0s.length == hooksAddrs.length, "Length mismatch");

        for (uint256 i = 0; i < currency0s.length; i++) {
            this.registerPool(
                currency0s[i],
                currency1s[i],
                fees[i],
                tickSpacings[i],
                hooksAddrs[i]
            );
        }
    }

    /// @notice Update pool manager address
    function setPoolManager(address _poolManager) external onlyOwner {
        if (_poolManager == address(0)) revert InvalidPoolManager();
        poolManager = IPoolManager(_poolManager);
        emit PoolManagerUpdated(_poolManager);
    }

    /// @notice Update router address
    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert InvalidRouter();
        router = IV4Router(_router);
        emit RouterUpdated(_router);
    }

    /// @notice Set token support
    function setTokenSupport(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
        emit TokenSupportUpdated(token, supported);
    }

    /// @notice Emergency withdraw (supports both ETH and ERC20)
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ============ Internal Functions ============

    /// @notice Get pool key hash for storage lookup
    function getPoolKeyHash(PoolKey memory key) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    Currency.unwrap(key.currency0),
                    Currency.unwrap(key.currency1),
                    key.fee,
                    key.tickSpacing,
                    key.hooks
                )
            );
    }

    /// @notice Find pool key for a token pair (tries multiple fees)
    function findPoolKey(
        address tokenIn,
        address tokenOut
    ) internal view returns (PoolKey memory key, bool zeroForOne) {
        // Determine swap direction
        address currency0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address currency1 = tokenIn < tokenOut ? tokenOut : tokenIn;
        zeroForOne = tokenIn == currency0;

        // Try common fee tiers (3000 = 0.3%, 500 = 0.05%, 10000 = 1%)
        uint24[3] memory commonFees = [uint24(3000), uint24(500), uint24(10000)];

        for (uint256 i = 0; i < commonFees.length; i++) {
            PoolKey memory testKey = PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: commonFees[i],
                tickSpacing: getTickSpacingForFee(commonFees[i]),
                hooks: address(0)
            });

            bytes32 poolKeyHash = getPoolKeyHash(testKey);
            if (Currency.unwrap(poolKeys[poolKeyHash].currency0) != address(0)) {
                return (poolKeys[poolKeyHash], zeroForOne);
            }
        }

        // Return empty key if no pool found
        return (key, zeroForOne);
    }

    /// @notice Get tick spacing for fee tier
    function getTickSpacingForFee(uint24 fee) internal pure returns (int24) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60; // Default
    }
}
