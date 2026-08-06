# SteadyStake Contracts - Frontend Integration Guide

## Overview

This guide explains how to integrate the SteadyStake smart contracts with the Next.js frontend application.

## Contract Addresses

Update these in your frontend environment configuration:

```typescript
// config/contracts.ts
export const CONTRACTS = {
  USDC: "0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975",
  DCAVault: "0x...", // Deploy and update
  DCAResolver: "0x...", // Deploy and update
};

export const CHAIN_ID = 8453; // Base mainnet
export const CHAIN_ID_SEPOLIA = 84532; // Base Sepolia testnet
```

## ABI Integration

### 1. DCAVault ABI

```typescript
// lib/abis/DCAVault.ts
export const DCA_VAULT_ABI = [
  // Schedule creation
  {
    name: "createSchedule",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "targetToken", type: "address" },
      { name: "frequency", type: "uint8" }, // 0=DAILY, 1=WEEKLY, 2=BIWEEKLY, 3=MONTHLY
      { name: "amountPerInterval", type: "uint256" },
      { name: "totalAmount", type: "uint256" },
    ],
    outputs: [{ name: "scheduleId", type: "uint256" }],
  },
  // Schedule cancellation
  {
    name: "cancelSchedule",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "scheduleId", type: "uint256" }],
  },
  // View functions
  {
    name: "getActiveSchedules",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256[]" }],
  },
  {
    name: "getSchedule",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "user", type: "address" },
      { name: "scheduleId", type: "uint256" },
    ],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "targetToken", type: "address" },
          { name: "frequency", type: "uint8" },
          { name: "amountPerInterval", type: "uint256" },
          { name: "lastExecutionTime", type: "uint256" },
          { name: "totalAmount", type: "uint256" },
          { name: "executedCount", type: "uint256" },
          { name: "active", type: "bool" },
        ],
      },
    ],
  },
  // Fee management
  {
    name: "feePercentage",
    type: "function",
    stateMutability: "view",
    outputs: [{ name: "", type: "uint256" }],
  },
];
```

## React Hooks Integration

### 1. Create Schedule Hook

```typescript
// hooks/useDCASchedule.ts
import { useContractWrite, usePrepareContractWrite } from "wagmi";
import { DCA_VAULT_ABI } from "@/lib/abis/DCAVault";

export function useCreateSchedule() {
  const { config } = usePrepareContractWrite({
    address: process.env.NEXT_PUBLIC_DCA_VAULT,
    abi: DCA_VAULT_ABI,
    functionName: "createSchedule",
  });

  const { write, isLoading, isSuccess, data } = useContractWrite(config);

  return {
    createSchedule: (
      targetToken: string,
      frequency: number,
      amountPerInterval: string,
      totalAmount: string
    ) => {
      write?.({
        args: [targetToken, frequency, BigInt(amountPerInterval), BigInt(totalAmount)],
      });
    },
    isLoading,
    isSuccess,
    transactionHash: data?.hash,
  };
}
```

### 2. Read Schedule Hook

```typescript
// hooks/useSchedules.ts
import { useContractRead } from "wagmi";
import { DCA_VAULT_ABI } from "@/lib/abis/DCAVault";

export function useActiveSchedules(userAddress?: string) {
  const { data, isLoading, error } = useContractRead({
    address: process.env.NEXT_PUBLIC_DCA_VAULT,
    abi: DCA_VAULT_ABI,
    functionName: "getActiveSchedules",
    args: [userAddress],
    enabled: !!userAddress,
  });

  return {
    schedules: (data as bigint[]) || [],
    isLoading,
    error,
  };
}

export function useScheduleDetail(userAddress: string, scheduleId: bigint) {
  const { data, isLoading } = useContractRead({
    address: process.env.NEXT_PUBLIC_DCA_VAULT,
    abi: DCA_VAULT_ABI,
    functionName: "getSchedule",
    args: [userAddress, scheduleId],
    enabled: !!userAddress,
  });

  return {
    schedule: data,
    isLoading,
  };
}
```

### 3. Approval Hook

```typescript
// hooks/useUSDCApproval.ts
import { useContractWrite, usePrepareContractWrite } from "wagmi";
import { ERC20_ABI } from "@/lib/abis/ERC20";

export function useApproveUSDC(amount: string) {
  const { config } = usePrepareContractWrite({
    address: process.env.NEXT_PUBLIC_USDC,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [process.env.NEXT_PUBLIC_DCA_VAULT, BigInt(amount)],
  });

  const { write, isLoading } = useContractWrite(config);

  return { approveUSDC: write, isLoading };
}
```

