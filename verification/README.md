# Verifying the mainnet $SS4 contracts on BOTScan

Both contracts are deployed and frozen on BOT Chain mainnet (677) but **not source-verified**.

## Why this could not be done from the deploy machine

`https://scan.botchain.ai` sits behind a Cloudflare WAF that returns **403** to any POST whose body
carries Solidity source. Everything else about the endpoint works from the same host:

| request | result |
|---|---|
| `GET /api?module=contract&action=getabi&...` (browser UA) | 200 |
| `GET /api/v2/smart-contracts/verification/config` | 200 |
| `POST /api` with a small form body | 200 |
| `POST /api` with a 250 KB dummy body | 200 |
| `POST /api/v2/.../verification/via/standard-input` (multipart) | **403** |
| `POST /api` `action=verifysourcecode` + standard JSON | **403** |

So it is neither the method, nor the body size, nor a missing API key — it is content inspection.
`forge verify-contract` fails earlier still, because Cloudflare rejects its default User-Agent
outright. The testnet explorer (`scan.bohr.life`) has no such rule, which is why all six rehearsals
verified without trouble.

**Verification is cosmetic here** — it publishes the source behind an address that is already
deployed and frozen. It changes nothing about how the sale behaves.

## How to finish it

From a browser (any network), or from a host Cloudflare does not challenge:

**BOTScan → the contract address → Contract tab → Verify & Publish →
"Solidity (Standard JSON Input)"**, then supply:

### SS4Token — `0xf21f791937263F22c1860DfbcB975deCfCDe5D1f`
- Compiler: `v0.8.35+commit.47b9dedd`
- License: MIT
- Standard JSON: [`SS4Token.standard-input.json`](SS4Token.standard-input.json)
- Constructor args (ABI-encoded, no `0x`): [`SS4Token.constructor-args.txt`](SS4Token.constructor-args.txt)

### SS4PresaleV3 — `0x1EfEA1a3A4FA3fdedfAd4005dDB94eDF7B36BD13`
- Compiler: `v0.8.35+commit.47b9dedd`
- License: MIT
- Standard JSON: [`SS4PresaleV3.standard-input.json`](SS4PresaleV3.standard-input.json)
- Constructor args (ABI-encoded, no `0x`): [`SS4PresaleV3.constructor-args.txt`](SS4PresaleV3.constructor-args.txt)

Optimizer is **on at 200 runs** for both (profile `ss4-optimized`) and is already encoded in the
standard-input files — do not re-enter it by hand.

Or, from an unblocked host with this repo checked out:

```bash
forge verify-contract 0xf21f791937263F22c1860DfbcB975deCfCDe5D1f src/token/SS4Token.sol:SS4Token \
  --chain 677 --verifier blockscout --verifier-url https://scan.botchain.ai/api \
  --compilation-profile ss4-optimized \
  --constructor-args "0x$(cat verification/SS4Token.constructor-args.txt)" --watch

forge verify-contract 0x1EfEA1a3A4FA3fdedfAd4005dDB94eDF7B36BD13 src/sale/SS4PresaleV3.sol:SS4PresaleV3 \
  --chain 677 --verifier blockscout --verifier-url https://scan.botchain.ai/api \
  --compilation-profile ss4-optimized \
  --constructor-args "0x$(cat verification/SS4PresaleV3.constructor-args.txt)" --watch
```

After it succeeds, flip `verified` to `true` and drop `verificationNote` for both contracts in
`deployed-ss4-contracts.json`, then re-run `npm run sync:ss4-contracts` from `backend/`.
