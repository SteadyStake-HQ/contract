# SteadyStake Smart Contracts

A comprehensive smart contract suite for automated dollar-cost averaging (DCA) on Base Network.

## Overview

SteadyStake enables users to set up automated recurring purchases of any token using USDC on Base Network. The contracts handle:

- **ERC-4626 Vault**: Manages USDC deposits and schedule tracking
- **DCA Scheduling**: Create daily, weekly, or monthly swap schedules
- **Gelato Automation**: Automated execution of scheduled swaps
- **1inch Integration**: Route swaps through 1inch aggregator for best prices

## Project Structure

```
contracts/
├── src/
│   ├── DCAVault.sol          # Main ERC-4626 vault contract
│   ├── DCAResolver.sol       # Gelato automation resolver
│   ├── SwapHelper.sol        # 1inch swap integration
│   └── MockTokens.sol        # Test token implementations
├── test/
│   ├── DCAVault.t.sol        # Vault unit tests
│   └── DCAResolver.t.sol     # Resolver unit tests
├── script/
│   └── Deploy.s.sol          # Deployment scripts
├── foundry.toml              # Foundry configuration
└── package.json              # NPM dependencies
```

## Key Contracts

### DCAVault (ERC-4626)

The main contract managing DCA operations.

**Key Features:**
- ERC-4626 compliant vault for standardized share/asset mechanics
- User-specific DCA schedules with flexible frequencies
- Automatic fee collection (default 0.25%)
- Admin controls for pause/unpause
- Reentrancy protection

**Main Functions:**
```solidity
function createSchedule(
    address targetToken,
    DCAFrequency frequency,
    uint256 amountPerInterval,
    uint256 totalAmount
) external returns (uint256 scheduleId)

function executeSwap(
    address user,
    uint256 scheduleId,
    bytes calldata swapData
) external

function cancelSchedule(uint256 scheduleId) external

function getActiveSchedules(address user) external view returns (uint256[])

function isScheduleReady(address user, uint256 scheduleId) external view returns (bool)
```

### DCAResolver

Gelato-compatible automation resolver for checking and executing DCA swaps.

**Key Features:**
- Gelato checker function for determining execution readiness
- Batch checking for multiple schedules
- Encode execution data for Gelato

**Main Functions:**
```solidity
function checker(
    address user,
    uint256 scheduleId
) external view returns (bool canExec, bytes memory execPayload)

function batchChecker(
    address user,
    uint256[] calldata scheduleIds
) external view returns (uint256[] memory executables, bytes[] memory execPayloads)
```

### SwapHelper

Abstraction for 1inch swap integration and mock swap router for testing.

**Features:**
- IOneInchAggregator interface for mainnet integration
- MockSwapRouter for testing (1:1 swaps)
- Swap data encoding/decoding utilities

## Usage Flow

### 1. Create a Schedule

```solidity
// User approves USDC to vault
usdc.approve(address(vault), amount);

// Create daily schedule
vault.createSchedule(
    tokenAddress,      // AERO, DEGEN, etc.
    DCAFrequency.DAILY,
    100e6,              // 100 USDC per day
    1000e6              // 1000 USDC total
);
```

### 2. Automated Execution (via Gelato)

```solidity
// Gelato monitoring checks readiness
(bool canExec, bytes memory execPayload) = resolver.checker(user, scheduleId);

// When ready, Gelato calls executeSwap
vault.executeSwap(user, scheduleId, swapData);

// User receives target token and pays 0.25% fee
```

### 3. Cancel Anytime

```solidity
vault.cancelSchedule(scheduleId);
// Remaining USDC returned to user
```

## Testing

### Run All Tests
```bash
forge test
```

### Run Specific Test
```bash
forge test --match-contract DCAVaultTest
```

### Generate Coverage Report
```bash
forge coverage
```

### Gas Snapshot
```bash
forge snapshot
```

## Deployment

### Testnet (Base Sepolia)

```bash
export PRIVATE_KEY=your_private_key
export BASE_ETHERSCAN_KEY=your_etherscan_key

forge script script/Deploy.s.sol:DeployTestnet \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

### Mainnet (Base)

```bash
forge script script/Deploy.s.sol:DeployMainnet \
  --rpc-url base \
  --broadcast \
  --verify
```

### Mainnet (Kava, chain 2222)

Kava EVM uses USDC at `0xfA9343C3897324496A05fC75abeD6bAC29f8A40f`. Use legacy transactions if the RPC returns invalid EIP-1559 fee data:

```bash
export PRIVATE_KEY=your_private_key
# Optional for verification (Kavascan / Cosmostation API)
export KAVASCAN_API_KEY=any_non_empty_string

