// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VoidDexRouter} from "../src/core/VoidDexRouter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";

/// @title DeployVoidDex
/// @notice Deployment script for VoidDex DEX Aggregator
contract DeployVoidDex is Script {
    // DEX IDs
    bytes32 public constant UNISWAP_V3_ID = keccak256("uniswap_v3");

    // Deployed contracts
    VoidDexRouter public router;
    UniswapV3Adapter public uniswapAdapter;

    // Chain-specific addresses
    struct ChainConfig {
        address weth;
        address uniswapRouter;
        address uniswapQuoter;
    }

    function getChainConfig(uint256 chainId) internal pure returns (ChainConfig memory) {
        if (chainId == 1) {
            // Ethereum Mainnet
            return ChainConfig({
                weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                uniswapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                uniswapQuoter: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
            });
        } else if (chainId == 137) {
            // Polygon
            return ChainConfig({
                weth: 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270, // WMATIC
                uniswapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                uniswapQuoter: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
            });
        } else if (chainId == 42161) {
            // Arbitrum
            return ChainConfig({
                weth: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
                uniswapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                uniswapQuoter: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
            });
        } else if (chainId == 11155111) {
            // Sepolia Testnet
            return ChainConfig({
                weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                uniswapRouter: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E,
                uniswapQuoter: 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3
            });
        } else {
            // Unknown chain - will fail
            revert("Unsupported chain");
        }
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        ChainConfig memory config = getChainConfig(chainId);

        console.log("=== VoidDex Deployment ===");
        console.log("Chain ID:", chainId);
        console.log("Deployer:", deployer);
        console.log("WETH:", config.weth);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy VoidDexRouter
        router = new VoidDexRouter(config.weth, deployer);
        console.log("VoidDexRouter deployed:", address(router));

        // 2. Deploy UniswapV3Adapter
        uniswapAdapter = new UniswapV3Adapter(
            config.uniswapRouter,
            config.uniswapQuoter,
            config.weth
        );
        console.log("UniswapV3Adapter deployed:", address(uniswapAdapter));

        // 3. Register adapter with router
        router.registerDexAdapter(UNISWAP_V3_ID, address(uniswapAdapter));
        console.log("UniswapV3Adapter registered");

        // 4. Setup token support
        _setupTokenSupport(chainId, config);

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Deployment Summary ===");
        console.log("VoidDexRouter:", address(router));
        console.log("UniswapV3Adapter:", address(uniswapAdapter));
    }

    function _setupTokenSupport(uint256 chainId, ChainConfig memory config) internal {
        // Native token always supported
        uniswapAdapter.setTokenSupport(address(0), true);
        uniswapAdapter.setTokenSupport(config.weth, true);

        if (chainId == 1) {
            // Ethereum Mainnet tokens
            address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
            address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
            address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

            uniswapAdapter.setTokenSupport(USDC, true);
            uniswapAdapter.setTokenSupport(USDT, true);
            uniswapAdapter.setTokenSupport(DAI, true);
        } else if (chainId == 137) {
            // Polygon tokens
            address USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
            address USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

            uniswapAdapter.setTokenSupport(USDC, true);
            uniswapAdapter.setTokenSupport(USDT, true);
        } else if (chainId == 42161) {
            // Arbitrum tokens
            address USDC = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
            address USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

            uniswapAdapter.setTokenSupport(USDC, true);
            uniswapAdapter.setTokenSupport(USDT, true);
        } else if (chainId == 11155111) {
            // Sepolia tokens - all from API token-addresses.ts
            address USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            address DAI = 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357;
            address USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
            address UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
            address LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
            address AAVE = 0x88541670E55cC00bEEFD87eB59EDd1b7C511AC9a;
            address GHO = 0xc4bF5CbDaBE595361438F8c6a187bDc330539c60;
            address EURS = 0x6d906e526a4e2Ca02097BA9d0caA3c382F52278E;

            uniswapAdapter.setTokenSupport(USDC, true);
            uniswapAdapter.setTokenSupport(DAI, true);
            uniswapAdapter.setTokenSupport(USDT, true);
            uniswapAdapter.setTokenSupport(UNI, true);
            uniswapAdapter.setTokenSupport(LINK, true);
            uniswapAdapter.setTokenSupport(AAVE, true);
            uniswapAdapter.setTokenSupport(GHO, true);
            uniswapAdapter.setTokenSupport(EURS, true);
        }
    }
}
