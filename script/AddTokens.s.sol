// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";

/// @title AddTokens
/// @notice Script to add missing tokens to UniswapV3Adapter whitelist
contract AddTokens is Script {
    // Sepolia UniswapV3Adapter address - from API dex-contracts.ts
    address constant UNISWAP_V3_ADAPTER = 0x9d1bE60a7bCCc0c6883D05D280bDC0F879961324;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 chainId = block.chainid;

        console.log("=== Adding Missing Tokens ===");
        console.log("Chain ID:", chainId);
        console.log("UniswapV3Adapter:", UNISWAP_V3_ADAPTER);

        vm.startBroadcast(deployerPrivateKey);

        UniswapV3Adapter adapter = UniswapV3Adapter(payable(UNISWAP_V3_ADAPTER));

        if (chainId == 11155111) {
            // Sepolia tokens - all from API token-addresses.ts
            address USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            address USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
            address UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
            address LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
            address AAVE = 0x88541670E55cC00bEEFD87eB59EDd1b7C511AC9a;
            address GHO = 0xc4bF5CbDaBE595361438F8c6a187bDc330539c60;
            address EURS = 0x6d906e526a4e2Ca02097BA9d0caA3c382F52278E;

            console.log("Adding USDC:", USDC);
            adapter.setTokenSupport(USDC, true);

            console.log("Adding USDT:", USDT);
            adapter.setTokenSupport(USDT, true);

            console.log("Adding UNI:", UNI);
            adapter.setTokenSupport(UNI, true);

            console.log("Adding LINK:", LINK);
            adapter.setTokenSupport(LINK, true);

            console.log("Adding AAVE:", AAVE);
            adapter.setTokenSupport(AAVE, true);

            console.log("Adding GHO:", GHO);
            adapter.setTokenSupport(GHO, true);

            console.log("Adding EURS:", EURS);
            adapter.setTokenSupport(EURS, true);
        }

        vm.stopBroadcast();

        console.log("\n=== Tokens Added Successfully ===");
    }
}
