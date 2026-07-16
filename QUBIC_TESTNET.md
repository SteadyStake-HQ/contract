# Qubic Testnet – Faucet & Test Resources

Use the [Qubic testnet](https://docs.qubic.org/developers/testnet-resources) for development and testing. SteadyStake’s Solidity contracts deploy to **Base / Base Sepolia** (EVM). This page is for getting **test funds on Qubic** and using the Qubic testnet RPC.

**Official docs:** [Testnet Resources | Qubic Docs](https://docs.qubic.org/developers/testnet-resources)

---

## Testnet RPC

| Resource   | Value |
|-----------|--------|
| **Public testnet RPC** | `https://testnet-rpc.qubic.org` |
| **Use case**          | General development and testing |

For hackathons or specific programs, dedicated testnet nodes (with their own IP/RPC) may be provided.

---

## Get Test Funds (Faucet)

To get test Qubics for your wallet:

1. Join the **Qubic Discord**.
2. Go to the **`#bot-commands`** channel.
3. Use the **faucet command** to receive:
   - **1000 Qubics** on mainnet  
   - **Test Qubics** for the testnet RPC  

Use these for testing and interacting with the network during development.

---

## Pre-funded Testnet Seeds

For testing, you can use these pre-funded seeds on the testnet (each has ~1 billion Qubic tokens). Use them with the Qubic CLI, e.g.:

```bash
./qubic-cli -nodeip YOUR_NODE_IP -nodeport YOUR_NODE_PORT -seed <SEED> -somecommand
```

**Seeds (use only on testnet):**

```
fwqatwliqyszxivzgtyyfllymopjimkyoreolgyflsnfpcytkhagqii
xpsxzzfqvaohzzwlbofvqkqeemzhnrscpeeokoumekfodtgzmwghtqm
ukzbkszgzpipmxrrqcxcppumxoxzerrvbjgthinzodrlyblkedutmsy
wgfqazfmgucrluchpuivdkguaijrowcnuclfsjrthfezqapnjelkgll
kewgvatawujuzikurbhwkrisjiubfxgfqkrvcqvfvgfgajphbvhlaos
nkhvicelolicthrcupurhzyftctcextifzkoyvcwgxnjsjdsfrtbrbl
otyqpudtgogpornpqbjfzkohralgffaajabxzhneoormvnstheuoyay
ttcrkhjulvxroglycvlpgesnxpwgjgvafpezwdezworzwcfobevoacx
mvssxxbnmincnnjhtrlbdffulimsbmzluzrtbjqcbvaqkeesjzevllk
jjhikmkgwhyflqdszdxpcjrilnoxerfeyttbbjahapatglpqgctnkue
nztizdwotovhuzchctpfdgylzmsdfxlvdcpikhmptqjbwwgbxavhtwo
lxbjeczdoqyjtzhizbeapkbpvfdbgxxbdbhyfvzhbkysmgdxuzspmwu
zwoggmzfbdhuxrikdhqrmcxaqmpmdblgsdjzlesfnyogxquwzutracm
inkzmjoxytbhmvuuailtfarjgooearejunwlzsnvczcamsvjlrobsof
htvhtfjxzqandmcshkfifmrsrikrcpsxmnemcjthtmyvsqqcvwckwfk
hmsmhamftvncxcdvxytqgdihxfncarwzatpjuoecjqhceoepysozwlp
wrnohgpgfuudvhtwnuyleimplivlxcaswuwqezusyjddgkdigtueswb
fisfusaykkovsskpgvsaclcjjyfstrstgpebxvsqeikhneqaxvqcwsf
jftgpcowwnmommeplhbvgotjxrtkmiddcjmitbxoekwunmlpmdakjzq
svaluwylhjejvyjvgmqsqjcufulhusbkkujwrwfgdphdmesqjirsoep
lzinqhyvomjzqoyluifguhytcgpftdxndswbcqriecatcmfidbnmvka
mqamjotnshocvekufdqylgtdcembtddlfockjyaotfdvzqpvkylsjjk
asueorfnexvnthcuicsqqppekcdrwizxqlnkzdkazsymrotjtmdnofe
ahfulnoaeuoiurixbjygqxiaklmiwhysazqylyqhitjsgezhqwnpgql
omyxajeenkikjvihmysvkbftzqrtsjfstlmycfwqjyaihtldnetvkrw
zrfpagcpqfkwjimnrehibkctvwsyzocuikgpedchcyaotcamzaxpivq
kexrupgtmbmwwzlcpqccemtgvolpzqezybmgaedaganynsnjijfyvcn
```

---

## How This Repo Uses Qubic Testnet

- **RPC endpoint** is defined in `foundry.toml` as `qubic_testnet` for reference (Qubic is non-EVM; our Solidity contracts deploy to Base/Base Sepolia).
- **Faucet:** Use Discord **#bot-commands** to get test Qubics to your wallet.
- **Seeds:** Use the list above with the Qubic CLI for automated or scripted testing.

---

## Monitoring Transactions (Qubic)

To watch transactions on your node you can use qlogging, for example:

```bash
./qubic/scripts/qlogging 127.0.0.1 31841 1 2 3 4 21180000
```

---

## Best Practices (from Qubic docs)

1. Use the **Qubic CLI** for direct interaction with contracts.
2. **Monitor logs** (e.g. qlogging) to debug transactions.
3. **Test with small amounts** first.
4. **Clean up** when using a dedicated node.
5. **Document your contract index** for later use.
