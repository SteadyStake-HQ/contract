# Deploy & Verify on BNB Chain (BSC) Mainnet

**Eligible mainnets:** Base mainnet (8453), BNB Chain (56). See [DEPLOY_BASE_MAINNET.md](DEPLOY_BASE_MAINNET.md) for Base.

## Prerequisites

1. **Foundry** installed (`forge --version`)
2. **Environment variables** (do not commit):
   - `PRIVATE_KEY` – deployer wallet private key (with enough BNB for gas)
   - `BSCSCAN_API_KEY` – [BscScan API key](https://bscscan.com/apis) for verification

## Deploy and verify

From the `contracts` folder:

```bash
# Windows (PowerShell)
$env:PRIVATE_KEY="0x_your_private_key_here"
$env:BSCSCAN_API_KEY="your_bscscan_api_key"
forge script script/Deploy.s.sol:DeployBNB --rpc-url bnb --broadcast --verify

# Linux/macOS
export PRIVATE_KEY=0x_your_private_key_here
export BSCSCAN_API_KEY=your_bscscan_api_key
forge script script/Deploy.s.sol:DeployBNB --rpc-url bnb --broadcast --verify
```

## After deployment

1. Note the logged addresses: **ZeroExAdapter**, **DCAVault**, **DCAResolver**.
2. Broadcast artifacts are in `broadcast/Deploy.s.sol/56/` (chain ID 56 = BNB mainnet).
3. Update the frontend `config/deployed-addresses.json` with the `56` entry (see Frontend integration below).

## BNB mainnet addresses used

- **USDC**: `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` (Binance-Peg USD Coin)
- **0x ExchangeProxy**: `0xdef1C0ded9bec7F1a1670819833240f027b25EfF`

## Frontend integration

Add the deployed addresses under chain ID `56` in `frontend/config/deployed-addresses.json`:

```json
{
  "8453": { "DCAVault": "...", "DCAResolver": "...", "ZeroExAdapter": "..." },
  "56": {
    "DCAVault": "<your DCAVault address>",
    "DCAResolver": "<your DCAResolver address>",
    "ZeroExAdapter": "<your ZeroExAdapter address>"
  }
}
```

Users can then select **Base mainnet** or **BNB Chain** in the app; contracts will switch automatically.
