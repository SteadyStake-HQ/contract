# Contract Architecture Diagrams

Visual representation of SteadyStake smart contract architecture and interactions.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      STEADYSTAKE PROTOCOL                        │
└─────────────────────────────────────────────────────────────────┘

                    ┌──────────────────────────────┐
                    │    Frontend (Next.js)        │
                    │   - Dashboard                │
                    │   - Schedule Management      │
                    │   - User Wallet              │
                    └────────────┬─────────────────┘
                                 │
                    ┌────────────▼─────────────────┐
                    │      RainbowKit              │
                    │   + Wagmi Hooks              │
                    │   + Viem Contract Calls      │
                    └────────────┬─────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
   ┌────▼─────┐         ┌────────▼────────┐      ┌────────▼────────┐
   │   USDC   │         │   DCAVault      │      │  DCAResolver    │
   │  Token   │         │   (ERC-4626)    │      │   (Gelato)      │
   │          │         │                 │      │                 │
   │ Approve  │◄───────►│ - Schedules     │◄─────┤ - Checker       │
   │ Transfer │         │ - Fee Collection│      │ - Payloads      │
   └──────────┘         │ - Execution     │      │ - Batch Check   │
                        └────────┬────────┘      └────────┬────────┘
                                 │                        │
                       ┌─────────┴────────────────────────┤
                       │                                  │
                       │                    ┌─────────────▼──────┐
                       │                    │ Gelato Automation  │
                       │                    │                    │
                       │                    │ - Monitors checker │
                       │                    │ - Calls executeSwap│
                       │                    │ - Pays Gas Fee     │
                       │                    └────────────────────┘
                       │
            ┌──────────▼──────────┐
            │   SwapHelper        │
            │   (1inch Router)    │
            │                     │
            │ - Execute Swaps     │
            │ - Route to DEX      │
            │ - Price Aggregation │
            └─────────────────────┘
```

## DCA Vault Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        DCAVault                                   │
│                      (ERC-4626)                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  State Variables:                                                │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ • USDC (constant) ..................... Token for deposits  │ │
│  │ • swapRouter (address) ................ 1inch integration   │ │
│  │ • schedules (mapping) ................. User → ID → Schedule│ │
│  │ • activeSchedules (mapping) ........... User → Schedule IDs │ │
│  │ • feePercentage (uint256) ............ 0.25% default       │ │
│  │ • totalFeesCollected (uint256) ....... Accumulated fees    │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Core Functions:                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │ createSchedule(token, freq, amount, total)              │ │ │
│  │  │ ├─ Validate inputs                                       │ │ │
│  │  │ ├─ Transfer USDC from user                               │ │ │
│  │  │ ├─ Create schedule record                                │ │ │
│  │  │ ├─ Add to active schedules                               │ │ │
│  │  │ └─ Return scheduleId                                     │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │ executeSwap(user, scheduleId, swapData)                 │ │ │
│  │  │ ├─ Check schedule ready                                  │ │ │
│  │  │ ├─ Validate time interval                                │ │ │
│  │  │ ├─ Calculate fee and net amount                          │ │ │
│  │  │ ├─ Update schedule state                                 │ │ │
│  │  │ ├─ Execute swap via router                               │ │ │
│  │  │ ├─ Collect fee                                           │ │ │
│  │  │ └─ Emit event                                            │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │ cancelSchedule(scheduleId)                              │ │ │
│  │  │ ├─ Verify schedule active                                │ │ │
│  │  │ ├─ Mark schedule inactive                                │ │ │
│  │  │ ├─ Calculate refund amount                               │ │ │
│  │  │ ├─ Transfer USDC back to user                            │ │ │
│  │  │ └─ Emit cancellation event                               │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │ View Functions:                                          │ │ │
│  │  │ ├─ getActiveSchedules(user) → uint256[]                 │ │ │
│  │  │ ├─ getSchedule(user, id) → DCASchedule                  │ │ │
│  │  │ ├─ isScheduleReady(user, id) → bool                     │ │ │
│  │  │ └─ totalAssets() → uint256                              │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │ Admin Functions:                                         │ │ │
│  │  │ ├─ setFeePercentage(uint256) [onlyOwner]                │ │ │
│  │  │ ├─ withdrawFees() [onlyOwner]                           │ │ │
│  │  │ ├─ pause() / unpause() [onlyOwner]                      │ │ │
│  │  │ └─ setSwapRouter(address) [onlyOwner]                  │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  │                                                               │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Security Layers:                                                │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ ✓ Reentrancy Guards          [nonReentrant]                 │ │
│  │ ✓ Input Validation           [require statements]           │ │
│  │ ✓ Access Control             [onlyOwner, user checks]       │ │
│  │ ✓ Emergency Pause            [Pausable pattern]             │ │
│  │ ✓ Fee Capping                [MAX_FEE constant]             │ │
│  │ ✓ Safe Token Transfer        [ERC20 standard]               │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Schedule Lifecycle

```
                    ┌──────────────────────┐
                    │   User Initiates     │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Approve USDC        │
                    │ usdc.approve(dca)    │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │  Create Schedule             │
                    │  dca.createSchedule(...)     │
                    └──────────┬───────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
    ┌───▼────┐          ┌──────▼────────┐       ┌────▼──────┐
    │ Funds   │          │  Schedule     │       │   Gelato  │
    │ in      │          │  Created      │       │  Registers│
    │ Vault   │          │  Event        │       │  Task     │
    └───┬────┘          └───────────────┘       └────┬──────┘
        │                                             │
        ├──────────────────────────────────────────────┤
        │                                              │
        │              ┌──────────────────┐           │
        │              │    Monitoring    │           │
        │              │  Gelato Checks   │           │
        │              │ isScheduleReady()│           │
        │              └────────┬─────────┘           │
        │                       │                     │
        │              ┌────────▼──────────┐          │
        │              │ Interval Passed?  │          │
        │              │ Funds Available?  │          │
        │              └────────┬──────────┘          │
        │                       │                     │
        │              ┌────────▼──────────┐          │
        │              │ YES - Ready       │          │
        │              │ NO - Keep Waiting │          │
        │              └────┬───────┬──────┘          │
        │                   │       │                 │
        │            ┌──────▼┐   ┌──▼───────┐         │
        │            │Execute│   │ Continue │         │
        │            │Swap   │   │Wait      │         │
        │            └───┬───┘   └──┬───────┘         │
        │                │          │                 │
        │          ┌─────▼──────────▼────────┐       │
        │          │  [Loop - Next Interval] │       │
        │          └─────┬──────────────────┘        │
        │                │                           │
        │     ┌──────────▼──────────────┐            │
        │     │  Funds Depleted?        │            │
        │     │  Schedule Cancelled?    │            │
        │     └────────┬─────────┬──────┘            │
        │             │         │                    │
        │          NO │         │ YES                │
        │             │         │                    │
        │      ┌──────▼┐   ┌────▼─────────┐         │
        │      │Continue  │ Schedule      │         │
        │      │Monitoring│ Ends          │         │
        │      └──────┬───┘ Inactive      │         │
        │             │   └────┬──────────┘         │
        └─────────────┼─────────┤                    │
                      │         │                    │
                   ┌──▼─────────▼───┐               │
                   │  User Can:     │               │
                   │ • View History │               │
                   │ • Cancel Anytime               │
                   │ • Create New   │               │
                   └────────────────┘               │
