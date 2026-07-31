# Kava (2222) & Polygon (137) mainnet deployment — 2026-07-28

Deployer / relayer: `0x1BF1fdC063dF1239a9407767C5be36e746104294` (same wallet for both;
`RELAYER_ADDRESS` in `contracts/.env` == `RELAYER_PRIVATE_KEY` in `backend/.env`).

Both chains previously had addresses listed in `deployed-addresses.json` that had **no bytecode
on-chain** — Polygon's were copy-pasted from the 677/8453 entries. This was the first real deploy
for both.

## Deployed addresses

Synced into `backend/deployed-addresses.json` and `frontend/config/deployed-addresses.json`
via `node scripts/sync-chain.js <chainId>`.

### Polygon (137)
| Contract | Address |
| --- | --- |
| ZeroExAdapter | `0x0459f26fc754d0762b26ed0b9fa5f476455453b2` |
| DCAVault | `0xdb561fe13a6516b31c8fcd5cb8b5a4e3fefe43a9` |
| DCAResolver | `0x441cad85ee6c88a0f1d93628b6faf7d1c3a3bdf0` |
| GasTank | `0xda4c87986f4bb210c4affef815e8c1b5addad297` |

Stablecoin: Circle native USDC `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` (6 dec).
Cost: 2.40 POL.

### Kava (2222)
| Contract | Address |
| --- | --- |
| ZeroExAdapter (**inert** — see below) | `0x0c2bf5bcf2ebe0c56fd05f391008ee3f9bd090d2` |
| DCAVault | `0x19feb663233b76d84283ed84f5a2ed638c3d6d65` |
| DCAResolver | `0x13028ce629a452764e976f811fddc51a512dbab4` |
| GasTank | `0xe97febdbc8a18babe1bcd36316b70319986b25c0` |

Stablecoin: native Tether **USDt** `0x919C1c267BC06a7039e03fcc2eF738525769109c` (6 dec).
Cost: 0.005 KAVA.

Both GasTanks: `executor` = relayer, `gasCostPerExecutionUsdc6` = `10000` ($0.01/run).

## Kava has no working swap route

The vault, resolver and GasTank are fully functional on Kava. **Swaps are not**, deliberately:

- 0x does not support chain 2222 — its API rejects the chainId outright. Supported chains are
  1, 10, 56, 137, 8453, 42161, 43114, 59144, 534352, 5000, 480, 130, 80094, 57073, 9745, 143, 146,
  2741, 999, 4217, 4663.
- The only DEX, **Equilibre**, is a Solidly fork: it exposes `weth()` and
  `getPair(a, b, bool stable)`, not `WETH()` / `getPair(a, b)`. `UniV2SwapAdapter` cannot even be
  *constructed* against it — its constructor calls `router.WETH()`, which reverts.
- Liquidity is negligible regardless: the Equilibre USDt/WKAVA pool holds ~198 USDt / 4,407 WKAVA
  (~$400 total at KAVA ≈ $0.045).

So the deployed Kava adapter points at an address with no code on that chain. Any swap attempt
reverts on ZeroExAdapter's `"No output received"` guard instead of consuming user funds, and in
practice the relayer never even sends a tx (the 0x quote fails first and the run is skipped).

To enable Kava swaps later: write an Equilibre/Solidly adapter implementing `ISwapRouter`, then
`vault.setSwapRouter(newAdapter)` — no redeploy of the vault is needed.

## Why `forge script` was not used

`forge script` SIGILLs on this machine (see `DEPLOY_BOT_CHAIN.md`). Deployment was done by a viem
script reading `out/*.json` bytecode directly, then writing a forge-compatible
`broadcast/Deploy.s.sol/<chainId>/run-latest.json` so `scripts/sync-chain.js` works unchanged.
`script/Deploy.s.sol` was still updated so `DeployKava` / `DeployPolygon` carry the correct
constants for whoever can run forge.

## Build settings (needed to verify the contracts)

Polygon used the default build:

```
forge build --out out-poly --skip test
# solc 0.8.35+commit.47b9dedd, evmVersion=osaka (default), optimizer OFF, runs 200
```

Two corrections to what this section originally claimed, both established by diffing the on-chain
runtime against local builds while verifying (2026-07-29):

- The evmVersion is **osaka**, not prague — that is solc 0.8.35's default. A prague build differs
  only in the metadata hash for the small contracts, but it is not what is deployed.
- Polygon's **DCAVault predates the BNB `maxTotalDeposit` refactor**, so it does not build from the
  current working tree; its runtime is 24,373 bytes against the current source's 24,518. The
  deployed source is the one in git HEAD (`git show HEAD:src/DCAVault.sol`). The other three
  contracts are unchanged since and do build from the working tree.

