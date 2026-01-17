// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VoidDexRouter} from "../src/core/VoidDexRouter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";

/// @title UpgradeAll
/// @notice Deploy new Router and Adapter with forceApprove fix
contract UpgradeAll is Script {
    bytes32 public constant UNISWAP_V3_ID = keccak256("uniswap_v3");

    // Sepolia addresses
    address constant UNISWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant UNISWAP_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        require(chainId == 11155111, "Only Sepolia supported");

        console.log("=== Full Upgrade: Router + Adapter ===");
        console.log("Chain ID:", chainId);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new Router
        VoidDexRouter router = new VoidDexRouter(WETH, deployer);
        console.log("New VoidDexRouter deployed:", address(router));

        // 2. Deploy new Adapter
        UniswapV3Adapter adapter = new UniswapV3Adapter(
            UNISWAP_ROUTER,
            UNISWAP_QUOTER,
            WETH
        );
        console.log("New UniswapV3Adapter deployed:", address(adapter));

        // 3. Register adapter with router
        router.registerDexAdapter(UNISWAP_V3_ID, address(adapter));
        console.log("Adapter registered with router");

        // 4. Add all Sepolia tokens to adapter whitelist
        address USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        address DAI = 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357;
        address USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
        address UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        address LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
        address AAVE = 0x88541670E55cC00bEEFD87eB59EDd1b7C511AC9a;
        address GHO = 0xc4bF5CbDaBE595361438F8c6a187bDc330539c60;
        address EURS = 0x6d906e526a4e2Ca02097BA9d0caA3c382F52278E;

        adapter.setTokenSupport(USDC, true);
        adapter.setTokenSupport(DAI, true);
        adapter.setTokenSupport(USDT, true);
        adapter.setTokenSupport(UNI, true);
        adapter.setTokenSupport(LINK, true);
        adapter.setTokenSupport(AAVE, true);
        adapter.setTokenSupport(GHO, true);
        adapter.setTokenSupport(EURS, true);
        console.log("All tokens added to whitelist");

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("Router:", address(router));
        console.log("Adapter:", address(adapter));
    }
}
