# SteadyStake Project Integration Guide

Complete guide for integrating smart contracts with the frontend application.

## Project Structure

```
steadystake/
├── frontend/                    # Next.js application
│   ├── app/
│   ├── config/
│   ├── components/
│   └── package.json
│
└── contracts/                   # Smart contracts (NEW!)
    ├── src/                     # Core contracts
    ├── test/                    # Unit tests
    ├── script/                  # Deployment
    ├── README.md
    ├── ARCHITECTURE.md
    ├── FRONTEND_INTEGRATION.md
    └── package.json
```

## Quick Start

### 1. Setup Contracts (Backend)

```bash
cd contracts

# Install dependencies
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Build
forge build

# Test
forge test

# Deploy to Sepolia testnet
export PRIVATE_KEY=0x...
export BASE_ETHERSCAN_KEY=...
make deploy-testnet
```

### 2. Setup Frontend (Frontend)

```bash
cd frontend

# Install dependencies
npm install

# Add contract addresses to .env
echo "NEXT_PUBLIC_DCA_VAULT=0x..." >> .env.local
echo "NEXT_PUBLIC_DCA_RESOLVER=0x..." >> .env.local
echo "NEXT_PUBLIC_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975" >> .env.local

# Run development server
npm run dev
```

### 3. Verify Integration

- Navigate to http://localhost:3000
- Connect wallet (Coinbase Wallet recommended for Base)
- Create a test DCA schedule
- Monitor Gelato automation

## Contract Deployment Output

After running `make deploy-testnet`, you'll see:

```
=== SteadyStake Deployment ===
MockUSDC: 0x1234...
MockAERO: 0x5678...
MockDEGEN: 0xabcd...
MockCBETH: 0xef01...
SwapRouter: 0x2345...
DCAVault: 0x6789...
DCAResolver: 0xghij...
```

### Copy Addresses to Frontend

Create `frontend/.env.local`:

```env
# Contracts
NEXT_PUBLIC_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975
NEXT_PUBLIC_DCA_VAULT=0x6789...      # Copy from deployment
NEXT_PUBLIC_DCA_RESOLVER=0xghij...    # Copy from deployment
NEXT_PUBLIC_CHAIN_ID=84532            # Sepolia for testing

# RPC
NEXT_PUBLIC_RPC_URL=https://sepolia.base.org

# Gelato (if using)
GELATO_API_KEY=your_key
```

## Frontend Integration Steps

### 1. Update Contract Addresses

**File:** `frontend/config/contracts.ts`

```typescript
export const CONTRACTS = {
  USDC: process.env.NEXT_PUBLIC_USDC || 
    "0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975",
  DCAVault: process.env.NEXT_PUBLIC_DCA_VAULT || "",
  DCAResolver: process.env.NEXT_PUBLIC_DCA_RESOLVER || "",
};

export const RPC_URLS = {
  [8453]: "https://mainnet.base.org",        // Mainnet
  [84532]: "https://sepolia.base.org",       // Sepolia
};

export const CHAIN_ID = 
  process.env.NEXT_PUBLIC_CHAIN_ID === "8453" ? 8453 : 84532;
```

### 2. Create React Hooks

**File:** `frontend/hooks/useDCA.ts`

```typescript
import { useContractWrite, usePrepareContractWrite } from "wagmi";
import { CONTRACTS } from "@/config/contracts";
import DCA_VAULT_ABI from "@/abis/DCAVault.json";

export function useCreateSchedule() {
  const { config } = usePrepareContractWrite({
    address: CONTRACTS.DCAVault as `0x${string}`,
    abi: DCA_VAULT_ABI,
    functionName: "createSchedule",
  });

  const { write, data, isLoading } = useContractWrite(config);

  return { createSchedule: write, txHash: data?.hash, isLoading };
}
```

### 3. Copy Contract ABIs

Create `frontend/abis/` directory and copy these:

```bash
mkdir -p frontend/abis

# Copy from contract artifacts
cp contracts/out/DCAVault.sol/DCAVault.json frontend/abis/
cp contracts/out/DCAResolver.sol/DCAResolver.json frontend/abis/
cp contracts/out/MockTokens.sol/MockUSDC.json frontend/abis/
```

Or generate manually:

**File:** `frontend/abis/DCAVault.json`

```json
{
  "abi": [
    {
      "name": "createSchedule",
      "type": "function",
      "stateMutability": "nonpayable",
      "inputs": [
        {"name": "targetToken", "type": "address"},
        {"name": "frequency", "type": "uint8"},
        {"name": "amountPerInterval", "type": "uint256"},
        {"name": "totalAmount", "type": "uint256"}
      ],
      "outputs": [{"name": "scheduleId", "type": "uint256"}]
    }
  ]
}
```

