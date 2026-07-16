#!/usr/bin/env node
/**
 * Reads the latest Base mainnet (8453) deploy broadcast and writes
 * frontend/config/deployed-addresses.json. Run after: forge script script/Deploy.s.sol:DeployMainnet --rpc-url base --broadcast --verify
 */
const fs = require("fs");
const path = require("path");

const CHAIN_ID = 8453;
const BROADCAST_DIR = path.join(__dirname, "..", "broadcast", "Deploy.s.sol", String(CHAIN_ID));
const OUT_PATH = path.join(__dirname, "..", "..", "frontend", "config", "deployed-addresses.json");

function findLatestRun() {
  if (!fs.existsSync(BROADCAST_DIR)) {
    console.warn("No broadcast folder for chain", CHAIN_ID, "- deploy first.");
    return null;
  }
  const runLatest = path.join(BROADCAST_DIR, "run-latest.json");
  if (fs.existsSync(runLatest)) return runLatest;
  const files = fs.readdirSync(BROADCAST_DIR).filter((f) => f.startsWith("run-") && f.endsWith(".json"));
  if (files.length === 0) return null;
  files.sort();
  return path.join(BROADCAST_DIR, files[files.length - 1]);
}

function main() {
  const runPath = findLatestRun();
  if (!runPath) {
    console.warn("No broadcast run found. Deploy with: forge script script/Deploy.s.sol:DeployMainnet --rpc-url base --broadcast --verify");
    process.exit(0);
    return;
  }
  const data = JSON.parse(fs.readFileSync(runPath, "utf8"));
  const addresses = { chainId: CHAIN_ID, DCAVault: "", DCAResolver: "", ZeroExAdapter: "" };
  for (const tx of data.transactions || []) {
    const name = tx.contractName;
    const addr = tx.contractAddress ? "0x" + tx.contractAddress.replace(/^0x/i, "").toLowerCase() : "";
    if (name === "DCAVault") addresses.DCAVault = addr;
    else if (name === "DCAResolver") addresses.DCAResolver = addr;
    else if (name === "ZeroExAdapter") addresses.ZeroExAdapter = addr;
  }
  const outDir = path.dirname(OUT_PATH);
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(OUT_PATH, JSON.stringify(addresses, null, 2) + "\n", "utf8");
  console.log("Wrote", OUT_PATH, ":", addresses);
}

main();
