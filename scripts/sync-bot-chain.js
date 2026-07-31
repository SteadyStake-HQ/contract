#!/usr/bin/env node
/**
 * Reads the latest BOT Chain deploy broadcast and merges the addresses into both
 * frontend/config/deployed-addresses.json and backend/deployed-addresses.json.
 *
 * Usage: node scripts/sync-bot-chain.js [677|968]     (default: 968 = testnet)
 *
 * Run after:
 *   forge script script/Deploy.s.sol:DeployBotTestnet --rpc-url bot_testnet --broadcast --legacy
 *   forge script script/Deploy.s.sol:DeployBotMainnet --rpc-url bot --broadcast --legacy
 */
const fs = require("fs");
const path = require("path");

const CHAIN_ID = parseInt(process.argv[2] || "968", 10);
if (CHAIN_ID !== 677 && CHAIN_ID !== 968) {
  console.error("Usage: node scripts/sync-bot-chain.js [677|968]");
  process.exit(1);
}

const BROADCAST_DIR = path.join(__dirname, "..", "broadcast", "Deploy.s.sol", String(CHAIN_ID));
const TARGETS = [
  path.join(__dirname, "..", "..", "frontend", "config", "deployed-addresses.json"),
  path.join(__dirname, "..", "..", "backend", "deployed-addresses.json"),
];

function findLatestRun() {
  if (!fs.existsSync(BROADCAST_DIR)) return null;
  const runLatest = path.join(BROADCAST_DIR, "run-latest.json");
  if (fs.existsSync(runLatest)) return runLatest;
  const files = fs
    .readdirSync(BROADCAST_DIR)
    .filter((f) => f.startsWith("run-") && f.endsWith(".json"))
    .sort();
  return files.length ? path.join(BROADCAST_DIR, files[files.length - 1]) : null;
}

function main() {
  const runPath = findLatestRun();
  if (!runPath) {
    console.warn(`No broadcast run found for chain ${CHAIN_ID}. Deploy first.`);
    process.exit(0);
  }

  const data = JSON.parse(fs.readFileSync(runPath, "utf8"));
  const entry = { chainId: CHAIN_ID };
  for (const tx of data.transactions || []) {
    const addr = tx.contractAddress ? "0x" + tx.contractAddress.replace(/^0x/i, "").toLowerCase() : "";
    if (!addr) continue;
    // UniV2SwapAdapter and MockSwapRouter both take the ZeroExAdapter slot: that field is
    // simply whatever DCAVault.swapRouter points at, which differs per deploy script.
    if (tx.contractName === "DCAVault") entry.DCAVault = addr;
    else if (tx.contractName === "DCAResolver") entry.DCAResolver = addr;
    else if (tx.contractName === "UniV2SwapAdapter") entry.ZeroExAdapter = addr;
    else if (tx.contractName === "MockSwapRouter") entry.ZeroExAdapter = addr;
    else if (tx.contractName === "GasTank") entry.GasTank = addr;
    // Only present from DeployBotTestnetWithMockUSDC; the real-USDT deploy uses bridged tokens.
    else if (tx.contractName === "MockUSDC") entry.MockUSDC = addr;
    else if (tx.contractName === "MockAERO") entry.MockAERO = addr;
  }

  const missing = ["DCAVault", "DCAResolver", "ZeroExAdapter", "GasTank"].filter((k) => !entry[k]);
  if (missing.length) console.warn(`Warning: no address found for ${missing.join(", ")}`);

  for (const outPath of TARGETS) {
    let existing = {};
    if (fs.existsSync(outPath)) {
      try {
        existing = JSON.parse(fs.readFileSync(outPath, "utf8"));
      } catch {
        console.warn(`Could not parse ${outPath}; rewriting.`);
      }
    }
    existing[String(CHAIN_ID)] = { ...existing[String(CHAIN_ID)], ...entry };
    const ordered = Object.fromEntries(
      Object.keys(existing)
        .sort((a, b) => Number(a) - Number(b))
        .map((k) => [k, existing[k]])
    );
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(ordered, null, 2) + "\n", "utf8");
    console.log("Wrote", outPath);
  }
  console.log(`Chain ${CHAIN_ID}:`, entry);
}

main();
