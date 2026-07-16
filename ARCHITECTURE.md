# SteadyStake Architecture Documentation

## System Overview

SteadyStake is built on a modular architecture with three core layers:

```
┌─────────────────────────────────────────────┐
│     Frontend (Next.js + RainbowKit)         │
│  - User dashboard                           │
│  - Schedule creation                        │
│  - Real-time monitoring                     │
└──────────────┬──────────────────────────────┘
               │
┌──────────────▼──────────────────────────────┐
│     Smart Contract Layer                    │
│  ┌────────────────────────────────────────┐ │
│  │  DCAVault (ERC-4626)                   │ │
│  │  - Schedule management                 │ │
│  │  - USDC custody                        │ │
│  │  - Fee collection                      │ │
│  └────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────┐ │
│  │  DCAResolver (Gelato)                  │ │
│  │  - Execution triggers                  │ │
│  │  - Condition checking                  │ │
│  └────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────┐ │
│  │  SwapHelper (1inch)                    │ │
│  │  - Token swap routing                  │ │
│  │  - Price aggregation                   │ │
│  └────────────────────────────────────────┘ │
└──────────────┬──────────────────────────────┘
               │
┌──────────────▼──────────────────────────────┐
│     External Services                       │
│  - Gelato Network (automation)              │
│  - 1inch API (swaps)                        │
│  - Base RPC (blockchain)                    │
└─────────────────────────────────────────────┘
```

## Smart Contract Interactions

### DCA Schedule Lifecycle

```
User Flow:
1. User → Frontend: Create DCA schedule
2. Frontend → Vault: Approve & Call createSchedule
3. Vault: Accept USDC, emit ScheduleCreated
4. DCAResolver: Monitor schedule readiness (off-chain)
5. Gelato: Triggers executeSwap when ready
6. Vault → 1inch: Route swap
7. 1inch: Swap USDC for target token
8. Vault: Collect fee, update schedule
9. Frontend: Display execution result
```

### Data Models

#### Schedule Structure
```solidity
struct DCASchedule {
    address targetToken;           // Token to accumulate
    DCAFrequency frequency;        // Execution interval
    uint256 amountPerInterval;     // USDC per execution
    uint256 lastExecutionTime;     // Last swap timestamp
    uint256 totalAmount;           // Remaining USDC
    uint256 executedCount;         // Swap count
    bool active;                   // Active status
}
```

#### Frequency Enum
```solidity
enum DCAFrequency {
    DAILY,      // 1 day
    WEEKLY,     // 7 days
    BIWEEKLY,   // 14 days
    MONTHLY     // 30 days
}
```

## State Management

### Storage Layout

```
DCAVault Storage:
├── USDC (constant)
├── schedules (mapping: user → scheduleId → schedule)
├── scheduleCount (mapping: user → count)
├── activeSchedules (mapping: user → scheduleId[])
├── swapRouter (address)
├── feePercentage (uint256)
└── totalFeesCollected (uint256)
```

### Access Patterns

**User Schedule Access:**
```solidity
// Get all active schedules for a user
getActiveSchedules(address user) → uint256[]

// Get specific schedule details
getSchedule(address user, uint256 scheduleId) → DCASchedule
```

**Admin Access:**
```solidity
// Modify fee collection
setFeePercentage(uint256 newFee)
withdrawFees()

// Pause operations in emergency
pause() / unpause()

// Update swap router
setSwapRouter(address newRouter)
```

## Fee Structure

### Fee Collection

```
Fee Formula: amount × (feePercentage / FEE_PRECISION)

Examples (default 0.25% fee):
- 100 USDC swap → 0.25 USDC fee → 99.75 USDC swapped
- 1000 USDC swap → 2.5 USDC fee → 997.5 USDC swapped

Constants:
- FEE_PRECISION = 10000 (1 = 0.01%)
- DEFAULT_FEE = 25 (0.25%)
- MAX_FEE = 500 (5%)
```

### Revenue Model

- **Immediate**: 0.25% of each swap
- **Long-term**: Sustainable revenue without exit fee
- **Scaling**: Fixed fee maintains competitiveness as TVL grows
- **Distribution**: Treasury → development, marketing, partnerships

## Integration Points

### 1. Gelato Automation

**Task Creation:**
```typescript
// Frontend creates Gelato task
Gelato Task: {
  execAddress: DCAResolver address,
  execSelector: checker(user, scheduleId),
  resolverAddress: DCAResolver address,
  resolverData: encoded data
}
```

**Execution Flow:**
1. Gelato monitors DCAResolver.checker()
2. When true, calls encoded execution payload
3. DCAVault.executeSwap() executes atomically
4. Gelato pays gas, reimbursed via protocol