```

## Execution Flow - Deep Dive

```
Step 1: Schedule Execute
─────────────────────────────────────────────────

User Schedule State:
┌─────────────────────────────────┐
│ targetToken: 0xAERO             │
│ frequency: WEEKLY (7 days)      │
│ amountPerInterval: 100 USDC     │
│ lastExecutionTime: 1704067200   │
│ totalAmount: 900 USDC (900 left)│
│ executedCount: 1                │
│ active: true                    │
└─────────────────────────────────┘
                │
                ▼
Step 2: Time Check
─────────────────────────────────────────────────

Current Time: 1704672000
Last Execution: 1704067200
Interval Required: 604800 (7 days)
Time Elapsed: 604800

✓ Current Time - Last Execution ≥ Interval
✓ Schedule is READY


Step 3: Calculate Amounts
─────────────────────────────────────────────────

Amount to Swap: min(100 USDC, 900 USDC) = 100 USDC
Fee Percentage: 0.25% (25/10000)
Fee Amount: 100 × 25 / 10000 = 0.25 USDC
Net Swap Amount: 100 - 0.25 = 99.75 USDC


Step 4: State Update
─────────────────────────────────────────────────

Schedule After Execution:
┌─────────────────────────────────┐
│ targetToken: 0xAERO             │
│ frequency: WEEKLY               │
│ amountPerInterval: 100 USDC     │
│ lastExecutionTime: 1704672000  │◄── Updated
│ totalAmount: 800 USDC (900-100) │◄── Updated
│ executedCount: 2                │◄── Incremented
│ active: true                    │
└─────────────────────────────────┘


Step 5: Execute Swap
─────────────────────────────────────────────────

DCAVault sends to 1inch Router:
  Amount: 99.75 USDC
  Output: 0xAERO token
  Min Output: [Slippage protected]

1inch Router:
  ├─ Routes through DEXes
  ├─ Gets best price
  ├─ Executes swap atomically
  └─ Sends AERO back to user


