// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWETH
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title IVoidDexRouter
interface IVoidDexRouter {
    struct RouteStep {
        bytes32 dexId;
        uint256 percentage;
        uint256 minAmountOut;
        bytes dexData;
    }

    function swapMultiRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minTotalAmountOut,
        RouteStep[] calldata routes
    ) external payable returns (uint256 totalAmountOut);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes32 dexId,
        bytes calldata dexData
    ) external payable returns (uint256 amountOut);
}

/// @title TestSwap
/// @notice Test script for VoidDexRouter swap on Sepolia
contract TestSwap is Script {
    // Sepolia addresses
    address constant VOID_DEX_ROUTER = 0xD4949Be390c68658D9Dc85b8F37faED53fa39Ae4;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDC = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Aave USDC on Sepolia
    address constant DAI = 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357;  // Aave DAI on Sepolia

    bytes32 constant UNISWAP_V3_ID = keccak256("uniswap_v3");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== VoidDex Swap Test ===");
        console.log("Deployer:", deployer);
        console.log("VoidDexRouter:", VOID_DEX_ROUTER);

        // Check ETH balance
        uint256 ethBalance = deployer.balance;
        console.log("ETH Balance:", ethBalance);

        if (ethBalance < 0.01 ether) {
            console.log("Not enough ETH! Need at least 0.01 ETH");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // Test 1: Simple swap using ETH -> WETH -> USDC via swap() function
        console.log("\n=== Test 1: Simple swap ETH -> USDC ===");
        testSimpleSwap(deployer);

        // Test 2: Multi-route swap (like RAILGUN uses)
        console.log("\n=== Test 2: Multi-route swap ETH -> USDC ===");
        testMultiRouteSwap(deployer);

        vm.stopBroadcast();
    }

    function testSimpleSwap(address deployer) internal {
        uint256 amountIn = 0.001 ether;

        // Get USDC balance before
        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        console.log("USDC Before:", usdcBefore);

        // Encode dexData for UniswapV3 - single hop with 0.3% fee
        // Format: (bool isMultiHop, bytes swapData)
        // For single hop: swapData = abi.encode(uint24 fee)
        bytes memory dexData = abi.encode(false, abi.encode(uint24(3000))); // 0.3% fee

        console.log("Swapping", amountIn, "wei ETH for USDC...");

        try IVoidDexRouter(VOID_DEX_ROUTER).swap{value: amountIn}(
            address(0), // tokenIn = ETH
            USDC,       // tokenOut
            amountIn,
            0,          // minAmountOut (0 for testing)
            UNISWAP_V3_ID,
            dexData
        ) returns (uint256 amountOut) {
            console.log("Swap successful! Got USDC:", amountOut);

            uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
            console.log("USDC After:", usdcAfter);
            console.log("USDC Received:", usdcAfter - usdcBefore);
        } catch Error(string memory reason) {
            console.log("Swap failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Swap failed with low-level error");
            console.logBytes(lowLevelData);
        }
    }

    function testMultiRouteSwap(address deployer) internal {
        uint256 amountIn = 0.001 ether;

        // Get USDC balance before
        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        console.log("USDC Before:", usdcBefore);

        // Create route steps - 100% through UniswapV3
        IVoidDexRouter.RouteStep[] memory routes = new IVoidDexRouter.RouteStep[](1);

        // Encode dexData for UniswapV3
        bytes memory dexData = abi.encode(false, abi.encode(uint24(3000))); // 0.3% fee

        routes[0] = IVoidDexRouter.RouteStep({
            dexId: UNISWAP_V3_ID,
            percentage: 10000, // 100%
            minAmountOut: 0,
            dexData: dexData
        });

        console.log("Swapping", amountIn, "wei ETH for USDC via swapMultiRoute...");

        try IVoidDexRouter(VOID_DEX_ROUTER).swapMultiRoute{value: amountIn}(
            address(0), // tokenIn = ETH
            USDC,       // tokenOut
            amountIn,
            0,          // minTotalAmountOut
            routes
        ) returns (uint256 totalAmountOut) {
            console.log("Multi-route swap successful! Got USDC:", totalAmountOut);

            uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
            console.log("USDC After:", usdcAfter);
            console.log("USDC Received:", usdcAfter - usdcBefore);
        } catch Error(string memory reason) {
            console.log("Multi-route swap failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Multi-route swap failed with low-level error");
            console.logBytes(lowLevelData);
        }
    }

    // Test with WETH directly (simulating what RelayAdapt does)
    function testWETHSwap() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Test WETH -> USDC (like RelayAdapt) ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        uint256 amountIn = 0.001 ether;

        // First wrap ETH to WETH
        console.log("Wrapping ETH to WETH...");
        IWETH(WETH).deposit{value: amountIn}();

        uint256 wethBalance = IWETH(WETH).balanceOf(deployer);
        console.log("WETH Balance:", wethBalance);

        // Approve router to spend WETH
        console.log("Approving router...");
        IWETH(WETH).approve(VOID_DEX_ROUTER, amountIn);

        // Get USDC balance before
        uint256 usdcBefore = IERC20(USDC).balanceOf(deployer);
        console.log("USDC Before:", usdcBefore);

        // Create route steps
        IVoidDexRouter.RouteStep[] memory routes = new IVoidDexRouter.RouteStep[](1);
        bytes memory dexData = abi.encode(false, abi.encode(uint24(3000)));

        routes[0] = IVoidDexRouter.RouteStep({
            dexId: UNISWAP_V3_ID,
            percentage: 10000,
            minAmountOut: 0,
            dexData: dexData
        });

        console.log("Swapping WETH for USDC...");

        try IVoidDexRouter(VOID_DEX_ROUTER).swapMultiRoute(
            WETH,  // tokenIn = WETH (not ETH)
            USDC,  // tokenOut
            amountIn,
            0,
            routes
        ) returns (uint256 totalAmountOut) {
            console.log("WETH swap successful! Got USDC:", totalAmountOut);

            uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
            console.log("USDC After:", usdcAfter);
        } catch Error(string memory reason) {
            console.log("WETH swap failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("WETH swap failed with low-level error");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }

    // Test the exact calldata that RAILGUN generates (for debugging)
    function testRailgunCalldata() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Test with exact RAILGUN calldata format ===");

        // Build the exact calldata that the frontend generates
        bytes memory dexData = abi.encode(false, abi.encode(uint24(3000)));

        IVoidDexRouter.RouteStep[] memory routes = new IVoidDexRouter.RouteStep[](1);
        routes[0] = IVoidDexRouter.RouteStep({
            dexId: UNISWAP_V3_ID,
            percentage: 10000,
            minAmountOut: 0,
            dexData: dexData
        });

        // Log the encoded calldata
        bytes memory swapCalldata = abi.encodeWithSelector(
            IVoidDexRouter.swapMultiRoute.selector,
            WETH,   // tokenIn
            USDC,   // tokenOut
            0.001 ether,  // amountIn
            0,      // minTotalAmountOut
            routes
        );

        console.log("Swap calldata:");
        console.logBytes(swapCalldata);

        vm.startBroadcast(deployerPrivateKey);

        // Wrap and approve
        IWETH(WETH).deposit{value: 0.001 ether}();
        IWETH(WETH).approve(VOID_DEX_ROUTER, 0.001 ether);

        // Call with low-level call to see exact error
        (bool success, bytes memory returnData) = VOID_DEX_ROUTER.call(swapCalldata);

        if (success) {
            uint256 amountOut = abi.decode(returnData, (uint256));
            console.log("Success! Amount out:", amountOut);
        } else {
            console.log("Failed!");
            console.logBytes(returnData);
        }

        vm.stopBroadcast();
    }
}
