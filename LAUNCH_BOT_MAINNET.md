# $SS4 mainnet launch — BOT Chain 677

**Deployed 2026-08-20 04:53 UTC. The sale is LIVE.**

| | |
|---|---|
| `SS4Token` | [`0xf21f791937263F22c1860DfbcB975deCfCDe5D1f`](https://scan.botchain.ai/address/0xf21f791937263F22c1860DfbcB975deCfCDe5D1f) |
| `SS4PresaleV3` | [`0x1EfEA1a3A4FA3fdedfAd4005dDB94eDF7B36BD13`](https://scan.botchain.ai/address/0x1EfEA1a3A4FA3fdedfAd4005dDB94eDF7B36BD13) |
| Payment | bridged **USDT** `0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C` (6 dec) |
| Admin | `0x1BF1fdC063dF1239a9407767C5be36e746104294` (deployer) |
| Campaign signer | `0x5e3EFe20697B858901a21496b49Ac653618104a3` |
| `configHash` | `0x53748fb7ef9d3c3ee6d06ca1d9d44453ca2c0a7380b9b0081e4398c30981ff7f` |
| EIP-712 `domainSeparator` | `0x0883e843d4cf6a35d663e750d6de1e3cf32aba0d4c165e17d89919a685d50063` |
| Deployed by | `script/DeploySS4Mainnet.s.sol` (chain-gated to 677) |
| Token block / tx | 20290315 / `0x9b597fc33ef5a7a7e2cf09a8790c75db83a9ed6c4dd09b20316987ed5813cfea` |
| Sale block / tx | 20290321 / `0x51a0557b41656551b5a2fa6e3e6d90f8dab82d84b9ecc95f80270bdaa5397ba1` |
| Gas | 9,244,788 total across 8 txs — 0.1413 BOT at 20 gwei |

## Frozen terms — these are the published ones, not rehearsal values

| Term | Value |
|---|---|
| Price | $0.004 per `$SS4` (`priceUsdE6` 4000) |
| Sale allocation | 50,000,000 SS4 |
| Campaign reserve | 7,500,000 SS4 |
| Soft cap | $16,000 |
| Hard cap | $200,000 |
| Minimum buy | $4 |
| Per-wallet cap | $4,444 |
| Window | 2026-08-20 00:00 UTC → 2026-09-02 00:00 UTC |
| Claim opens | 2026-09-02 00:00 UTC, 100% unlocked (`tgeUnlockBps` 10000, no vesting) |
| Campaign ceiling | +5.50% (`maxCampaignBoostBps` 550) |

`saleStart` was already ~5 hours in the past when the freeze confirmed. `configure()` validates only
that the schedule is *ordered*, never that it is in the future, so the sale went **Active on the
freeze** rather than waiting — `state()` returned `1` immediately after deploy.

**§7.5 configuration is atomic and one-way.** Nothing above can be changed by any call. A correction
costs a new address and a migration, which is what the six superseded testnet rehearsals were about.

## Why this script exists

`DeploySS4.s.sol` and `DeploySS4PresaleV3.s.sol` are both hard-gated to chain **968**, so a mistyped
`--rpc-url` cannot put real supply somewhere unintended. Relaxing either guard would delete that
protection for every future rehearsal, so mainnet got its own script with the mirror-image guard:
`DeploySS4Mainnet.s.sol` refuses to run anywhere **except** 677.

It also deploys the token and the sale in one broadcast, unlike the V3 rehearsal script which took an
existing token address. `$SS4` has a fixed supply minted once in the constructor — there is no second
chance to mint — so a half-finished launch must not be able to leave a supply on chain with no sale
behind it.

## Verified after deploy (read back from chain, not from the script's own output)

- `state() == 1` (Active), `configFrozen == true`, not paused / finalized / cancelled
- `ss4()` points at the deployed token; sale holds **57,500,000 SS4** (50M sale + 7.5M reserve)
- USDT accepted at exactly 6 decimals
- Campaign signer holds `CAMPAIGN_SIGNER_ROLE`; **the admin/deployer deliberately does not**
  (`hasRole(role, admin) == false`)
- A backend-signed voucher reproduces the contract's own `campaignVoucherDigest` and recovers to the
  signer — the whole campaign path works against the live sale
- `previewPurchase`: $4 → 1,000 SS4; $4,444 → 1,111,000 SS4. `quoteBoost` at 550 bps → +61,105 SS4
- Worst-case boost demand is 2.75M SS4 against a funded 7.5M reserve, so this sale cannot exhaust it

`test/fork/MainnetLaunch.t.sol` forks mainnet and completes real buys (plain and campaign) plus every
limit and the voucher-replay guard, without spending anything:

```bash
forge test --match-path "test/fork/MainnetLaunch.t.sol" -vv
```

## Known gaps

**Source is not verified on BOTScan.** `scan.botchain.ai` sits behind a Cloudflare WAF that 403s any
POST carrying Solidity source — GETs, plain POSTs and 250 KB dummy bodies all pass, so it is content
inspection rather than method, size or key. The testnet explorer has no such rule, which is why all
six rehearsals verified. Ready-to-upload artifacts and instructions are in
[`verification/`](verification/README.md). Verification is cosmetic — it publishes source behind an
address that is already deployed and frozen.

**All six token allocations were minted to the deployer EOA**, which §3.3 and §22.1 forbid for
production. This was a deliberate owner decision to avoid blocking the launch on six vaults existing,
with the intent to move the pools to vaults/multisigs afterwards. The supply is ordinary ERC-20 and
transferable, so that migration is possible — but the `AllocationMinted` events and
`allocationRecipients()` record the EOA permanently, and until the pools move, one hot key holds
1,000,000,000 SS4.

**Not audited.**

**The admin is an EOA.** It holds finalize / cancel / withdraw / pause and receives the raised USDT.
Roles are not part of `configHash`, so this one *is* changeable — transfer it to a multisig.

## Settlement

`settle()` reverts below the $16,000 soft cap. If the raise closes under it, the sale can only be
cancelled and refunded, never finalized — the same thing that stranded testnet rehearsal `0x19fEB663`.
