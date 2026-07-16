# Deploy and verify contracts (Base Sepolia + Ethereum Sepolia)

**When you change any contract code:** redeploy and verify on **both** Base Sepolia and Ethereum Sepolia, then run the sync script (step 4) so frontend and backend get the new addresses.

Use this flow to deploy the **updated contracts** (including `getReadyScheduleIds`) to both testnets and sync addresses to the frontend and backend.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Wallet with testnet ETH:
  - [Base Sepolia faucet](https://www.coinbase.com/faucets/base-sepolia-faucet)
  - [Ethereum Sepolia faucet](https://sepoliafaucet.com/)
- API keys for verification:
  - [Basescan](https://basescan.org/apis) (Base Sepolia)
  - [Etherscan](https://etherscan.io/apis) (Ethereum Sepolia)

## 1. Environment variables

From repo root or `contracts/`:

```bash
# Required for deployment
export PRIVATE_KEY=0x...              # deployer wallet

# Verification (optional but recommended)
export BASE_ETHERSCAN_KEY=...         # Base Sepolia (Basescan)
export ETHERSCAN_API_KEY=...          # Ethereum Sepolia (Etherscan)

# Optional: avoid "key not found" when verifying only on one chain
export KAVASCAN_API_KEY=dummy
export POLYGONSCAN_API_KEY=dummy
export BSCSCAN_API_KEY=dummy
```

Windows (PowerShell):

```powershell
$env:PRIVATE_KEY = "0x..."
$env:BASE_ETHERSCAN_KEY = "..."
$env:ETHERSCAN_API_KEY = "..."
```

## 2. Deploy Base Sepolia (chain 84532)

From the **contracts** directory:

```bash
cd contracts
forge script script/Deploy.s.sol:DeployTestnet \
  --rpc-url base_sepolia \
  --broadcast \
  --verify \
  --chain-id 84532
```

- Uses RPC from `foundry.toml` (`base_sepolia = "https://sepolia.base.org"`).
- If `--verify` fails (e.g. rate limit), re-run verification later with `forge verify-contract` (see section 5).

## 3. Deploy Ethereum Sepolia (chain 11155111)

From the **contracts** directory:

```bash
forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC \
  --rpc-url eth_sepolia \
  --broadcast \
  --verify \
  --chain-id 11155111
```

- Deploys MockUSDC, MockSwapRouter, DCAVault, DCAResolver, GasTank.
- RPC: `eth_sepolia` from `foundry.toml` (e.g. `https://rpc.sepolia.org`).

## 4. Update frontend and backend addresses

After one or both deploys, run (from **repo root**):

```bash
node contracts/scripts/sync-both-testnets.js
```

This reads the latest broadcast for **84532** and **11155111**, extracts contract addresses, and updates:

- `frontend/config/deployed-addresses.json`
- `backend/deployed-addresses.json`

Other chain IDs in those files are left unchanged.

Alternatively, update a single chain:

```bash
node contracts/scripts/sync-base-sepolia.js
node contracts/scripts/update-eth-sepolia-addresses.js
```

## 5. Manual verification (if `--verify` failed)

Use the addresses and constructor args from your **latest** broadcast (e.g. `contracts/broadcast/Deploy.s.sol/<chainId>/run-latest.json`). Example for Ethereum Sepolia (11155111):

```bash
cd contracts

# Get constructor args from broadcast or cast. Replace <ADDRESS> with deployed address.
# DCAVault(swapAdapter, resolver)
forge verify-contract <DCA_VAULT_ADDRESS> src/DCAVault.sol:DCAVault \
  --chain-id 11155111 \
  --constructor-args $(cast abi-encode "constructor(address,address)" <SWAP_ADAPTER> <RESOLVER>) \
  --watch

# DCAResolver(vault)
forge verify-contract <RESOLVER_ADDRESS> src/DCAResolver.sol:DCAResolver \
  --chain-id 11155111 \
  --constructor-args $(cast abi-encode "constructor(address)" <DCA_VAULT_ADDRESS>) \
  --watch

# GasTank(resolver)
forge verify-contract <GASTANK_ADDRESS> src/GasTank.sol:GasTank \
  --chain-id 11155111 \
  --constructor-args $(cast abi-encode "constructor(address)" <RESOLVER_ADDRESS>) \
  --watch
```

For **Base Sepolia** (84532), use `--chain-id 84532`; verification uses `BASE_ETHERSCAN_KEY` from `foundry.toml`.

## Summary

| Step | Command |
|------|--------|
| 1 | Set `PRIVATE_KEY`, `BASE_ETHERSCAN_KEY`, `ETHERSCAN_API_KEY` |
| 2 | `cd contracts && forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify --chain-id 84532` |
| 3 | `forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC --rpc-url eth_sepolia --broadcast --verify --chain-id 11155111` |
| 4 | `node contracts/scripts/sync-both-testnets.js` (from repo root) |

After step 4, frontend and backend use the new DCAVault (with `getReadyScheduleIds`) and other contract addresses on both testnets.
