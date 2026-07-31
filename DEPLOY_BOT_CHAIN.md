# Deploy & Verify on BOT Chain (677 mainnet / 968 testnet)

BOT Chain is EVM-compatible with Parlia consensus (BSC-derived), ~0.75s blocks and low fees.
Docs: <https://dev-docs.botchain.ai/docs/Developers/json-rpc-endpoint/>

## What is different from the other chains

Two things drive every configuration choice here:

1. **There is no 0x aggregator on BOT Chain.** Swaps go through **BDEX V2**, a Uniswap V2 fork.
   The vault therefore points at [`src/UniV2SwapAdapter.sol`](src/UniV2SwapAdapter.sol) instead of
   `ZeroExAdapter`, and the relayer sends **empty `swapData`** so `DCAVault` takes the
   `ISwapRouter.swap` path. See `usesDirectSwapRouter()` in `backend/src/config.ts`.
2. **There is no USDC on BOT Chain.** Bridged **USDT (6 decimals)** is the settlement stablecoin
   and occupies the vault's "USDC" slot. Field names across the codebase still say USDC; only the
   display symbol changes (`getStableSymbol()` in `backend/src/config.ts`).

## Network reference

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | 677 | 968 |
| RPC | `https://rpc.botchain.ai` | `https://rpc.bohr.life` |
| Explorer (Blockscout) | `https://scan.botchain.ai` | `https://scan.bohr.life` |
| Native token | BOT (18 dec) | tBOT (18 dec) |
| Faucet | — (swap on B DEX) | <https://faucet.botchain.ai/basic> |
| USDT (6 dec) | `0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C` | `0x75edC9335175Fc0552D51D48439F229c10420fe3` |
| WBOT (18 dec) | `0xD5452816194a3784dBa983426cCe7c122F4abd30` | `0xD5452816194a3784dBa983426cCe7c122F4abd30` |
| BDEX V2 Router02 | `0x1414eD29FdFD322c3c0a830330ed982E2D629e76` | `0xD6425a02f0845B8D99e349C34D2E7A576E177345` |
| BDEX V2 Factory | `0x117115f3B72C8d1989178089A67D0C26f8EE0AA3` | `0x65b8e98ceA190d8c28B3e4716402027f634d15a3` |
| Multicall3 | `0x47FA21f684bBAD707A53a0f9BE59F1422F46C265` | `0x47FA21f684bBAD707A53a0f9BE59F1422F46C265` |

> The docs page lists a `SwapRouter02` for V3 at `0xaE6ae8630f7A888dEc0B9195C85F7515d5887655`, but
> that address has **no code on testnet** — V2 Router02 is the only router deployed on both networks,
> which is why the adapter targets V2.

## Prerequisites

1. **Foundry** installed (`forge --version`)
2. **Environment variables** (do not commit):
   - `PRIVATE_KEY` – deployer wallet, funded with BOT/tBOT for gas
   - `RELAYER_ADDRESS` – optional; set as the GasTank executor at deploy time
   - `BOTSCAN_API_KEY` – any non-empty string (Blockscout ignores it)

## Deploy

From the `contracts` folder. **`--legacy` is required** — BOT Chain uses legacy (type-0) gas pricing.

```bash
# Testnet (968) — start here
export PRIVATE_KEY=0x_your_private_key_here
export RELAYER_ADDRESS=0x_your_relayer_address
make deploy-bot-testnet

# Mainnet (677)
make deploy-bot-mainnet
```

Or directly:

```bash
forge script script/Deploy.s.sol:DeployBotTestnet \
  --rpc-url bot_testnet --broadcast --legacy \
  --verify --verifier blockscout --verifier-url https://scan.bohr.life/api
```

Both `make` targets run `node scripts/sync-bot-chain.js <chainId>` afterwards, which merges the
deployed addresses into **both** `frontend/config/deployed-addresses.json` and
`backend/deployed-addresses.json`. `UniV2SwapAdapter` is written to the `ZeroExAdapter` key —
that field is simply "whatever `DCAVault.swapRouter` points at".

## After deployment

1. **Fund the relayer** with tBOT/BOT for gas.
2. **Confirm the GasTank executor** is the relayer address (`gasTank.setExecutor(...)` runs at deploy
   only when `RELAYER_ADDRESS` is set).
3. **Set the gas price basis.** CoinGecko lists BOT Chain (platform `bot-chain`, coin `bot`) but has
   no USD quote yet, so network-derived gas cost resolves to `0` and the GasTank is never debited.
   Set one of these in `backend/.env`:
   - `NATIVE_PRICE_USD_968=<BOT price in USD>` (or `_677`), or
   - `GAS_COST_PER_EXECUTION_USDC=0.001` for a flat per-execution charge.
4. **Restrict the executor while testing**: pause every other network on the backend dashboard's
   **Networks** page (`POST /api/admin/networks/pause`, `ADMIN_API_TOKEN` required). The executor
   otherwise runs every chain with a deployed GasTank — there is no env chain list.
5. **Frontend**: `NEXT_PUBLIC_SUPPORTED_CHAIN_IDS=968` to show only BOT testnet in the switcher.

## Liquidity caveat

The vault passes `minAmountOut = 0`, and BOT Chain has no aggregator quote to check a swap against,
so slippage protection depends entirely on trade size versus pool depth. At the time of writing the
BDEX V2 USDT/WBOT pool holds roughly **23,000 USDT on testnet** but only about **11 USDT on
mainnet** — size mainnet DCA intervals accordingly, or wait for deeper pools.

## Token list

`frontend/config/contracts.ts` ships USDT and WBOT for 677/968. BDEX has no token-list API yet; add
entries as pools appear. The adapter routes `USDT -> token` when that pair exists and falls back to
`USDT -> WBOT -> token` otherwise, so any token with a WBOT pool works without a contract change.

## Not wired up

**Gelato Relay does not support BOT Chain**, so the Vercel cron route
(`frontend/app/api/cron/execute-dca/route.ts`) cannot execute plans there. BOT Chain executes through
the standalone backend relayer (`backend/src/run-executor.ts`), which signs with `RELAYER_PRIVATE_KEY`
directly. The cron route still carries BOT Chain's RPC and swap-path config so nothing breaks if
Gelato adds support later.
