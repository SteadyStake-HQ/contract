# Deploy & Verify on BNB Chain (BSC) Mainnet — chain 56

Deployer / relayer: `0x1BF1fdC063dF1239a9407767C5be36e746104294` (same wallet for both;
`RELAYER_ADDRESS` in `contracts/.env` == `RELAYER_PRIVATE_KEY` in `backend/.env`).

## BNB Chain settles in an 18-decimal stablecoin — read this first

Every other chain in this project settles in a 6-decimal token. **BSC cannot.** Its liquid
stablecoins — Binance-Peg USDC and USDT, BUSD, FDUSD, USD1, DAI — are all **18-decimal**. The only
6-decimal options are bridged wrappers with a few hundred thousand dollars of total supply
(axlUSDC ~230k, Wormhole USDCet ~137k, Wormhole USDTet ~299k), which are too thin to settle into
and would force every user to bridge in before they could start a plan.

So chain 56 uses **Binance-Peg USD Coin `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` (18 decimals)**
and the codebase was taught about per-chain stablecoin decimals:

| Layer | What changed |
| --- | --- |
| `DCAVault` | The deposit cap `10_000_000e6` became `maxTotalDeposit`, an immutable set in the constructor to `10_000_000 * 10**usdc.decimals()`. At 18 decimals the old literal was a cap of **$0.00001**, so every realistic deposit reverted with "Amount too large". |
| Frontend | `getStableDecimals(chainId)` in `config/contracts.ts`; ~39 hardcoded `parseUnits(x, 6)` / `formatUnits(x, 6)` call sites now read from it. |
| Backend | `getStableDecimals(chainId)` in `src/config.ts`; run prices, gas-cost conversion and plan formatting scale from it. |

Both helpers return **6 for every pre-existing chain**, so nothing about the other seven
deployments changes — only chain 56 resolves to 18.

### Cross-chain totals need a common scale

Gas-tank balances are pooled: a run on one network can be paid out of another network's tank. Once
one chain is 18-decimal, raw balances can no longer be summed or compared. Both apps now normalise
to a canonical 6-decimal **pooled** scale (`toPooledUsd6` / `fromPooledUsd6`, and
`convertStableAmount` on the backend) before any cross-chain arithmetic:

- `useGasTankAllChains().totalBalanceUsdc6` and the backend's `globalGas.globalBalance` are pooled;
  `byChain` entries stay in each chain's own units.
- `pickDeductChain` (backend) and `gasPayingChainId` (frontend) compare pooled values — raw, an
  18-decimal BSC balance outranks every other chain by 10^12 and would always win "richest tank".
- The relayer restates the charge into the deduct chain's units before calling `recordExecution`,
  since the tank it debits is not always the chain it executed on.
- `useGasTankLevel` converts the pooled balance into the chain's units before dividing by the run
  price; without that every BSC tank reads as empty.

## Addresses used

- **Stablecoin**: `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` (Binance-Peg USDC, **18 decimals**)
- **0x router**: `0x0000000000001fF3684f28c67538d4D072C22734` (Swap API **v2** AllowanceHolder)

The legacy Exchange Proxy `0xDef1C0ded9bec7F1a1670819833240f027b25EfF` that this script used to
point at is unusable — `/swap/v1` is sunset and 404s, so v2 + AllowanceHolder is the only route
that still yields executable calldata. Verified live: a `chainId=56` v2 quote for 5 USDC → WBNB
returns `liquidityAvailable: true` and routes to the AllowanceHolder above.

## Build

BSC gets its own optimized build, like Kava does:

```bash
cd contracts
forge build --evm-version cancun --optimize --optimizer-runs 200 --out out-bsc --skip test
# solc 0.8.35+commit.47b9dedd, evmVersion=cancun, optimizer ON, runs 200
```

Two reasons this is not the default build:

1. **Optimizer.** Unoptimized, DCAVault's runtime is 24,518 bytes against EIP-170's 24,576 — 58
   bytes of headroom, which is not a margin to ship a mainnet deploy on. Optimized it is 13,075.
2. **`--evm-version cancun`.** solc 0.8.35 now defaults to `osaka`, which is ahead of what BSC
   executes. Cancun is well supported there and still has PUSH0 and MCOPY.

Runtime sizes from this build: DCAVault 13,075 · GasTank 2,714 · ZeroExAdapter 2,167 ·
DCAResolver 1,848.

