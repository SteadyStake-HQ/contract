# Contract Interaction Guide

Complete reference for interacting with SteadyStake smart contracts.

## Table of Contents
1. [Contract Addresses](#contract-addresses)
2. [Core Functions](#core-functions)
3. [Step-by-Step Flows](#step-by-step-flows)
4. [Error Handling](#error-handling)
5. [Gas Estimation](#gas-estimation)
6. [Event Monitoring](#event-monitoring)

## Contract Addresses

### Base Mainnet (Chain ID: 8453)
```solidity
USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975
DCAVault: [Deploy to get]
DCAResolver: [Deploy to get]
OneInch: 0x111111125421cA6dc452d289314280a0f8842A65
```

### Base Sepolia (Chain ID: 84532)
```solidity
MockUSDC: [Deploy to get]
MockAERO: [Deploy to get]
DCAVault: [Deploy to get]
DCAResolver: [Deploy to get]
```

## Core Functions

### 1. Create Schedule

**Function Signature:**
```solidity
function createSchedule(
    address targetToken,
    DCAFrequency frequency,
    uint256 amountPerInterval,
    uint256 totalAmount
) external returns (uint256)
```

**Parameters:**
- `targetToken`: ERC-20 token address (e.g., AERO)
- `frequency`: 0=DAILY, 1=WEEKLY, 2=BIWEEKLY, 3=MONTHLY
- `amountPerInterval`: USDC amount per execution (6 decimals). Example: 100e6 = 100 USDC
- `totalAmount`: Total USDC to allocate (6 decimals). Example: 1000e6 = 1000 USDC

**Returns:**
- Schedule ID (uint256) - Use for future references

**Prerequisites:**
1. User has USDC balance ≥ totalAmount
2. User approved vault to spend totalAmount
3. targetToken is valid ERC-20

**Gas Estimate:** ~150,000 gas

**Example (via Ethers.js):**
```typescript
const tx = await dca.createSchedule(
  "0x940181a94A35DC584061DeeA9B928900aa048AF6", // AERO
  1,                                              // WEEKLY
  ethers.parseUnits("100", 6),                   // 100 USDC per week
  ethers.parseUnits("1000", 6),                  // 1000 USDC total
);
const receipt = await tx.wait();
const scheduleId = receipt.events[0].args.scheduleId;
```

### 2. Execute Swap

**Function Signature:**
```solidity
function executeSwap(
    address user,
    uint256 scheduleId,
    bytes calldata swapData
) external
```

**Parameters:**
- `user`: User's wallet address
- `scheduleId`: Schedule ID from createSchedule()
- `swapData`: Encoded 1inch swap data (from API)

**Conditions:**
- Schedule must exist and be active
- Sufficient time must have passed (based on frequency)
- Schedule must have funds remaining

**Gas Estimate:** ~250,000 gas

**Note:** Usually called by Gelato automation, not directly by users.

### 3. Cancel Schedule

**Function Signature:**
```solidity
function cancelSchedule(uint256 scheduleId) external
```

**Parameters:**
- `scheduleId`: Schedule ID to cancel

**Effect:**
- Refunds remaining USDC to user
- Deactivates schedule

**Gas Estimate:** ~100,000 gas

**Example (via Ethers.js):**
```typescript
const tx = await dca.cancelSchedule(0); // Cancel first schedule
await tx.wait();
```

### 4. Get Active Schedules

**Function Signature:**
```solidity
function getActiveSchedules(address user) 
    external view returns (uint256[])
```

**Parameters:**
- `user`: User's wallet address

**Returns:**
- Array of active schedule IDs

**Gas:** None (view function)

**Example:**
```typescript
const schedules = await dca.getActiveSchedules(userAddress);
console.log(`User has ${schedules.length} active schedules`);
```

### 5. Get Schedule Details

**Function Signature:**
```solidity
function getSchedule(address user, uint256 scheduleId)
    external view returns (DCASchedule)
```

**Returns Structure:**
```solidity
struct DCASchedule {
    address targetToken;           // Token being accumulated
    DCAFrequency frequency;        // 0-3
    uint256 amountPerInterval;     // USDC per swap
    uint256 lastExecutionTime;     // Timestamp of last swap
    uint256 totalAmount;           // Remaining USDC
    uint256 executedCount;         // Number of swaps done
    bool active;                   // Is schedule active?
}
```

**Example:**
```typescript
const schedule = await dca.getSchedule(userAddress, 0);
console.log(`Target: ${schedule.targetToken}`);
console.log(`Remaining: ${schedule.totalAmount / 1e6} USDC`);
console.log(`Executed: ${schedule.executedCount} times`);
```

### 6. Check if Schedule is Ready

**Function Signature:**
```solidity
function isScheduleReady(address user, uint256 scheduleId)
    external view returns (bool)
```

**Returns:**
- `true` if enough time has passed and schedule has funds
- `false` otherwise

**Example:**
```typescript
const ready = await dca.isScheduleReady(userAddress, 0);
if (ready) {
  console.log("Schedule can be executed now");
}
```

## Step-by-Step Flows

### Flow 1: Create and Setup Schedule

```
1. User approves USDC
   └─ usdc.approve(dca, amount)

2. User creates schedule
   └─ dca.createSchedule(...) → scheduleId

3. Gelato monitors schedule
   └─ dca.isScheduleReady(user, scheduleId)

4. When ready, Gelato executes
   └─ dca.executeSwap(user, scheduleId, swapData)

5. User can cancel anytime
   └─ dca.cancelSchedule(scheduleId)
```

### Flow 2: Complete User Journey

```typescript
// Step 1: Get user input
const targetToken = "0x940181a94A35DC584061DeeA9B928900aa048AF6"; // AERO
const frequency = 1; // WEEKLY
const amountPerInterval = ethers.parseUnits("100", 6); // 100 USDC/week
const totalAmount = ethers.parseUnits("1000", 6); // 1000 USDC total

// Step 2: Approve USDC
const approveTx = await usdc.approve(dca.address, totalAmount);
await approveTx.wait();

// Step 3: Create schedule
const createTx = await dca.createSchedule(
  targetToken,
  frequency,
  amountPerInterval,
  totalAmount
);
const receipt = await createTx.wait();
const scheduleId = receipt.events[0].args.scheduleId;

// Step 4: Check schedule
const schedule = await dca.getSchedule(user, scheduleId);
console.log(`Created schedule with ID: ${scheduleId}`);
console.log(`Target token: ${schedule.targetToken}`);
console.log(`Amount per interval: ${schedule.amountPerInterval / 1e6} USDC`);

// Step 5: Monitor
const isReady = await dca.isScheduleReady(user, scheduleId);
console.log(`Ready for execution: ${isReady}`);

// Step 6: (Later) Cancel if needed
if (someCondition) {
  const cancelTx = await dca.cancelSchedule(scheduleId);
  await cancelTx.wait();
  console.log("Schedule cancelled and USDC refunded");
}
```

## Error Handling

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Invalid target token` | Token address is 0x0 | Verify token address |
| `Amount must be > 0` | amountPerInterval is 0 | Use amount > 0 |
| `Total must be >= interval` | totalAmount < amountPerInterval | Increase total amount |
| `Not enough time passed` | Calling before interval elapsed | Wait for next interval |
| `Schedule not active` | Schedule already cancelled | Check schedule status |
| `Insufficient balance` | Not enough USDC | Add more USDC |
| `Transfer failed` | Approval issue | Re-approve USDC |

### Error Handling Example

```typescript
try {
  const tx = await dca.createSchedule(...);
  await tx.wait();
} catch (error) {
  if (error.reason?.includes("Invalid target token")) {
    console.error("Token address not valid");
  } else if (error.reason?.includes("Amount must be > 0")) {
    console.error("Amount must be greater than 0");
  } else {
    console.error("Transaction failed:", error.message);
  }
}
```

## Gas Estimation

### Typical Gas Costs

| Operation | Gas | Cost (wei) | Cost ($USD) |
|-----------|-----|-----------|-----------|
| `createSchedule()` | 150,000 | varies | ~$0.10-0.50 |
| `executeSwap()` | 250,000 | varies | ~$0.20-1.00 |
| `cancelSchedule()` | 100,000 | varies | ~0.05-0.30 |
| `approve(USDC)` | 50,000 | varies | ~$0.05-0.15 |

**Base Fees:**
```
Gwei Price   | 0.1 tx    | 0.25 tx    | 0.5 tx
0.1 Gwei     | $0.01     | $0.03      | $0.05
1 Gwei       | $0.15     | $0.38      | $0.75
10 Gwei      | $1.50     | $3.75      | $7.50
```

### Estimate Gas Example

```typescript
const gasEstimate = await dca.estimateGas.createSchedule(
  targetToken,
  frequency,
  amountPerInterval,
  totalAmount
);
const gasCost = gasEstimate * gasPrice; // in wei
```

## Event Monitoring

### Events Emitted

#### ScheduleCreated
```solidity
event ScheduleCreated(
    address indexed user,
    uint256 indexed scheduleId,
    address targetToken,
    DCAFrequency frequency,
    uint256 amountPerInterval
)
```

**Monitoring:**
```typescript
dca.on("ScheduleCreated", (user, scheduleId, token, freq, amount) => {
  console.log(`Schedule ${scheduleId} created for ${token}`);
});
```

#### ScheduleExecuted
```solidity
event ScheduleExecuted(
    address indexed user,
    uint256 indexed scheduleId,
    address targetToken,
    uint256 usdcAmount,
    uint256 tokenOut,
    uint256 fee
)
```

**Monitoring:**
```typescript
dca.on("ScheduleExecuted", (user, scheduleId, token, usdc, out, fee) => {
  console.log(`Swap executed: ${usdc/1e6} USDC → ${out} tokens`);
  console.log(`Fee collected: ${fee/1e6} USDC`);
});
```

#### ScheduleCancelled
```solidity
event ScheduleCancelled(address indexed user, uint256 indexed scheduleId)
```

**Monitoring:**
```typescript
dca.on("ScheduleCancelled", (user, scheduleId) => {
  console.log(`Schedule ${scheduleId} cancelled`);
});
```

#### FeeCollected
```solidity
event FeeCollected(uint256 amount)
```

### Indexing Events

```typescript
// Get all events for a user
const events = await dca.queryFilter(
  dca.filters.ScheduleCreated(userAddress),
  0, // fromBlock
  "latest"
);

for (const event of events) {
  const { user, scheduleId, targetToken } = event.args;
  console.log(`Schedule ${scheduleId}: ${targetToken}`);
}
```

## Advanced Interactions

### Batch Check Schedules (Resolver)

```typescript
const scheduleIds = [0, 1, 2];
const [executables, payloads] = await resolver.batchChecker(
  user,
  scheduleIds
);

console.log(`${executables.length} schedules ready`);
```

### Calculate Fees

```typescript
const feePercentage = await dca.feePercentage();
const amount = ethers.parseUnits("100", 6);
const fee = amount.mul(feePercentage).div(10000);
console.log(`Fee on 100 USDC: ${fee / 1e6}`);
```

### Get Total Collected Fees

```typescript
const totalFees = await dca.totalFeesCollected();
console.log(`Total fees: ${totalFees / 1e6} USDC`);
```

## Testing Interactions

### Local Testing

```bash
# Run in Foundry
forge test -v --match-contract DCAVaultTest
```

### Testnet Testing

```bash
# Deploy to Sepolia
export PRIVATE_KEY=0x...
forge script script/Deploy.s.sol:DeployTestnet \
  --rpc-url base_sepolia \
  --broadcast
```

### Integration Testing

```typescript
// Use Foundry's testing utilities
import { expect } from "chai";
import { ethers } from "hardhat";

describe("DCA Integration", () => {
  it("should create and execute schedule", async () => {
    // Create schedule
    await usdc.approve(dca.address, amount);
    const tx = await dca.createSchedule(...);
    
    // Verify creation
    const schedules = await dca.getActiveSchedules(user);
    expect(schedules.length).to.equal(1);
  });
});
```

## Troubleshooting

### Transaction Failing

1. **Check allowance:**
   ```typescript
   const allowance = await usdc.allowance(userAddress, dca.address);
   console.log(`Allowance: ${allowance}`);
   ```

2. **Check balance:**
   ```typescript
   const balance = await usdc.balanceOf(userAddress);
   console.log(`Balance: ${balance}`);
   ```

3. **Check schedule:**
   ```typescript
   const schedule = await dca.getSchedule(userAddress, scheduleId);
   console.log(`Active: ${schedule.active}`);
   console.log(`Remaining: ${schedule.totalAmount}`);
   ```

### RPC Issues

- Use fallback RPC if primary fails
- Implement retry logic
- Monitor network conditions

```typescript
const provider = new ethers.providers.JsonRpcProvider(
  "https://mainnet.base.org",
  {
    chainId: 8453
  }
);
```

## Reference

- **Mainnet RPC:** https://mainnet.base.org
- **Testnet RPC:** https://sepolia.base.org
- **Block Explorer:** https://basescan.org
- **USDC Bridge:** https://bridge.base.org

## Support

For issues or questions:
1. Check ARCHITECTURE.md for design details
2. Check FRONTEND_INTEGRATION.md for React integration
3. Review test files for usage examples
4. Contact development team
