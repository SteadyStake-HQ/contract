# Quick Start Guide

Get up and running with SteadyStake smart contracts in minutes.

## Prerequisites

- Git
- Node.js 16+ (optional, for Foundry)
- Foundry ([Install](https://book.getfoundry.sh/getting-started/installation))

## Installation

### 1. Clone Repository

```bash
git clone https://github.com/steadystake/contracts.git
cd contracts
```

### 2. Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 3. Verify Installation

```bash
forge --version
# Expected: forge 0.2.x
```

## Setting Up Your Environment

### 1. Create Environment File

```bash
cp .env.example .env.local
```

### 2. Configure Private Key

Add your private key to `.env.local`:

```env
PRIVATE_KEY=0x0000...your_actual_key...0000
```

**⚠️ Never commit `.env.local` or keys to version control!**

### 3. Verify Setup

```bash
make install
```

## Build & Test

### Build Contracts

```bash
forge build
```

Expected output:
```
[⠒] Compiling...
[⠘] Compiling 10 files with 0.8.19
[⠚] Solc 0.8.19 finished in 2.35s
Compiler run successful
```

### Run Tests

```bash
forge test
```

Expected output:
```
[⠘] Compiling...
Compiling 6 files with 0.8.19
Solc 0.8.19 finished in 1.47s
Compiler run successful

Ran 15 tests in 0.31s:
Test Results: 15 passed, 0 failed
```

### Generate Coverage

```bash
forge coverage
```

## Deployment

### Testnet (Base Sepolia)

```bash
export PRIVATE_KEY=0x...
make deploy-testnet
```

Expected output:
```
Deploying to Base Sepolia...
📝 Simulating transaction...
✓ Simulation successful
🔗 Broadcasting transaction...
✓ Transaction confirmed
📊 Contracts deployed:
  - DCAVault: 0x123...
  - DCAResolver: 0x456...
```

### Mainnet (Base)

```bash
export PRIVATE_KEY=0x...
make deploy-mainnet
```

## Next Steps

1. **Read Documentation**
   - See [README.md](README.md) for full overview
   - See [ARCHITECTURE.md](ARCHITECTURE.md) for design details

2. **Frontend Integration**
   - See [FRONTEND_INTEGRATION.md](FRONTEND_INTEGRATION.md)
   - Set up React hooks and components

3. **Write Custom Tests**
   - Create tests in `test/` directory
   - Follow existing patterns

## Common Commands

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts |
| `forge test` | Run all tests |
| `forge test -v` | Run tests with verbose output |
| `forge test --match-test test_Name` | Run specific test |
| `forge coverage` | Generate coverage report |
| `forge fmt` | Format code |
| `forge snapshot` | Save gas snapshots |

## Development Workflow

### 1. Create New Contract

```bash
# Create in src/MyContract.sol
cat > src/MyContract.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MyContract {
    // Implementation
}
EOF
```

### 2. Create Tests

```bash
# Create in test/MyContract.t.sol
cat > test/MyContract.t.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/src/Test.sol";
import {MyContract} from "../src/MyContract.sol";

contract MyContractTest is Test {
    MyContract public contract_;
    
    function setUp() public {
        contract_ = new MyContract();
    }
    
    function test_Example() public {
        // Your test here
    }
}
EOF
```

### 3. Test & Iterate

```bash
# Test your changes
forge test --match-contract MyContractTest -v

# Format
forge fmt

# Deploy
make deploy-testnet
```

## Troubleshooting

### Compilation Errors

**Problem:** `Compiler error`

```bash
# Update compiler
foundryup

# Clean and rebuild
make clean
forge build
```

### Test Failures

**Problem:** `Test failed`

```bash
# Run with verbose output
forge test -v

# Check specific test
forge test --match-test test_FailingTest -vv
```

### Deployment Issues

**Problem:** `Transaction reverted`

1. Check gas limit: `forge estimate-gas`
2. Verify private key in `.env.local`
3. Check chain ID in `foundry.toml`
4. Ensure account has funds

## Security Best Practices

✅ Do:
- Use `nonReentrant` guards
- Validate inputs
- Use safe math (OpenZeppelin)
- Test edge cases
- Document assumptions

❌ Don't:
- Store secrets in code
- Use unsafe patterns
- Skip testing
- Deploy without audit
- Ignore warnings

## Resources

- **Foundry Docs:** https://book.getfoundry.sh/
- **Solidity Docs:** https://docs.soliditylang.org/
- **OpenZeppelin:** https://docs.openzeppelin.com/contracts/
- **Base Docs:** https://docs.base.org/
- **Ethereum Dev:** https://ethereum.org/developers

## Support

- **Docs:** See README.md and ARCHITECTURE.md
- **Issues:** Create a GitHub issue
- **Discord:** Join our community
- **Email:** dev@steadystake.com

## Next Chapter

Ready to deploy? → See [ARCHITECTURE.md](ARCHITECTURE.md) for deployment checklist.

Happy coding! 🚀