## Deploy

`forge script` SIGILLs on this machine (see [DEPLOY_BOT_CHAIN.md](DEPLOY_BOT_CHAIN.md)), so the
deploy runs through a viem script that reads `out-bsc/*.json` directly. It must run from `backend/`
because that is where viem resolves.

```bash
cd backend
node deploy-bsc.mjs
```

It deploys ZeroExAdapter → DCAVault → DCAResolver → GasTank, then wires
`setGasCostPerExecution(1e16)` ($0.01 at 18 decimals — **not** the `10_000` used on 6-decimal
chains), `setExecutor(RELAYER_ADDRESS)` and `vault.setGasTank(...)`. It then reads all of that back
off-chain and exits non-zero if any check fails, so a half-wired deploy never reaches the sync step.
Finally it writes a forge-compatible `broadcast/Deploy.s.sol/56/run-latest.json`.

Cost is negligible: BSC's gas price floor is 0.05 gwei and the script bumps to 0.1 gwei, so the
whole deploy is well under 0.001 BNB.

`script/Deploy.s.sol:DeployBNB` carries the same constants for whoever can run forge.

## Sync the addresses into both apps

```bash
cd contracts
node scripts/sync-chain.js 56
```

This merges the `56` entry into `frontend/config/deployed-addresses.json` and
`backend/deployed-addresses.json`. Nothing else needs editing — chain 56 is already in
`NEXT_PUBLIC_SUPPORTED_CHAIN_IDS`, the backend network registry, `frontend/lib/server-chain.ts`
and the BNB token list.

## What was already on chain 56 before this

A February deploy left DCAVault `0x8Cf3533A…728D`, DCAResolver `0xd301fBCa…d505` and ZeroExAdapter
`0xb6609501…e196` with live bytecode, and `deployed-addresses.json` pointed at them. **They are
stale and are replaced by this deploy:**

- The old vault predates `gasTank` entirely — calling `gasTank()` on it reverts — so it can never
  take part in automated execution. GasTank was never deployed on 56 at all (`0x0`).
- The old vault carries the `10_000_000e6` cap, which against 18-decimal USDC caps deposits at
  $0.00001.
- The old adapter predates the balance-delta fix and points at the sunset Exchange Proxy.

The old vault holds no plans that this deploy strands; if any user funds are ever found in it, its
owner is the same deployer wallet.

## Verification

All four contracts are **verified on BscScan** (2026-07-29), full matches:

| Contract | Address |
| --- | --- |
| ZeroExAdapter | [`0xd50dc0211bf623caa95cbecc58f4d8f821811e93`](https://bscscan.com/address/0xd50dc0211bf623caa95cbecc58f4d8f821811e93#code) |
| DCAVault | [`0xa9ffd2da7942f9ba13ed0d2b4cf9aff23979eb5d`](https://bscscan.com/address/0xa9ffd2da7942f9ba13ed0d2b4cf9aff23979eb5d#code) |
| DCAResolver | [`0x5c67819cbf3f332acc41ab2e062c97840c7bc555`](https://bscscan.com/address/0x5c67819cbf3f332acc41ab2e062c97840c7bc555#code) |
| GasTank | [`0xe487b573b458aee811acbe3196f9e9022fb87a0e`](https://bscscan.com/address/0xe487b573b458aee811acbe3196f9e9022fb87a0e#code) |

Reproduce with `node scripts/verify-deployed.mjs 56` (idempotent — it no-ops if already verified).
`forge verify-contract` SIGILLs here like `forge script`, so that script posts a solc
standard-JSON input, rebuilt from `out-bsc`'s own artifact metadata, to Etherscan's V2 multichain
API (`api.etherscan.io/v2/api?chainid=56`, `ETHERSCAN_API_KEY` from `contracts/.env` — BscScan's
own V1 key is not used). Standard-JSON rather than `forge flatten` output, so the settings above
(cancun, optimizer on, runs 200) come straight from the artifact and cannot drift.

## Still to do

- Restart the backend relayer so it picks up the new addresses, and fund it with BNB for gas.
- Redeploy the frontend so the synced addresses and the decimals changes ship together. **The
  frontend and backend must go out together** — an old frontend against the new 18-decimal vault
  would size every deposit 10^12 too small.
