<p align="center">
  <img src="./assets/void-dex-logo.svg" alt="VoidDex" width="200" />
</p>

Smart contracts for VoidDex DEX aggregator. Includes the VoidDexRouter and DEX adapter contracts for executing swaps across multiple protocols.

[![Solidity](https://img.shields.io/badge/Solidity-363636?logo=solidity&logoColor=white)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-000000?logo=ethereum&logoColor=white)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Installation

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install

# Build
forge build

# Test
forge test
```

## Contracts

| Contract | Description |
|----------|-------------|
| VoidDexRouter | Main router with swap, split routing, and multi-hop support |
| UniswapV2Adapter | Adapter for Uniswap V2 and forks |
| UniswapV3Adapter | Adapter for Uniswap V3 with fee tier selection |
| UniswapV4Adapter | Adapter for Uniswap V4 hooks |
| CurveAdapter | Adapter for Curve Finance pools |
| BalancerAdapter | Adapter for Balancer V2 vaults |

## Features

- **Access Control**: Role-based permissions (Admin, Operator, Guardian)
- **Pausability**: Emergency pause functionality
- **Reentrancy Protection**: All external functions protected
- **Fee System**: Configurable protocol fees (default 0.05%)
- **Native Token Support**: Automatic ETH wrapping/unwrapping

## Deployment

```bash
# Deploy to testnet
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast

# Verify on Etherscan
forge verify-contract $CONTRACT_ADDRESS VoidDexRouter --chain sepolia
```

## Documentation

For detailed documentation, visit [https://pzza.works/products/void-dex](https://pzza.works/products/void-dex)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

VoidDex Team - [https://pzza.works/products/void-dex](https://pzza.works/products/void-dex)

Project Link: [https://github.com/pzzaworks/void-dex-contracts](https://github.com/pzzaworks/void-dex-contracts)