Step 6: Fee Collection
─────────────────────────────────────────────────

totalFeesCollected += 0.25 USDC


Step 7: Emit Events & Return
─────────────────────────────────────────────────

ScheduleExecuted Event:
{
  user: 0xUserAddress
  scheduleId: 0
  targetToken: 0xAERO
  usdcAmount: 99.75
  tokenOut: 95000000000000000000  (95 AERO)
  fee: 0.25
}
```

## State Transitions

```
Schedule State Machine:

                    ┌─────────────────────┐
                    │     CREATED         │
                    │  (Just initialized) │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │    WAITING FOR      │
                    │    INTERVAL         │
                    │  (Monitoring phase) │
                    └──────┬────────┬─────┘
                           │        │
                    ┌──────▼┐  ┌───▼──────┐
                    │READY  │  │CANCELLED │
                    └──┬───┘  └──────────┘
                       │
                ┌──────▼──────────┐
                │  EXECUTING      │
                │  (Swap running) │
                └──────┬──────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
    ┌───▼────┐   ┌─────▼─────┐  ┌────▼─────┐
    │SUCCESS │   │  DEPLETED │  │ REACTIVATE
    │        │   │  (0 USDC) │  │           │
    └───┬────┘   └─────┬─────┘  └────┬─────┘
        │              │              │
        │              ▼              │
        │         INACTIVE           │
        │                            │
        │      Back to WAITING       │
        └────────────┬───────────────┘
                     │
                     ▼
                [Continue Loop]
```

## Data Flow Diagram

```
USER INTERACTION
       │
       ▼
    ┌──────────────────┐
    │  Next.js Frontend│
    │  (React Hooks)   │
    └────┬─────────────┘
         │
         │ wagmi / viem
         ▼
    ┌──────────────────────┐
    │  RainbowKit Wallet   │
    │  (Connection Layer)  │
    └────┬─────────────────┘
         │
         | JSON-RPC
         ▼
    ┌────────────────────────────┐
    │  Base Blockchain Network   │
    │                            │
    │ ┌──────────────────────┐   │
    │ │  USDC Contract       │   │
    │ │  - approve USDC      │   │
    │ │  - transfer USDC     │   │
    │ └──────────────────────┘   │
    │                            │
    │ ┌──────────────────────┐   │
    │ │  DCAVault Contract   │   │
    │ │  - createSchedule    │   │
    │ │  - executeSwap       │   │
    │ │  - cancelSchedule    │   │
    │ └──────────────────────┘   │
    │                            │
    │ ┌──────────────────────┐   │
    │ │  1inch Router        │   │
    │ │  - Execute Swaps     │   │
    │ │  - Route to DEX      │   │
    │ └──────────────────────┘   │
    │                            │
    │ ┌──────────────────────┐   │
    │ │  Target Tokens       │   │
    │ │  (AERO, DEGEN, etc)  │   │
    │ └──────────────────────┘   │
    └────┬───────────────────────┘
         │
         | Events + State
         ▼
┌─────────────────────────────────┐
│  The Graph (Indexing)          │
│  - Track all events            │
│  - Build user dashboards       │
└─────────────────────────────────┘


AUTOMATION LAYER
       │
       ▼
   ┌───────────────┐
   │ Gelato Network│
   │               │
   │ ┌────────────┐│
   │ │DCAResolver ││
   │ │- checker() ││
   │ └────────────┘│
   └───┬───────────┘
       │
       │ Monitors every block
       ▼
   Execute when ready
       │
       ▼
   DCAVault.executeSwap()
```

## Dependencies & Integrations

```
OpenZeppelin Contracts
├── ERC4626 (Vault)
├── ERC20 (Token Standard)
├── ReentrancyGuard
├── Ownable
└── Pausable

Gelato Network
├── Gelato OPS
├── DCAResolver Interface
└── Task Creation

1inch Aggregator Router
├── Best Price Routing
├── Multi-DEX Swaps
└── Atomic Execution

Base Network
├── Native USDC
├── Low Gas Fees
├── EVM Compatibility
└── Sequencer Infrastructure
```

## File Dependencies

```
DCAVault.sol
├── openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol
├── openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol
├── openzeppelin/contracts/security/ReentrancyGuard.sol
├── openzeppelin/contracts/access/Ownable.sol
└── openzeppelin/contracts/security/Pausable.sol

DCAResolver.sol
└── DCAVault.sol (interface)

SwapHelper.sol
└── openzeppelin/contracts/token/ERC20/ERC20.sol

MockTokens.sol
├── openzeppelin/contracts/token/ERC20/ERC20.sol
└── openzeppelin/contracts/access/Ownable.sol

Constants.sol
└── (No external dependencies)
```
