# Deploy SteadyStake to Ethereum Sepolia

Chain ID: **11155111**

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Wallet with Sepolia ETH (faucet: https://sepoliafaucet.com/)
- [Etherscan API key](https://etherscan.io/apis) for verification

## 1. Configure environment

From repo root or `contracts/`:

```bash
export PRIVATE_KEY=0x...          # deployer wallet
export ETHERSCAN_API_KEY=...      # for contract verification
# optional: relayer address for GasTank executor
export RELAYER_ADDRESS=0x...
```

## 2. Deploy and verify

From the **contracts** directory:

```bash
cd contracts
forge script script/Deploy.s.sol:DeployEthSepolia \
  --rpc-url eth_sepolia \
  --broadcast \
  --verify \
  --chain-id 11155111
```

- `--broadcast`: send transactions to Sepolia
- `--verify`: verify contracts on Etherscan after deploy

If verification fails during deploy (e.g. Foundry errors on missing `KAVASCAN_API_KEY`), set dummy keys so only Sepolia is used, then verify manually:

```bash
# Required for Etherscan (Sepolia)
export ETHERSCAN_API_KEY=...   # from https://etherscan.io/apis

# Optional: avoid "not found" errors for other chains when verifying on Sepolia
export KAVASCAN_API_KEY=dummy
export POLYGONSCAN_API_KEY=dummy
export BASE_ETHERSCAN_KEY=dummy
export BSCSCAN_API_KEY=dummy
```

Then run from **contracts/** (Bash; `ZeroExAdapter` lives in `SwapHelper.sol`):

```bash
cd contracts
forge verify-contract 0x8A7DcD7975e44Ad7a6e21a577A573F77C6656742 src/SwapHelper.sol:ZeroExAdapter --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address,address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 0xDef1C0ded9bec7F1a1670819833240f027b25EfF) --watch
forge verify-contract 0x55a3812b36a4d9F3dc7ce6204A5ae81c3b714f3a src/DCAVault.sol:DCAVault --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address,address)" 0x8A7DcD7975e44Ad7a6e21a577A573F77C6656742 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) --watch
forge verify-contract 0x088bC79F8dE6D7BA90EDc96665B5D7917C56cd84 src/DCAResolver.sol:DCAResolver --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address)" 0x55a3812b36a4d9F3dc7ce6204A5ae81c3b714f3a) --watch
forge verify-contract 0x9Ec79EE879b2945e87446Aba08F93Bc50b200461 src/GasTank.sol:GasTank --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) --watch
```

Or use the script (from **contracts/**):

```bash
# PowerShell (Windows)
.\scripts\verify-sepolia.ps1

# Bash
./scripts/verify-sepolia.sh
```

**Verify only GasTank** (e.g. at `0x9Ec79EE879b2945e87446Aba08F93Bc50b200461`; this contract holds USDC for gas reimbursement, it is not the USDC token):

```bash
# Set ETHERSCAN_API_KEY and optional dummy keys (see above), then:
forge verify-contract 0x9Ec79EE879b2945e87446Aba08F93Bc50b200461 src/GasTank.sol:GasTank --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) --watch
```

### Deploy with new MockUSDC (full stack)

To deploy a **new MockUSDC** plus MockSwapRouter, DCAVault, DCAResolver, and GasTank (no existing USDC/0x):

```bash
cd contracts
forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast \
  --chain-id 11155111
```

Then verify **MockUSDC** (no constructor args):

```bash
# Replace <MOCK_USDC_ADDRESS> with the logged address (e.g. 0x89A01f63A5F4b42d30483ee17c5f537A4B94b15E)
forge verify-contract <MOCK_USDC_ADDRESS> src/MockTokens.sol:MockUSDC --chain-id 11155111 --compiler-version 0.8.33 --watch
```

After deploy, update **frontend** (`frontend/config/contracts.ts`, `frontend/config/deployed-addresses.json`, `frontend/lib/automation.ts`) and **backend** (`backend/deployed-addresses.json`, `backend/src/config.ts` USDC_BY_CHAIN) with the new MockUSDC and contract addresses.

## 3. Update app config with deployed addresses

After a successful run, the script prints:

- **ZeroExAdapter**
- **DCAVault**
- **DCAResolver**
- **GasTank**

Update both config files with these addresses:

1. **Backend** – `backend/deployed-addresses.json`  
   Set the `"11155111"` entry:
   - `DCAVault`: deployed DCAVault address
   - `GasTank`: deployed GasTank address

2. **Frontend** – `frontend/config/deployed-addresses.json`  
   Set the `"11155111"` entry:
   - `DCAVault`, `DCAResolver`, `ZeroExAdapter`, `GasTank`

Alternatively, from repo root run the helper script (after deploy) to fill addresses from the last broadcast:

```bash
node contracts/scripts/update-eth-sepolia-addresses.js
```

This reads `contracts/broadcast/Deploy.s.sol/11155111/run-latest.json` and updates both JSON files.