### 4. Create Dashboard Component

**File:** `frontend/app/components/dashboard/CreateSchedule.tsx`

```typescript
import { useState } from "react";
import { useAccount } from "wagmi";
import { useCreateSchedule } from "@/hooks/useDCA";
import { CONTRACTS } from "@/config/contracts";
import { parseUnits } from "ethers";

const FREQUENCIES = {
  0: "Daily",
  1: "Weekly",
  2: "Biweekly",
  3: "Monthly",
};

export function CreateSchedule() {
  const { address } = useAccount();
  const [token, setToken] = useState("");
  const [frequency, setFrequency] = useState(1);
  const [amountPerInterval, setAmountPerInterval] = useState("");
  const [totalAmount, setTotalAmount] = useState("");
  
  const { createSchedule, isLoading } = useCreateSchedule();

  const handleCreate = () => {
    createSchedule?.({
      args: [
        token as `0x${string}`,
        frequency,
        parseUnits(amountPerInterval, 6),
        parseUnits(totalAmount, 6),
      ],
    });
  };

  return (
    <div className="space-y-4">
      <div>
        <label>Token Address</label>
        <input
          value={token}
          onChange={(e) => setToken(e.target.value)}
          placeholder="0x..."
          className="w-full border rounded px-3 py-2"
        />
      </div>

      <div>
        <label>Frequency</label>
        <select
          value={frequency}
          onChange={(e) => setFrequency(Number(e.target.value))}
          className="w-full border rounded px-3 py-2"
        >
          {Object.entries(FREQUENCIES).map(([key, value]) => (
            <option key={key} value={key}>
              {value}
            </option>
          ))}
        </select>
      </div>

      <div>
        <label>Amount per Interval (USDC)</label>
        <input
          type="number"
          value={amountPerInterval}
          onChange={(e) => setAmountPerInterval(e.target.value)}
          placeholder="100"
          className="w-full border rounded px-3 py-2"
        />
      </div>

      <div>
        <label>Total Amount (USDC)</label>
        <input
          type="number"
          value={totalAmount}
          onChange={(e) => setTotalAmount(e.target.value)}
          placeholder="1000"
          className="w-full border rounded px-3 py-2"
        />
      </div>

      <button
        onClick={handleCreate}
        disabled={isLoading}
        className="w-full bg-blue-500 text-white px-4 py-2 rounded disabled:opacity-50"
      >
        {isLoading ? "Creating..." : "Create Schedule"}
      </button>
    </div>
  );
}
```

### 5. Update Existing Components

**Update:** `frontend/app/components/Header.tsx`

Add network indicator and contract status:

```typescript
import { useNetwork } from "wagmi";
import { CONTRACTS } from "@/config/contracts";

export function Header() {
  const { chain } = useNetwork();

  return (
    <header className="flex justify-between items-center p-4 border-b">
      <h1>SteadyStake</h1>
      
      <div className="flex gap-4">
        <span className="text-sm">
          Network: {chain?.name || "Unknown"}
        </span>
        
        {CONTRACTS.DCAVault && (
          <span className="text-sm text-green-600">✓ Contracts Ready</span>
        )}
        
        <CustomConnectButton />
      </div>
    </header>
  );
}
```

## Testing the Integration

### Local Testing

```bash
# Terminal 1: Run contract tests
cd contracts
forge test -v

# Terminal 2: Run frontend
cd frontend
npm run dev
```

### Testnet Testing

```bash
# Deploy contracts
cd contracts
make deploy-testnet

# Update frontend .env.local with addresses

# Test in browser
# 1. Navigate to localhost:3000
# 2. Connect Coinbase Wallet to Base Sepolia
# 3. Request test USDC from faucet
# 4. Create test DCA schedule
# 5. Monitor on Basescan
```

## Monitoring & Debugging

### 1. Check Contract Deployment

```bash
cd contracts
forge verify-contract \
  --chain-id 84532 \
  0x... # Contract address
```

### 2. Monitor Events

```typescript
// In frontend component
import { useContractEvent } from "wagmi";

useContractEvent({
  address: CONTRACTS.DCAVault,
  abi: DCA_VAULT_ABI,
  eventName: "ScheduleCreated",
  listener: (log) => {
    console.log("Schedule created:", log);
  },
});
```

### 3. Check Gelato Tasks

Visit https://app.gelato.network/ to:
- View active automation tasks
- Monitor execution history
- Check gas costs

### 4. Debug Contract State

```typescript
// Get schedule details
const schedule = await publicClient.readContract({
  address: CONTRACTS.DCAVault,
  abi: DCA_VAULT_ABI,
  functionName: "getSchedule",
  args: [userAddress, scheduleId],
});

console.log(schedule);
```

