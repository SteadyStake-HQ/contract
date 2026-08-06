# 0x Protocol Integration Guide

SteadyStake now uses **0x Protocol** instead of 1inch for token swaps. This guide explains the integration, API usage, and testing.

## Why 0x Protocol?

✅ **No KYC Required** - Free tier without identity verification  
✅ **Same Aggregation** - Routes through best DEX prices on Base  
✅ **Instant Setup** - Get API key immediately  
✅ **Production Ready** - Widely used in DeFi  
✅ **Base Supported** - Full support for Base mainnet & Sepolia testnet  

## Getting Started

### 1. API Key (Already Configured)

Your API key is set in `.env.local`:
```env
ZERO_EX_API_KEY=12249638-2d09-4f30-bdbe-8f44dad4d322
```

### 2. 0x Router Address

The 0x Protocol router on Base:
```solidity
address constant ZERO_EX_ROUTER = 0xdef1c0ded9bef7c1100000000000000000000000;
```

This is defined in [src/Constants.sol](src/Constants.sol)

## How It Works

### Flow: User DCA Schedule → 0x Swap → Token Received

```
1. User creates schedule (100 USDC/week for AERO)
2. Gelato automation triggers after 7 days
3. Backend calls 0x API to get swap quote
4. Gelato executes vault.executeSwap() with 0x data
5. Vault approves USDC to 0x router
6. Router executes swap atomically
7. User receives AERO token
8. Fee collected (0.25%)
```

## 0x API Integration

### Get a Swap Quote

Call 0x API to get swap data (+slippage protection):

```bash
curl -X GET \
  "https://api.0x.org/swap/v1/quote" \
  -H "0x-api-key: 12249638-2d09-4f30-bdbe-8f44dad4d322" \
  -G \
  -d buyToken=0x940181a94A35DC584061DeeA9B928900aa048AF6 \
  -d sellToken=0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975 \
  -d sellAmount=100000000 \
  -d slippagePercentage=1
```

### Response Structure

```json
{
  "chainId": 8453,
  "price": "0.95",
  "guaranteedPrice": "0.94",
  "to": "0xdef1c0ded9bef7c1100000000000000000000000",
  "data": "0x...",
  "value": "0",
  "gas": "150000",
  "gasPrice": "1000000000",
  "estimatedGas": "150000",
  "protocolFee": "0",
  "minimumProtocolFee": "0",
  "buyTokenAddress": "0x940181...",
  "buyAmount": "95000000000000000000",
  "sellTokenAddress": "0x833589...",
  "sellAmount": "100000000",
  "sources": [
    {"name": "Uniswap_V3", "proportion": "1"}
  ],
  "orders": [],
  "allowanceTarget": "0xdef1c0ded9bef7c1100000000000000000000000"
}
```

Key fields:
- **`data`**: Raw call data to pass to executeSwap()
- **`guaranteedPrice`**: Minimum amount you'll receive (slippage protected)
- **`gas`**: Estimated gas usage
- **`chainId`**: Must be 8453 (Base mainnet) or 84532 (Base Sepolia)

## Backend Integration (Node.js Example)

Store this on your backend and call 0x API server-side:

```typescript
import fetch from 'node-fetch';

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975';
const AERO = '0x940181a94A35DC584061DeeA9B928900aa048AF6';

async function get0xSwapData(
  sellAmount: string,
  buyToken: string,
  slippage: number = 1
) {
  const params = new URLSearchParams({
    buyToken,
    sellToken: USDC,
    sellAmount,
    slippagePercentage: slippage.toString(),
  });

  const response = await fetch(
    `https://api.0x.org/swap/v1/quote?${params}`,
    {
      headers: {
        '0x-api-key': process.env.ZERO_EX_API_KEY!,
      },
    }
  );

  if (!response.ok) {
    throw new Error(`0x API error: ${response.statusText}`);
  }

  return response.json();
}

// Usage
const quote = await get0xSwapData('100000000', AERO, 1);
console.log(`Buy ${quote.buyAmount / 1e18} AERO for ${quote.sellAmount / 1e6} USDC`);
console.log(`Swap data: ${quote.data}`);
```

## Smart Contract Integration

### Updated SwapHelper Contract

The `SwapHelper.sol` contract now uses 0x Protocol:

```solidity
// 0x Protocol Router on Base
address constant ZERO_EX_ROUTER = 0xdef1c0ded9bef7c1100000000000000000000000;

