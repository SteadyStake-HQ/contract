# Deploy GasTank to Base Sepolia

From the `contracts` directory:

1. Set env vars (optional but recommended):
   - `PRIVATE_KEY` – deployer wallet (required)
   - `RELAYER_ADDRESS` – address that will run the backend executor (set as GasTank executor)

2. Deploy:

```bash
forge script script/Deploy.s.sol:DeployGasTankBaseSepolia --rpc-url https://sepolia.base.org --broadcast
```

3. Copy the logged **GasTank** address (e.g. `GasTank: 0x...`).

4. Update frontend and backend:

```bash
# From repo root (replace 0xYourGasTankAddress with the logged address)
node scripts/update-gastank-base-sepolia.js 0xYourGasTankAddress
```

Or manually set `GasTank` for chain `84532` in:
- `frontend/config/deployed-addresses.json`
- `backend/deployed-addresses.json`