### 2. 1inch Swap Integration

**Swap Data Format:**
```solidity
// Encoded 1inch API response
swapData = {
  targetToken: AERO,
  amountIn: 100e6 USDC,
  minAmountOut: 95e18 AERO (slippage protection),
  routingData: [path through DEXes]
}
```

**Price Impact Protection:**
```solidity
// Minimum output validates execution quality
require(actualOut >= minAmountOut)
```

### 3. ERC-4626 Compliance

**Vault Interface:**
```solidity
// Standard share mechanics
function asset() → USDC
function totalAssets() → balanceOf(this)
function convertToShares(assets) → shares
function convertToAssets(shares) → assets
function deposit(assets, receiver) → shares
function withdraw(assets, receiver, owner) → shares
```

## Security Model

### Attack Vectors & Mitigations

| Risk | Mitigation |
|------|-----------|
| Reentrancy | `nonReentrant` on all external functions |
| Flash Loans | No external calls in critical logic |
| Price Oracle | Uses 1inch (aggregated pricing) |
| Front-running | Slippage protection via minAmountOut |
| Schedule Hijacking | User address checked in execution |
| Fund Loss | Pause mechanism for emergency |
| Fee Manipulation | Admin-only, capped at 5% |

### Access Control

```
Owner Only:
├── setFeePercentage()
├── setSwapRouter()
├── withdrawFees()
├── pause() / unpause()

User Only:
├── createSchedule()
├── cancelSchedule()

External (Gelato):
├── executeSwap()
```

## Gas Optimization

### Storage Packing

```solidity
// Before (inefficient)
struct Schedule {
    address token;      // 20 bytes
    uint256 amount;     // 32 bytes
    bool active;        // 1 byte
}
// Total: 3 slots

// After (optimized)
struct Schedule {
    address token;      // 20 bytes
    uint240 amount;     // 30 bytes (stores up to 2^240)
    bool active;        // 1 byte
}
// Total: 1 slot
```

### Function Optimization

- Batch operations for reducing read/write cycles
- View functions for off-chain queries
- Events for efficient indexing
- Minimal storage writes in critical paths

## Testing Strategy

### Test Coverage

```
DCAVault Tests:
├── Schedule Creation (valid, invalid inputs)
├── Schedule Execution (ready, not ready, depleted)
├── Schedule Cancellation
├── Fee Collection
├── Admin Functions
└── ERC-4626 Compliance

DCAResolver Tests:
├── Single schedule checking
├── Batch schedule checking
├── Gelato payload encoding
└── Edge cases

Integration Tests:
├── Full DCA cycle
├── Multiple users
├── Concurrent schedules
└── Stress testing
```

### Test Commands

```bash
# All tests
forge test

# With gas reporting
forge test --gas-report

# With coverage
forge coverage

# Specific test
forge test --match-test test_CreateSchedule -v
```

## Deployment Checklist

- [ ] Testnet deployment on Base Sepolia
- [ ] Mint mock tokens for testing
- [ ] Create Gelato tasks
- [ ] Configure 1inch aggregator
- [ ] Set admin addresses
- [ ] Enable pause functionality
- [ ] Run full test suite
- [ ] Formal security audit
- [ ] Mainnet deployment on Base
- [ ] Verify contract on Basescan
- [ ] Enable frontend integration
- [ ] Monitor for 24/48 hours

## Future Enhancements

### Phase 2
- Multi-token DCA (swap to multiple tokens per execution)
- Portfolio rebalancing
- Advanced analytics

### Phase 3
- Cross-chain DCA (Base → Arbitrum → Optimism)
- Institutional tools
- Payroll-to-crypto automation

### Phase 4
- RWA token integration
- AI-powered timing suggestions
- Community governance (DAO)

## Monitoring & Observability

### Events for Indexing

```solidity
ScheduleCreated(user, scheduleId, token, frequency, amount)
ScheduleExecuted(user, scheduleId, token, usdcAmount, tokenOut, fee)
ScheduleCancelled(user, scheduleId)
FeeCollected(amount)
SwapRouterUpdated(newRouter)
FeePercentageUpdated(newFee)
```

### Metrics to Track

- Active schedules per user
- Total TVL in vault
- Daily swap volume
- Average execution time
- Fee revenue
- User acquisition/churn

## References

- ERC-4626: https://eips.ethereum.org/EIPS/eip-4626
- Gelato Automation: https://docs.gelato.network/
- 1inch Aggregator: https://docs.1inch.io/
- OpenZeppelin Contracts: https://docs.openzeppelin.com/contracts/
- Base Documentation: https://docs.base.org/