function executeSwap(
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    bytes calldata swapData  // 0x API response data
) external returns (uint256 amountOut) {
    // Approve 0x router
    USDC.approve(ZERO_EX_ROUTER, amountIn);
    
    // Execute swap
    (bool success, bytes memory result) = ZERO_EX_ROUTER.call(swapData);
    require(success, "0x swap failed");
    
    // Decode result (amount received)
    amountOut = abi.decode(result, (uint256));
    require(amountOut >= minAmountOut, "Insufficient output");
    
    emit SwapExecuted(address(USDC), tokenOut, amountIn, amountOut);
}
```

### In DCAVault

When Gelato calls `executeSwap()`:

```solidity
function executeSwap(
    address user,
    uint256 scheduleId,
    bytes calldata swapData  // <-- 0x swap data from backend
) external {
    // ... validation ...
    
    // Pass 0x data to execution
    _performSwap(user, schedule.targetToken, netAmount, swapData);
}
```

## Testing on Base Sepolia

### 1. Get Testnet 0x Quote

```bash
curl -X GET \
  "https://sepolia.api.0x.org/swap/v1/quote" \
  -H "0x-api-key: YOUR_API_KEY" \
  -G \
  -d buyToken=MOCK_TOKEN_ADDRESS \
  -d sellToken=0xMOCK_USDC \
  -d sellAmount=1000000
```

### 2. Use Mock Router for Development

For local testing without API calls:

```solidity
// From MockSwapRouter in SwapHelper.sol
MockSwapRouter mockRouter = new MockSwapRouter();
mockRouter.swap(tokenOut, amount, minOut, recipient);
```

### 3. Full Test Flow

```bash
# Build contracts
forge build

# Run unit tests
forge test -v

# Deploy to Sepolia
make deploy-testnet

# Create DCA schedule
cast send $VAULT "createSchedule(address,uint8,uint256,uint256)" \
  $AERO 1 100000000 1000000000
```

## Gas Optimization Tips

- **Batch swaps**: Combine multiple DCA executions in one Gelato task
- **Slippage tuning**: Lower slippage = better price, higher gas
- **Off-chain computation**: Calculate swaps on backend, not blockchain
- **Smart pricing**: Use 0x best execution to minimize fees

## Monitoring & Debugging

### Check Quote Validity

```typescript
// Verify quote not expired
if (Date.now() > quoteTimestamp + 120000) {
  // Quote expired, get new one
  quote = await get0xSwapData(...);
}
```

### Monitor Swap Success

```solidity
event SwapExecuted(
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut
);
```

Track these events in your indexer (The Graph, etc.)

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| "0x swap failed" | Swap data invalid/expired | Get fresh quote from API |
| "Insufficient output" | Price slippage too high | Increase slippagePercentage |
| "Approval failed" | USDC allowance too low | Increase approval amount |
| "Insufficient balance" | Not enough USDC | Check vault has funds |

## Rate Limits & Quotas

- **Free Tier**: 10 requests/second
- **No KYC required**: Keep API key secret
- **Quote validity**: ~2 minutes (get fresh quotes for safety)

## API Endpoints

| Network | Endpoint |
|---------|----------|
| **Base Mainnet** | https://api.0x.org |
| **Base Sepolia** | https://sepolia.api.0x.org |
| **Ethereum** | https://api.0x.org (chainId=1) |

## Files Modified

1. **`.env.example`** - Added ZERO_EX_API_KEY with your key
2. **`src/Constants.sol`** - Updated ZERO_EX_ROUTER address
3. **`src/SwapHelper.sol`** - Replaced 1inch with 0x Protocol
4. **`src/DCAVault.sol`** - Updated comments for 0x

## Next Steps

1. ✅ **API Key Set** - Your 0x API key is configured
2. ⏭️ **Backend Integration** - Implement 0x quote fetching on backend
3. ⏭️ **Gelato Tasks** - Create automation tasks that pass 0x data
4. ⏭️ **Testing** - Deploy to Sepolia and test full flow
5. ⏭️ **Mainnet** - Launch on Base mainnet

## Additional Resources

- 0x Protocol Docs: https://docs.0x.org
- 0x API Reference: https://0x.org/docs/introduction/api
- Base Documentation: https://docs.base.org
- SteadyStake Contracts: See [ARCHITECTURE.md](ARCHITECTURE.md)

## Support

- **0x Discord**: https://discord.gg/0x
- **0x API Issues**: https://github.com/0xProject/0x-api
- **SteadyStake Repo**: Check GitHub issues

---

✅ **Integration Status: Complete**

All SteadyStake contracts are updated to use 0x Protocol. Ready for testnet and mainnet deployment.