## Component Integration

### 1. Create Schedule Component

```typescript
// app/components/dashboard/NewDcaModal.tsx
import { useState } from "react";
import { useAccount } from "wagmi";
import { useCreateSchedule } from "@/hooks/useDCASchedule";
import { useApproveUSDC } from "@/hooks/useUSDCApproval";
import { parseUnits } from "ethers";

enum DCAFrequency {
  DAILY = 0,
  WEEKLY = 1,
  BIWEEKLY = 2,
  MONTHLY = 3,
}

export function NewDcaModal() {
  const { address } = useAccount();
  const [targetToken, setTargetToken] = useState("");
  const [frequency, setFrequency] = useState<DCAFrequency>(DCAFrequency.DAILY);
  const [amountPerInterval, setAmountPerInterval] = useState("");
  const [totalAmount, setTotalAmount] = useState("");

  const { createSchedule, isLoading } = useCreateSchedule();
  const { approveUSDC, isLoading: isApproving } = useApproveUSDC(totalAmount);

  const handleCreate = async () => {
    // First approve USDC
    await approveUSDC?.({
      args: [
        process.env.NEXT_PUBLIC_DCA_VAULT,
        BigInt(parseUnits(totalAmount, 6)),
      ],
    });

    // Then create schedule
    createSchedule(
      targetToken,
      frequency,
      parseUnits(amountPerInterval, 6).toString(),
      parseUnits(totalAmount, 6).toString()
    );
  };

  return (
    <div className="space-y-4">
      <div>
        <label>Target Token</label>
        <input
          type="text"
          value={targetToken}
          onChange={(e) => setTargetToken(e.target.value)}
          placeholder="Token address"
        />
      </div>

      <div>
        <label>Frequency</label>
        <select
          value={frequency}
          onChange={(e) => setFrequency(Number(e.target.value) as DCAFrequency)}
        >
          <option value={DCAFrequency.DAILY}>Daily</option>
          <option value={DCAFrequency.WEEKLY}>Weekly</option>
          <option value={DCAFrequency.BIWEEKLY}>Biweekly</option>
          <option value={DCAFrequency.MONTHLY}>Monthly</option>
        </select>
      </div>

      <div>
        <label>Amount per Interval (USDC)</label>
        <input
          type="number"
          value={amountPerInterval}
          onChange={(e) => setAmountPerInterval(e.target.value)}
          placeholder="e.g., 100"
        />
      </div>

      <div>
        <label>Total Amount (USDC)</label>
        <input
          type="number"
          value={totalAmount}
          onChange={(e) => setTotalAmount(e.target.value)}
          placeholder="e.g., 1000"
        />
      </div>

      <button
        onClick={handleCreate}
        disabled={isLoading || isApproving}
        className="bg-blue-500 text-white px-4 py-2 rounded"
      >
        {isApproving ? "Approving..." : isLoading ? "Creating..." : "Create Schedule"}
      </button>
    </div>
  );
}
```

### 2. Dashboard Schedule List

```typescript
// app/components/dashboard/SchedulesList.tsx
import { useAccount } from "wagmi";
import { useActiveSchedules } from "@/hooks/useSchedules";
import { ScheduleCard } from "./ScheduleCard";

export function SchedulesList() {
  const { address } = useAccount();
  const { schedules, isLoading } = useActiveSchedules(address);

  if (isLoading) return <div>Loading schedules...</div>;

  return (
    <div className="grid gap-4">
      {schedules.map((scheduleId) => (
        <ScheduleCard
          key={scheduleId.toString()}
          userAddress={address!}
          scheduleId={scheduleId}
        />
      ))}
    </div>
  );
}
```

## Utility Functions

### 1. Format Schedule Data