`out-poly` is a checked-out-HEAD build kept around so the Polygon verification stays reproducible.

Kava needed a **separate build**:

```
forge build --evm-version paris --optimize --optimizer-runs 200 --out out-paris --skip test
# solc 0.8.35+commit.47b9dedd, evmVersion=paris, optimizer ON, runs 200
```

Two constraints forced this, in order:

1. Kava's EVM predates Shanghai and rejects `PUSH0` — deploying the default build fails at gas
   estimation with `rpc error: invalid opcode: PUSH0`.
2. Paris codegen replaces `PUSH0` with `PUSH1 0x00`, which pushed DCAVault's runtime size to
   **25,015 bytes** — over the EIP-170 limit of 24,576. Enabling the optimizer brings it to 13,241.

For reference, DCAVault runtime sizes: default build 24,373 (fits, 203 bytes of headroom);
paris unoptimized 25,015 (**too big**); paris optimized 13,241.

## Verification

Both chains are verified as of 2026-07-29. Reproduce either with
`node scripts/verify-deployed.mjs <137|2222>` — idempotent, no-ops when already verified.

**Polygon → Polygonscan**, all four full matches, via Etherscan's V2 multichain API
(`api.etherscan.io/v2/api?chainid=137`, `ETHERSCAN_API_KEY` from `contracts/.env`):

| Contract | Address |
| --- | --- |
| ZeroExAdapter | [`0x0459f26f…53b2`](https://polygonscan.com/address/0x0459f26fc754d0762b26ed0b9fa5f476455453b2#code) |
| DCAVault | [`0xdb561fe1…43a9`](https://polygonscan.com/address/0xdb561fe13a6516b31c8fcd5cb8b5a4e3fefe43a9#code) |
| DCAResolver | [`0x441cad85…bdf0`](https://polygonscan.com/address/0x441cad85ee6c88a0f1d93628b6faf7d1c3a3bdf0#code) |
| GasTank | [`0xda4c8798…d297`](https://polygonscan.com/address/0xda4c87986f4bb210c4affef815e8c1b5addad297#code) |

**Kava → Sourcify**, all four `exact_match` on both creation and runtime bytecode:
`https://repo.sourcify.dev/2222/<address>/`.

Kavascan cannot be used. Its verifier is Cosmostation's service at
`https://api.verify.mintscan.io/evm/api/0x8ae` (the URL in `foundry.toml`), and its
`compilerversion` allow-list stops at **v0.8.30** — these contracts are built with 0.8.35, so no
submission there can ever match. `kavascan.com` itself serves only a frontend; there is no public
Blockscout API on that host to import the Sourcify match through. If a native Kavascan listing is
ever required it means redeploying Kava with solc ≤ 0.8.30.

## ZeroExAdapter change shipped with this deploy

`executeSwapWithData` now measures the `tokenOut` balance delta instead of decoding the router's
return value, and reverts when the delta is zero.

0x Swap API **v1 is sunset** (`/swap/v1/quote` 404s on every chain), so the only source of
executable calldata is v2, which routes through `AllowanceHolder.exec()` — and that returns
`bytes`, not `uint256`. The old `abi.decode(result, (uint256))` would have read the ABI head
(`0x20` = 32) and forwarded **32 wei** of the bought token to the user, stranding the rest in the
adapter. Balance delta is router-agnostic and also covers routers that return nothing.

The backend was migrated to v2 alongside it (`get0xQuote` in `backend/src/run-executor.ts`):
`/swap/allowance-holder/quote`, header `0x-version: v2`, `slippageBps` instead of
`slippagePercentage`, and a `taker` — which must be the **adapter** address, since the adapter is
the contract that calls AllowanceHolder. This fix applies to Base and BSC too, whose swaps had
been silently failing since v1 was retired.

## Other fixes this deploy depended on

- `https://polygon-rpc.com` now returns **401 "API key disabled, tenant disabled"** for
  unauthenticated callers. Every default was switched to `https://polygon-bor-rpc.publicnode.com`
  (backend registry, `frontend/lib/server-chain.ts`, `get-bumped-gas.ts`, the cron route, both
  `scripts/set-*.js`, and `foundry.toml`).
- CoinGecko retired `matic-network` after the POL migration; it returns `{}`, which read as a $0
  native price for every Polygon run-cost estimate. Both copies of the id table now use
  `polygon-ecosystem-token`.

## Remaining operational steps

- Restart the backend relayer so it picks up the new addresses, and fund it with POL and KAVA.
- Redeploy the frontend so the synced addresses ship.
- Kava (2222) will log a failed-quote error per cycle for any plan created there until an
  Equilibre adapter exists. Pause 2222 via network allocation if that noise is unwanted.
