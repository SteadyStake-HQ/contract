# Deploy & Verify on Base Mainnet

**Other testnets:** Base Sepolia (EVM) → use `deploy:base-sepolia`. **Qubic testnet** (faucet, seeds, RPC) → see [QUBIC_TESTNET.md](QUBIC_TESTNET.md) and [Qubic Testnet Resources](https://docs.qubic.org/developers/testnet-resources).

## Prerequisites

1. **Foundry** installed (`forge --version`)
2. **Environment variables** (do not commit these):
   - `PRIVATE_KEY` – deployer wallet private key (with enough ETH on Base for gas)
   - `BASE_ETHERSCAN_KEY` – [Basescan API key](https://basescan.org/apis) for verification

## Deploy and verify

From the `contracts` folder:

```bash
# Windows (PowerShell)
$env:PRIVATE_KEY="0x_your_private_key_here"
$env:BASE_ETHERSCAN_KEY="your_basescan_api_key"
forge script script/Deploy.s.sol:DeployMainnet --rpc-url base --broadcast --verify

# Linux/macOS
export PRIVATE_KEY=0x_your_private_key_here
export BASE_ETHERSCAN_KEY=your_basescan_api_key
forge script script/Deploy.s.sol:DeployMainnet --rpc-url base --broadcast --verify
```

## After deployment

1. Note the logged addresses: **ZeroExAdapter**, **DCAVault**, **DCAResolver**.
2. Broadcast artifacts are in `broadcast/Deploy.s.sol/8453/` (chain ID 8453 = Base mainnet).
3. Update the frontend (see below) with the deployed addresses.

## Frontend integration

Set in the frontend `.env.local` (or your env):

- `NEXT_PUBLIC_CHAIN_ID=8453`
- `NEXT_PUBLIC_DCA_VAULT=<DCAVault address>`
- `NEXT_PUBLIC_DCA_RESOLVER=<DCAResolver address>`

On Base mainnet there are no “mock” tokens; the app uses canonical Base tokens (e.g. USDC, AERO, cbETH). Token addresses for mainnet are in `frontend/config/contracts.ts`. Set the three env vars in frontend `.env.local` and restart the dev server.