```typescript
// lib/utils/dca.ts
export enum DCAFrequency {
  DAILY = 0,
  WEEKLY = 1,
  BIWEEKLY = 2,
  MONTHLY = 3,
}

export const frequencyLabels = {
  [DCAFrequency.DAILY]: "Daily",
  [DCAFrequency.WEEKLY]: "Weekly",
  [DCAFrequency.BIWEEKLY]: "Biweekly",
  [DCAFrequency.MONTHLY]: "Monthly",
};

export const frequencyDays = {
  [DCAFrequency.DAILY]: 1,
  [DCAFrequency.WEEKLY]: 7,
  [DCAFrequency.BIWEEKLY]: 14,
  [DCAFrequency.MONTHLY]: 30,
};

export function formatUSDC(amount: bigint): string {
  return (Number(amount) / 1e6).toFixed(2);
}

export function calculateNextExecution(
  lastExecution: bigint,
  frequency: DCAFrequency
): Date {
  const days = frequencyDays[frequency];
  const nextTime = Number(lastExecution) * 1000 + days * 24 * 60 * 60 * 1000;
  return new Date(nextTime);
}

export function isScheduleReady(
  lastExecution: bigint,
  frequency: DCAFrequency
): boolean {
  const nextExecution = calculateNextExecution(lastExecution, frequency);
  return new Date() >= nextExecution;
}
```

### 2. Gas Estimation

```typescript
// lib/utils/gas.ts
export function estimateGas(
  frequency: DCAFrequency,
  amount: bigint
): number {
  // Rough estimates
  const createGas = 150000;
  const executeGas = 250000;
  const cancelGas = 100000;

  return createGas; // Adjust based on actual measurements
}
```

## Gelato Integration

### 1. Create Gelato Task

```typescript
// lib/gelato/createTask.ts
import { GelatoOpsSDK } from "@gelatonetwork/ops-sdk";

export async function createGelatoTask(
  userAddress: string,
  scheduleId: bigint,
  rpcUrl: string
) {
  const sdk = new GelatoOpsSDK({
    chainId: 8453, // Base
    rpcUrl,
  });

  const task = await sdk.createTask({
    name: `DCA-${scheduleId}`,
    taskCreator: userAddress,
    execAddress: process.env.NEXT_PUBLIC_DCA_RESOLVER,
    execSelector: "0x...", // checker() selector
    resolverAddress: process.env.NEXT_PUBLIC_DCA_RESOLVER,
    resolverData: encodeResolverData(userAddress, scheduleId),
    isDedicatedMsgSender: false,
    isUseTokenPayment: true,
  });

  return task.taskId;
}

function encodeResolverData(userAddress: string, scheduleId: bigint): string {
  // Encode data for Gelato resolver
  return "0x..."; // Implementation
}
```

## Error Handling

```typescript
// lib/utils/errors.ts
export const DCA_ERRORS = {
  INSUFFICIENT_BALANCE: "Insufficient USDC balance",
  APPROVAL_FAILED: "USDC approval failed",
  SCHEDULE_CREATE_FAILED: "Failed to create schedule",
  SCHEDULE_CANCEL_FAILED: "Failed to cancel schedule",
  GELATO_TASK_FAILED: "Gelato task creation failed",
  INVALID_TOKEN: "Invalid target token address",
  NO_ACTIVE_SCHEDULES: "No active schedules found",
};
```

## Testing in Frontend

```typescript
// __tests__/integration/dca.integration.ts
import { expect, describe, it } from "vitest";
import { parseUnits } from "ethers";
import { useCreateSchedule } from "@/hooks/useDCASchedule";

describe("DCA Integration", () => {
  it("should create a schedule", async () => {
    // Mock implementation
    const { createSchedule } = useCreateSchedule();
    // Test schedule creation
  });

  it("should list active schedules", async () => {
    // Mock implementation
    // Test schedule listing
  });

  it("should handle errors", async () => {
    // Test error handling
  });
});
```

## Environment Variables

Add to `.env.local`:

```env
NEXT_PUBLIC_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b1566dA3975
NEXT_PUBLIC_DCA_VAULT=0x...
NEXT_PUBLIC_DCA_RESOLVER=0x...
NEXT_PUBLIC_CHAIN_ID=8453
GELATO_API_KEY=your_api_key
```

## Resources

- [Wagmi Documentation](https://wagmi.sh/)
- [Viem Documentation](https://viem.sh/)
- [RainbowKit Documentation](https://www.rainbowkit.com/)
- [Base Documentation](https://docs.base.org/)
- [Gelato Automation](https://docs.gelato.network/)

## Support

For integration issues, contact the development team or create an issue in the repository.