## Deployment Workflow

### Phase 1: Development

```
contracts/       →  Local testing
├─ forge test          (40+ tests)
└─ foundry.toml        (dev config)

frontend/        →  Local integration
├─ npm run dev         (React dev server)
└─ Mock contracts      (In-memory)
```

### Phase 2: Testnet (Base Sepolia)

```
contracts/       →  Deploy to Sepolia
├─ make deploy-testnet  (Automated)
└─ Script output        (Contract addresses)

frontend/        →  Connect to Sepolia
├─ Update .env.local    (Contract addresses)
├─ npm run dev          (React dev server)
└─ Test all features    (Live testnet)
```

### Phase 3: Mainnet (Base)

```
contracts/       →  Audit + Mainnet Deploy
├─ Security audit       (Cyfrin/Code4rena)
├─ make deploy-mainnet  (Production)
└─ Verify on Basescan   (Public visibility)

frontend/        →  Deploy to Production
├─ Update .env.prod     (Mainnet addresses)
├─ Deploy to Vercel     (CDN)
└─ Monitor production   (24/7)
```

## Environment Configuration

### Development (.env.local)

```env
# Contracts - Testnet
NEXT_PUBLIC_USDC=0x1234...
NEXT_PUBLIC_DCA_VAULT=0x5678...
NEXT_PUBLIC_DCA_RESOLVER=0xabcd...
NEXT_PUBLIC_CHAIN_ID=84532

# RPC
NEXT_PUBLIC_RPC_URL=https://sepolia.base.org
```

### Production (.env.production)

```env
# Contracts - Mainnet
NEXT_PUBLIC_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975
NEXT_PUBLIC_DCA_VAULT=0x...
NEXT_PUBLIC_DCA_RESOLVER=0x...
NEXT_PUBLIC_CHAIN_ID=8453

# RPC
NEXT_PUBLIC_RPC_URL=https://mainnet.base.org

# Gelato
GELATO_API_KEY=...
```

## Documentation Links

- **Backend Docs:** [contracts/README.md](contracts/README.md)
- **Architecture:** [contracts/ARCHITECTURE.md](contracts/ARCHITECTURE.md)
- **Frontend Guide:** [contracts/FRONTEND_INTEGRATION.md](contracts/FRONTEND_INTEGRATION.md)
- **Contract Interactions:** [contracts/CONTRACT_INTERACTIONS.md](contracts/CONTRACT_INTERACTIONS.md)
- **Diagrams:** [contracts/DIAGRAMS.md](contracts/DIAGRAMS.md)

## Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| Contract address not found | Run `make deploy-testnet` and copy addresses |
| USDC approval fails | Ensure contract address is correct in .env |
| Gelato task not executing | Check DCAResolver deployed correctly |
| Gas too high | Use Sepolia testnet (cheaper) before mainnet |
| Wallet connection issues | Use Coinbase Wallet for Base |

## Performance Considerations

### Gas Optimization

- **Create Schedule:** ~150k gas
- **Execute Swap:** ~250k gas  
- **Cancel Schedule:** ~100k gas

### Batch Operations

For multiple schedules:

```typescript
// Use resolver batch checker
const [ready, payloads] = await resolver.batchChecker(
  userAddress,
  [0, 1, 2, 3] // Multiple schedule IDs
);
```

## Security Checklist

✅ Before Mainnet Deployment:
- [ ] All tests passing (`forge test`)
- [ ] Coverage report generated (`forge coverage`)
- [ ] Security audit completed
- [ ] NatSpec documentation complete
- [ ] Contract verified on Basescan
- [ ] Frontend environment variables set correctly
- [ ] USDC approval working
- [ ] Gelato tasks created successfully
- [ ] Monitored for 24+ hours on testnet

## Next Steps

1. **Deploy Contracts:**
   ```bash
   cd contracts && make deploy-testnet
   ```

2. **Update Frontend:**
   - Copy contract addresses to `.env.local`
   - Run `npm install`
   - Run `npm run dev`

3. **Test Integration:**
   - Connect wallet
   - Create schedule
   - Monitor Gelato execution

4. **Go Mainnet:**
   - Run security audit
   - Deploy to Base mainnet
   - Deploy frontend to Vercel

## Support & Resources

- **Frontend:** frontend/README.md
- **Contracts:** contracts/README.md
- **Architecture:** contracts/ARCHITECTURE.md
- **API Reference:** contracts/CONTRACT_INTERACTIONS.md
- **Diagrams:** contracts/DIAGRAMS.md
- **Discord:** [SteadyStake Community]
- **GitHub Issues:** [steadystake/issues]

---

**Status:** ✅ Ready for Integration & Testing

Start with the Quick Start section above!