forge script script/Deploy.s.sol:DeployKava \
  --rpc-url kava \
  --broadcast \
  --legacy
```

After deployment, update `frontend/config/deployed-addresses.json` with the logged DCAVault, DCAResolver, and ZeroExAdapter addresses. Verify contracts on [Kavascan](https://kavascan.com) via the Contract tab (flattened source or standard-json-input); see [Kava contract verification](https://docs.kava.io/docs/ethereum/contract_verification).

### Mainnet (Polygon, chain 137)

Polygon uses Circle USDC at `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` and 0x Exchange Proxy at `0xDef1C0ded9bec7F1a1670819833240f027b25EfF`. Ensure the deployer has enough MATIC for gas (~8+ POL recommended).

```bash
export PRIVATE_KEY=your_private_key
export POLYGONSCAN_API_KEY=your_polygonscan_api_key   # for --verify

forge script script/Deploy.s.sol:DeployPolygon \
  --rpc-url polygon \
  --broadcast \
  --verify
```

If deployment succeeds, contracts are verified on [Polygonscan](https://polygonscan.com). If you use a different deployer key, update `frontend/config/deployed-addresses.json` with the new DCAVault, DCAResolver, and ZeroExAdapter addresses.

### Qubic testnet (faucet & test funds)

SteadyStake Solidity contracts deploy to **Base / Base Sepolia** (EVM). For **Qubic testnet** (separate chain) test funds and RPC:

- **Faucet:** Join [Qubic Discord](https://discord.qubic.org) → **#bot-commands** → use the faucet command (test Qubics for testnet).
- **RPC:** `https://testnet-rpc.qubic.org` (stored in `foundry.toml` as `qubic_testnet`).
- **Pre-funded seeds** and full steps: see **[QUBIC_TESTNET.md](QUBIC_TESTNET.md)** and [Qubic Testnet Resources](https://docs.qubic.org/developers/testnet-resources).

```bash
npm run qubic-testnet   # prints reminder to read QUBIC_TESTNET.md
```

## Configuration

### foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
test = "test"

[rpc_endpoints]
base = "https://mainnet.base.org"
base_sepolia = "https://sepolia.base.org"
qubic_testnet = "https://testnet-rpc.qubic.org"   # Qubic testnet (see QUBIC_TESTNET.md)
```

## Contract Addresses

### Base Mainnet
- **USDC**: `0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975`
- **1inch Router**: `0x111111125421cA6dc452d289314280a0f8842A65`
- **DCAVault**: [Deploy to get address]
- **DCAResolver**: [Deploy to get address]

### Base Sepolia (Testnet)
- Mock USDC and tokens deployed during deployment
- See deployment output for addresses

## Key Constants

- **FEE_PRECISION**: 10000 (1 = 0.01%)
- **DEFAULT_FEE**: 25 (0.25%)
- **MAX_FEE**: 500 (5%)
- **MAX_DEPOSIT**: 10,000,000 USDC

## DCA Frequencies

- `DAILY`: 1 day interval
- `WEEKLY`: 7 days interval
- `BIWEEKLY`: 14 days interval
- `MONTHLY`: 30 days interval

## Security Considerations

1. **Reentrancy Protection**: All external functions use `nonReentrant`
2. **Pausable**: Admin can pause contract in emergency
3. **Access Control**: Only owner can modify fees and pause/unpause
4. **Safe Transfers**: Uses OpenZeppelin's ERC20 implementation
5. **Fee Limits**: Maximum fee capped at 5%

## Audit Recommendations

Before mainnet deployment:

1. [ ] Formal security audit (e.g., Cyfrin, Code4rena)
2. [ ] Natspec documentation completion
3. [ ] Event indexing verification
4. [ ] Gas optimization review
5. [ ] Integration testing with real 1inch API
6. [ ] Mainnet fork testing

## Integration with Frontend

The frontend communicates with these contracts:

```typescript
// Create schedule
await vault.createSchedule(
  tokenAddress,
  frequencyEnum,
  amountPerInterval,
  totalAmount
);

// Get active schedules
const schedules = await vault.getActiveSchedules(userAddress);

// Get schedule details
const schedule = await vault.getSchedule(userAddress, scheduleId);

// Check if ready to execute
const ready = await vault.isScheduleReady(userAddress, scheduleId);

// Cancel schedule
await vault.cancelSchedule(scheduleId);
```

## Development

### Set up for Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone repo
git clone <repo>
cd contracts

# Run tests
forge test -v
```

### Code Style

- Use Solidity ^0.8.19
- Follow OpenZeppelin naming conventions
- Include comprehensive NatSpec documentation
- Add event emissions for all state changes

## License

MIT

## Contact

For questions or integration support, contact the SteadyStake team.
