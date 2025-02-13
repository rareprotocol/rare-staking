# Rare Staking

A Solidity smart contract implementation for staking RARE tokens with Merkle-based claim functionality and efficient reward distribution. This contract enables users to stake their RARE tokens and participate in a rewards program, with claims validated through Merkle proofs for gas-efficient distribution.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) - Smart contract development toolkit
- [Git](https://git-scm.com/downloads) - Version control

## Setup

1. Clone the repository and its submodules:
```bash
git clone https://github.com/rareprotocol/rare-staking.git
cd rare-staking
forge install
```

2. Set up your environment variables:
```bash
cp sample.env .env
```
Then edit `.env` with your configuration. The following variables are required:
- `PRIVATE_KEY`: Your deployer wallet's private key
- `RARE_TOKEN`: The address of the RARE token contract
- `INITIAL_MERKLE_ROOT`: The initial Merkle root for claims

See `sample.env` for all available configuration options.

## Building

To compile the contracts:

```bash
forge build
```

To run tests:

```bash
forge test
```

To run tests with gas reporting:

```bash
forge test --gas-report
```


## Deployment

The deployment script is located in `script/DeployRareStake.s.sol`. To deploy the contract:

1. Ensure your `.env` file is properly configured with:
   - `PRIVATE_KEY`: Your deployer wallet's private key
   - `RARE_TOKEN`: The address of the RARE token contract
   - `INITIAL_MERKLE_ROOT`: The initial Merkle root for claims

2. Run the deployment script:
```bash
forge script script/DeployRareStake.s.sol --rpc-url <your_rpc_url> --broadcast
```

Replace `<your_rpc_url>` with your preferred network RPC URL (e.g., Ethereum mainnet, testnet).

## Project Structure

- `src/`: Smart contract source files
- `test/`: Contract test files
- `script/`: Deployment and other scripts
- `lib/`: Dependencies (OpenZeppelin contracts, Forge Standard Library)

## Dependencies

The project uses the following main dependencies:
- OpenZeppelin Contracts
- Forge Standard Library

These are managed through Git submodules and Foundry's dependency system.
