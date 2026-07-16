# Verify SteadyStake contracts on Kava (Kavascan)

Foundry’s `forge verify-contract` does **not** work with Kava’s explorer API (Cosmostation/Mintscan). Use the artifacts in this folder to verify manually on Kavascan.

## Contract addresses (Kava mainnet, chain 2222)

| Contract      | Address                                      |
| ------------- | -------------------------------------------- |
| ZeroExAdapter | `0x575C97aF6fFe3fB5F70776158cBc961C70df51ed` |
| DCAVault      | `0x749745696DD456761cB0c2FdB9E3e190E1f5382d` |
| DCAResolver   | `0x16486aeAFe203595FE27854353f1F40e1e31537A` |

## Constructor arguments (ABI-encoded)

Use these when Kavascan asks for constructor arguments:

- **ZeroExAdapter**:  
  `000000000000000000000000fa9343c3897324496a05fc75abed6bac29f8a40f000000000000000000000000def1c0ded9bec7f1a1670819833240f027b25eff`

- **DCAVault**:  
  `000000000000000000000000575c97af6ffe3fb5f70776158cbc961c70df51ed000000000000000000000000fa9343c3897324496a05fc75abed6bac29f8a40f`

- **DCAResolver**:  
  `000000000000000000000000749745696dd456761cb0c2fdb9e3e190e1f5382d`

## Verification steps (Kavascan)

1. Open the contract page (e.g.  
   `https://kavascan.com/address/0x575C97aF6fFe3fB5F70776158cBc961C70df51ed`).
2. Go to the **Contract** tab and start verification.
3. Choose **Standard-JSON-Input**.
4. Upload the matching file from this folder:
   - `ZeroExAdapter-standard-input.json` → contract **SwapHelper.sol : ZeroExAdapter**
   - `DCAVault-standard-input.json` → contract **DCAVault.sol : DCAVault**
   - `DCAResolver-standard-input.json` → contract **DCAResolver.sol : DCAResolver**
5. Enter the **constructor arguments** (hex string, no `0x` prefix) from the table above.
6. Submit. Compiler: **0.8.33**, optimization: **default** (as in `foundry.toml`).

If verification fails, ensure compiler version and optimizer runs match the deployment (see `foundry.toml` and `forge build`).

Ref: [Kava contract verification](https://docs.kava.io/docs/ethereum/contract_verification).
