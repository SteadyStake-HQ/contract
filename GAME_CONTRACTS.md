# Echo Arena × SteadyStake — Game Contracts

The three new contracts from the *SteadyStake Game + Crypto Implementation Blueprint* §18.
All target solc `^0.8.19` and OpenZeppelin 5.5.0, matching the existing DCA contracts.

| Contract | Where it lives | Blueprint |
|---|---|---|
| `StablecoinGamePassCheckout` | One per **payment** network (Base, BOT, …) | §18.1 |
| `SeasonRewardNFT` | **Base only** (canonical award chain) | §18.2 |
| `AutoPlanCapacityVerifier` | One per **DCA** network (Base, BOT, Polygon, BNB, Kava, …) | §18.3 |

All admin surfaces are `AccessControl`-gated. On mainnet every admin role must sit behind the
project multisig (§24). The deploy scripts default the admin to the deployer **for testnet only**.

---

## 1. StablecoinGamePassCheckout

Accepts exactly one allowlisted stablecoin (chosen by address at deploy, never by symbol), moves the
configured price straight to the treasury, refuses a `purchaseId` twice, and emits `PassPaid` for the
backend indexer. The backend — not this contract — is the canonical source of cross-network pass
expiry (§18.1). Pausing blocks new buys only; passes already sold live off-chain and are untouched.

- **Balance-delta guard:** the treasury balance is asserted to rise by exactly `price`. This rejects
  fee-on-transfer tokens and tolerates USDT's return-less `transferFrom` (via SafeERC20 + delta, §18.4).
- **Roles:** `DEFAULT_ADMIN_ROLE`, `CONFIG_ROLE` (setPlan), `TREASURER_ROLE` (setTreasury), `PAUSER_ROLE`.
- **Plan ids (beta):** 1 = Day (24h / $0.99), 2 = Week (7d / $3.99), 3 = Month (30d / $9.99), priced in
  the stablecoin's decimals.

```bash
PRIVATE_KEY=0x... \
STABLECOIN_ADDRESS=0x833589fCD6eDb6E08f4C7C32D4f71b54bdA02913 \  # native USDC on Base
TREASURY_ADDRESS=0x... \
# PASS_ADMIN=0x<multisig>   # mainnet: set + re-grant/revoke admin after
forge script script/DeployGamePassCheckout.s.sol --rpc-url base --broadcast
```

## 2. SeasonRewardNFT

ERC-721 + ERC-5192 soulbound. Every token is permanently locked: transfers and approvals revert; only
mint (and burn, reserved for a future migration) move a token. Two-step award (§14):

1. `registerSeasonResult(seasonId, rulesHash, snapshotHash, winners[3], tokenURIs[3])` — `FINALIZER_ROLE`,
   once per season. A zero winner address means "fewer than three eligible players" (§14.3); that rank
   can't be minted.
2. `mintSeasonAward(seasonId, rank)` — `MINTER_ROLE`. Deterministic `tokenId = (seasonId << 8) | rank`.
   Recipient can only be one of the three registered addresses (dashboard can't inject a wallet).
   `bonusSlots = 4 - rank` → rank 1/2/3 give **+3/+2/+1** Auto Execution slots. The **contract** is the
   authority on the slot value, never metadata (§13.2).

```bash
PRIVATE_KEY=0x... \
# NFT_ADMIN=0x<multisig>    # mainnet
forge script script/DeploySeasonRewardNFT.s.sol --rpc-url base --broadcast
```

## 3. AutoPlanCapacityVerifier

Per-DCA-network EIP-712 verifier for NFT-bonus plans (§16). The NFT is canonical on Base, but plans
exist on many chains and no chain can read another's state — so the backend capacity service (after
locking the account row and confirming a free bonus slot, §16.3) signs a short-lived permit that this
contract verifies on the target chain and single-uses by nonce. Fails closed.

- **`consumePermit(permit, signature)`** — `VAULT_ROLE` only. Checks `targetChainId == block.chainid`,
  `deadline` in the future and ≤ `issuedAt + 5min`, unused nonce, and a `SIGNER_ROLE` signer.
- **`hashPermit` / `domainSeparator`** — helpers so the backend signer reproduces the exact digest.
- **EIP-712 domain name/version MUST match the backend signer** or every permit fails.

```bash
PRIVATE_KEY=0x... \
CAPACITY_SIGNER=0x<backend capacity key> \
# VERIFIER_ADMIN=0x<multisig>   VAULT_ADDRESS=0x<dca vault>   # mainnet / once vault wired
EIP712_NAME="Echo Arena Capacity" EIP712_VERSION=1 \
forge script script/DeployCapacityVerifier.s.sol --rpc-url base --broadcast
```

> **Vault wiring is Phase 6, not done here.** The verifier is standalone. Actually *enforcing* the
> permit needs the DCAVault to call `consumePermit` on a new "create bonus plan" path — but vaults are
> live on 5 mainnets. Whether to add a new entrypoint or redeploy is a separate decision. For now the
> verifier + `IAutoPlanCapacityVerifier` interface are ready for that integration.

---

## After deploying: sync the addresses into the backend

Deploys record their addresses in `contracts/deployed-game-contracts.json`. That file is **not
enough on its own** — `backend/` and `contracts/` are separate git repos, so Railway builds the
backend without any sibling `contracts/` directory. A backend that cannot find the file reports
every chain as "no game contracts deployed", silently, on all four consumers: the networks
dashboard, the balances page, the capacity permit signer, and the `payment_networks` boot seed.

So after every game deploy:

```bash
cd backend
pnpm run sync:game-contracts   # copies contracts/deployed-game-contracts.json -> backend/
git add deployed-game-contracts.json && git commit -m "sync game contract addresses"
```

`pnpm run check:game-contracts` exits non-zero when the backend copy is stale — use it in CI.

The backend prefers the sibling `contracts/` file when one exists, so a local redeploy shows the new
addresses immediately; the committed copy is the fallback that production actually reads. Nothing
needs to change in `frontend/` or the game: both read the checkout address from the backend API
(`/api/pass/options`), never from a file.

## Testing

```bash
forge test --match-contract "StablecoinGamePassCheckoutTest|SeasonRewardNFTTest|AutoPlanCapacityVerifierTest" -vv
```

28 tests cover: exact-amount receipt, reused purchase id, USDT return-less path, fee-token rejection,
pause, role gating (checkout); register-once, rank→bonus mapping, duplicate/zero-winner/invalid-rank
mint reverts, soulbound transfer/approve reverts, `locked`/interface ids (NFT); valid/replay/expired/
ttl/wrong-chain/bad-signer/non-vault permit paths (verifier).

## Machine note (this workstation)

`forge test` and `forge build` work (svm `solc` was patched — see BOT deploy notes). **`forge script`
SIGILLs before compiling on this box**, so live deploys use the viem-script workaround (read
`out/*.json` bytecode + deployer key, write a forge-compatible `broadcast/.../run-latest.json`). The
`forge script … --broadcast` commands above are the canonical form for a machine where the subcommand
works, and for CI.
