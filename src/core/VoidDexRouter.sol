// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/// @title IWETH
/// @notice Interface for WETH
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title VoidDexRouter
/// @notice VoidDex Multi-DEX Aggregator Router with Privacy Support
/// @dev Routes swaps through multiple DEX adapters with split routing
/// @dev Can be called directly OR as Railgun Adapt Contract for private swaps
contract VoidDexRouter is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant PERCENTAGE_BASE = 10000; // 100% = 10000

    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ============ State Variables ============

    // DEX Adapters
    mapping(bytes32 => address) public dexAdapters;
    bytes32[] public dexIds;

    // WETH for ETH handling
    IWETH public weth;

    // Fee configuration
    uint256 public feeBps = 5; // 0.05% default
    address public feeRecipient;
    mapping(address => bool) public feeExempt;

    // Operation counter
    uint256 private operationNonce;

    // ============ Structs ============

    /// @notice Route step for multi-DEX split routing
    struct RouteStep {
        bytes32 dexId;        // DEX adapter ID
        uint256 percentage;   // Percentage of input (10000 = 100%)
        uint256 minAmountOut; // Minimum output for this step
        bytes dexData;        // DEX-specific data (paths, pools, etc.)
    }

    /// @notice Single swap parameters
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes32 dexId;
        bytes dexData;
    }

    /// @notice Route result for quotes
    struct RouteResult {
        bytes32 dexId;
        address dexAdapter;
        uint256 amountOut;
        bytes extraData;
    }

    /// @notice Sequential hop step for multi-hop routing (A->B->C)
    struct SequentialStep {
        bytes32 dexId;        // DEX adapter ID for this hop
        address tokenOut;     // Output token for this hop
        uint256 minAmountOut; // Minimum output for this hop
        bytes dexData;        // DEX-specific data
    }

    // ============ Events ============

    event SwapExecuted(
        bytes32 indexed operationId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        bytes32 dexId
    );

    event MultiRouteSwapExecuted(
        bytes32 indexed operationId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 totalAmountOut,
        uint256 routeCount
    );

    event SequentialSwapExecuted(
        bytes32 indexed operationId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 hopCount
    );

    event DexAdapterRegistered(bytes32 indexed dexId, address indexed adapter, string name);
    event DexAdapterRemoved(bytes32 indexed dexId);
    event FeeConfigUpdated(uint256 feeBps, address feeRecipient);
    event WETHUpdated(address indexed weth);

    // ============ Errors ============

    error InvalidAdapter();
    error InvalidAmount();
    error InvalidPercentage();
    error InsufficientOutput();
    error InsufficientValue();
    error SwapFailed();
    error UnsupportedPair();
    error FeeTooHigh();
    error TransferFailed();
    error NoDexAdapters();
    error NoRoutes();

    // ============ Constructor ============

    constructor(address _weth, address _feeRecipient) {
        weth = IWETH(_weth);
        feeRecipient = _feeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    // ============ Main Swap Functions ============

    /// @notice Execute a multi-route split swap
    /// @dev Called by Railgun as Adapt Contract OR directly by users
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param tokenOut Output token
    /// @param amountIn Total input amount
    /// @param minTotalAmountOut Minimum total output (slippage protection)
    /// @param routes Array of route steps (splits)
    /// @return totalAmountOut Total output amount received
    function swapMultiRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minTotalAmountOut,
        RouteStep[] calldata routes
    ) external payable nonReentrant whenNotPaused returns (uint256 totalAmountOut) {
        if (amountIn == 0) revert InvalidAmount();
        if (routes.length == 0) revert NoRoutes();

        bytes32 operationId = _generateOperationId();

        // Validate percentages sum to 100%
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < routes.length; i++) {
            totalPercentage += routes[i].percentage;
        }
        if (totalPercentage != PERCENTAGE_BASE) revert InvalidPercentage();

        // Calculate fee
        uint256 fee = 0;
        uint256 amountAfterFee = amountIn;

        if (!feeExempt[msg.sender] && feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountAfterFee = amountIn - fee;
        }

        // Handle input token
        address actualTokenIn = _handleInputToken(tokenIn, amountIn, fee);
        address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

        // Execute split routing
        totalAmountOut = _executeMultiRoute(
            actualTokenIn,
            actualTokenOut,
            amountAfterFee,
            routes
        );

        if (totalAmountOut < minTotalAmountOut) revert InsufficientOutput();

        // Handle output token
        _handleOutputToken(tokenOut, totalAmountOut, msg.sender);

        emit MultiRouteSwapExecuted(
            operationId,
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            totalAmountOut,
            routes.length
        );

        return totalAmountOut;
    }

    /// @notice Simple single-route swap (convenience function)
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output
    /// @param dexId DEX adapter ID
    /// @param dexData DEX-specific data
    /// @return amountOut Output amount
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes32 dexId,
        bytes calldata dexData
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmount();

        bytes32 operationId = _generateOperationId();

        // Calculate fee
        uint256 fee = 0;
        uint256 amountAfterFee = amountIn;

        if (!feeExempt[msg.sender] && feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountAfterFee = amountIn - fee;
        }

        // Handle input token
        address actualTokenIn = _handleInputToken(tokenIn, amountIn, fee);
        address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

        // Get adapter
        address adapter = dexAdapters[dexId];
        if (adapter == address(0)) revert InvalidAdapter();

        // Execute swap - use forceApprove for USDT compatibility
        IERC20(actualTokenIn).forceApprove(adapter, amountAfterFee);

        amountOut = IDexAdapter(adapter).swap(
            actualTokenIn,
            actualTokenOut,
            amountAfterFee,
            minAmountOut,
            dexData
        );

        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Handle output token
        _handleOutputToken(tokenOut, amountOut, msg.sender);

        emit SwapExecuted(
            operationId,
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            fee,
            dexId
        );

        return amountOut;
    }

    /// @notice Find best single route automatically
    /// @param tokenIn Input token (address(0) for ETH)
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output
    /// @return amountOut Output amount
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmount();

        // Find best route
        (bytes32 bestDexId, address bestAdapter, uint256 expectedOut, bytes memory dexData) =
            _findBestRoute(tokenIn, tokenOut, amountIn);

        if (bestAdapter == address(0)) revert NoDexAdapters();
        if (expectedOut < minAmountOut) revert InsufficientOutput();

        bytes32 operationId = _generateOperationId();

        // Calculate fee
        uint256 fee = 0;
        uint256 amountAfterFee = amountIn;

        if (!feeExempt[msg.sender] && feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountAfterFee = amountIn - fee;
        }

        // Handle input token
        address actualTokenIn = _handleInputToken(tokenIn, amountIn, fee);
        address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

        // Execute swap - use forceApprove for USDT compatibility
        IERC20(actualTokenIn).forceApprove(bestAdapter, amountAfterFee);

        amountOut = IDexAdapter(bestAdapter).swap(
            actualTokenIn,
            actualTokenOut,
            amountAfterFee,
            minAmountOut,
            dexData
        );

        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Handle output token
        _handleOutputToken(tokenOut, amountOut, msg.sender);

        emit SwapExecuted(
            operationId,
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            fee,
            bestDexId
        );

        return amountOut;
    }

    /// @notice Execute a sequential multi-hop swap (A->B->C->D)
    /// @dev Each step uses the output of the previous step as input
    /// @param tokenIn Initial input token
    /// @param amountIn Initial input amount
    /// @param minFinalAmountOut Minimum final output (slippage protection)
    /// @param steps Array of sequential hop steps
    /// @return finalAmountOut Final output amount
    function swapSequential(
        address tokenIn,
        uint256 amountIn,
        uint256 minFinalAmountOut,
        SequentialStep[] calldata steps
    ) external payable nonReentrant whenNotPaused returns (uint256 finalAmountOut) {
        if (amountIn == 0) revert InvalidAmount();
        if (steps.length == 0) revert NoRoutes();

        bytes32 operationId = _generateOperationId();

        // Calculate fee on initial input
        uint256 fee = 0;
        uint256 amountAfterFee = amountIn;

        if (!feeExempt[msg.sender] && feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountAfterFee = amountIn - fee;
        }

        // Handle initial input token
        address currentTokenIn = _handleInputToken(tokenIn, amountIn, fee);
        uint256 currentAmount = amountAfterFee;

        // Execute each hop sequentially
        for (uint256 i = 0; i < steps.length; i++) {
            SequentialStep calldata step = steps[i];

            // Get adapter
            address adapter = dexAdapters[step.dexId];
            if (adapter == address(0)) revert InvalidAdapter();

            // Determine output token (use WETH for ETH)
            address actualTokenOut = step.tokenOut == address(0) ? address(weth) : step.tokenOut;

            // Approve and execute swap - use forceApprove for USDT compatibility
            IERC20(currentTokenIn).forceApprove(adapter, currentAmount);

            uint256 amountOut = IDexAdapter(adapter).swap(
                currentTokenIn,
                actualTokenOut,
                currentAmount,
                step.minAmountOut,
                step.dexData
            );

            if (amountOut < step.minAmountOut) revert InsufficientOutput();

            // Update for next iteration
            currentTokenIn = actualTokenOut;
            currentAmount = amountOut;
        }

        finalAmountOut = currentAmount;

        if (finalAmountOut < minFinalAmountOut) revert InsufficientOutput();

        // Handle final output token (last step's tokenOut)
        address finalTokenOut = steps[steps.length - 1].tokenOut;
        _handleOutputToken(finalTokenOut, finalAmountOut, msg.sender);

        emit SequentialSwapExecuted(
            operationId,
            msg.sender,
            tokenIn,
            finalTokenOut,
            amountIn,
            finalAmountOut,
            steps.length
        );

        return finalAmountOut;
    }

    // ============ Quote Functions ============

    /// @notice Get best route for a swap
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @return result Best route result
    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (RouteResult memory result) {
        (bytes32 bestDexId, address bestAdapter, uint256 amountOut, bytes memory extraData) =
            _findBestRoute(tokenIn, tokenOut, amountIn);

        result = RouteResult({
            dexId: bestDexId,
            dexAdapter: bestAdapter,
            amountOut: amountOut,
            extraData: extraData
        });
    }

    /// @notice Get quotes from all DEX adapters
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @return results Array of route results
    function getAllQuotes(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (RouteResult[] memory results) {
        results = new RouteResult[](dexIds.length);

        address actualTokenIn = tokenIn == address(0) ? address(weth) : tokenIn;
        address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

        for (uint256 i = 0; i < dexIds.length; i++) {
            bytes32 dexId = dexIds[i];
            address adapter = dexAdapters[dexId];

            if (adapter == address(0)) continue;

            try IDexAdapter(adapter).getQuote(actualTokenIn, actualTokenOut, amountIn) returns (
                uint256 amountOut,
                bytes memory extraData
            ) {
                results[i] = RouteResult({
                    dexId: dexId,
                    dexAdapter: adapter,
                    amountOut: amountOut,
                    extraData: extraData
                });
            } catch {
                // Skip if quote fails
            }
        }
    }

    /// @notice Calculate fee for an amount
    /// @param user User address
    /// @param amount Amount
    /// @return fee Fee amount
    function calculateFee(address user, uint256 amount) external view returns (uint256 fee) {
        if (feeExempt[user]) return 0;
        return (amount * feeBps) / 10000;
    }

    // ============ View Functions ============

    /// @notice Get all registered DEX adapters
    function getAllDexAdapters() external view returns (bytes32[] memory ids, address[] memory adapters) {
        uint256 len = dexIds.length;
        ids = new bytes32[](len);
        adapters = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            ids[i] = dexIds[i];
            adapters[i] = dexAdapters[dexIds[i]];
        }
    }

    /// @notice Get DEX adapter info
    function getDexInfo(bytes32 dexId) external view returns (string memory name, address router) {
        address adapter = dexAdapters[dexId];
        if (adapter == address(0)) return ("", address(0));
        return IDexAdapter(adapter).getDexInfo();
    }

    /// @notice Check if a pair is supported on any DEX
    function isPairSupported(address tokenIn, address tokenOut) external view returns (bool) {
        address actualIn = tokenIn == address(0) ? address(weth) : tokenIn;
        address actualOut = tokenOut == address(0) ? address(weth) : tokenOut;

        for (uint256 i = 0; i < dexIds.length; i++) {
            address adapter = dexAdapters[dexIds[i]];
            if (adapter != address(0)) {
                try IDexAdapter(adapter).isPairSupported(actualIn, actualOut) returns (bool supported) {
                    if (supported) return true;
                } catch {}
            }
        }
        return false;
    }

    // ============ Internal Functions ============

    /// @notice Execute multi-route split swap
    function _executeMultiRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        RouteStep[] calldata routes
    ) internal returns (uint256 totalAmountOut) {
        for (uint256 i = 0; i < routes.length; i++) {
            RouteStep calldata route = routes[i];

            // Get adapter
            address adapter = dexAdapters[route.dexId];
            if (adapter == address(0)) revert InvalidAdapter();

            // Calculate split amount
            uint256 splitAmount = (amountIn * route.percentage) / PERCENTAGE_BASE;
            if (splitAmount == 0) continue;

            // Execute swap for this split - use forceApprove for USDT compatibility
            IERC20(tokenIn).forceApprove(adapter, splitAmount);

            uint256 amountOut = IDexAdapter(adapter).swap(
                tokenIn,
                tokenOut,
                splitAmount,
                route.minAmountOut,
                route.dexData
            );

            if (amountOut < route.minAmountOut) revert InsufficientOutput();

            totalAmountOut += amountOut;
        }
    }

    /// @notice Handle input token (ETH wrapping, fee deduction, transfers)
    function _handleInputToken(
        address tokenIn,
        uint256 amountIn,
        uint256 fee
    ) internal returns (address actualTokenIn) {
        if (tokenIn == address(0)) {
            // ETH input
            if (msg.value < amountIn) revert InsufficientValue();
            weth.deposit{value: amountIn}();
            actualTokenIn = address(weth);

            // Transfer fee
            if (fee > 0 && feeRecipient != address(0)) {
                IERC20(address(weth)).safeTransfer(feeRecipient, fee);
            }
        } else {
            // ERC20 input
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            actualTokenIn = tokenIn;

            // Transfer fee
            if (fee > 0 && feeRecipient != address(0)) {
                IERC20(tokenIn).safeTransfer(feeRecipient, fee);
            }
        }
    }

    /// @notice Handle output token (ETH unwrapping, transfers)
    function _handleOutputToken(
        address tokenOut,
        uint256 amountOut,
        address recipient
    ) internal {
        if (tokenOut == address(0)) {
            // ETH output
            weth.withdraw(amountOut);
            (bool sent,) = recipient.call{value: amountOut}("");
            if (!sent) revert TransferFailed();
        } else {
            // ERC20 output
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
        }
    }

    /// @notice Find best route across all DEX adapters
    function _findBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (bytes32 bestDexId, address bestAdapter, uint256 bestAmountOut, bytes memory bestExtraData) {
        address actualTokenIn = tokenIn == address(0) ? address(weth) : tokenIn;
        address actualTokenOut = tokenOut == address(0) ? address(weth) : tokenOut;

        for (uint256 i = 0; i < dexIds.length; i++) {
            bytes32 dexId = dexIds[i];
            address adapter = dexAdapters[dexId];

            if (adapter == address(0)) continue;

            try IDexAdapter(adapter).getQuote(actualTokenIn, actualTokenOut, amountIn) returns (
                uint256 amountOut,
                bytes memory extraData
            ) {
                if (amountOut > bestAmountOut) {
                    bestAmountOut = amountOut;
                    bestDexId = dexId;
                    bestAdapter = adapter;
                    bestExtraData = extraData;
                }
            } catch {
                // Skip if quote fails
            }
        }
    }

    /// @notice Generate unique operation ID
    function _generateOperationId() internal returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, operationNonce++));
    }

    // ============ Admin Functions ============

    /// @notice Register a DEX adapter
    function registerDexAdapter(bytes32 dexId, address adapter) external onlyRole(ADMIN_ROLE) {
        if (adapter == address(0)) revert InvalidAdapter();

        if (dexAdapters[dexId] == address(0)) {
            dexIds.push(dexId);
        }
        dexAdapters[dexId] = adapter;

        (string memory name, ) = IDexAdapter(adapter).getDexInfo();
        emit DexAdapterRegistered(dexId, adapter, name);
    }

    /// @notice Remove a DEX adapter
    function removeDexAdapter(bytes32 dexId) external onlyRole(ADMIN_ROLE) {
        if (dexAdapters[dexId] == address(0)) revert InvalidAdapter();

        delete dexAdapters[dexId];

        // Remove from array
        for (uint256 i = 0; i < dexIds.length; i++) {
            if (dexIds[i] == dexId) {
                dexIds[i] = dexIds[dexIds.length - 1];
                dexIds.pop();
                break;
            }
        }

        emit DexAdapterRemoved(dexId);
    }

    /// @notice Update fee configuration
    function setFeeConfig(uint256 _feeBps, address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        if (_feeBps > 100) revert FeeTooHigh(); // Max 1%
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeConfigUpdated(_feeBps, _feeRecipient);
    }

    /// @notice Set fee exemption
    function setFeeExemption(address account, bool exempt) external onlyRole(ADMIN_ROLE) {
        feeExempt[account] = exempt;
    }

    /// @notice Update WETH address
    function setWETH(address _weth) external onlyRole(ADMIN_ROLE) {
        weth = IWETH(_weth);
        emit WETHUpdated(_weth);
    }

    /// @notice Pause router
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpause router
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Receive ETH
    receive() external payable {}
}
