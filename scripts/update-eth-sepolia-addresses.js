#!/usr/bin/env node
/**
 * Reads the latest Ethereum Sepolia (11155111) deploy broadcast and updates
 * frontend/config/deployed-addresses.json and backend/deployed-addresses.json.
 * Run after: forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC --rpc-url eth_sepolia --broadcast --verify
 *
 * Usage (from repo root): node contracts/scripts/update-eth-sepolia-addresses.js
 */
const fs = require("fs");
const path = require("path");

const CHAIN_ID = 11155111;
const BROADCAST_DIR = path.join(__dirname, "..", "broadcast", "Deploy.s.sol", String(CHAIN_ID));
const FRONTEND_PATH = path.join(__dirname, "..", "..", "frontend", "config", "deployed-addresses.json");
const BACKEND_PATH = path.join(__dirname, "..", "..", "backend", "deployed-addresses.json");

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

function toChecksumAddress(addr) {
  if (!addr || addr.length !== 42) return addr;
  const a = String(addr).replace(/^0x/i, "").toLowerCase();
  return "0x" + a;
}

function main() {
  const runPath = findLatestRun();
  if (!runPath) {
    console.warn("No broadcast run found. Deploy with: forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC --rpc-url eth_sepolia --broadcast --verify --chain-id 11155111");
    process.exit(1);
    return;
  }
  const data = JSON.parse(fs.readFileSync(runPath, "utf8"));
  const extracted = {
    DCAVault: "",
    DCAResolver: "",
    ZeroExAdapter: "",
    GasTank: "",
    MockUSDC: "",
    MockAERO: "",
  };
  for (const tx of data.transactions || []) {
    if (tx.transactionType !== "CREATE") continue;
    const name = tx.contractName;
    const addr = tx.contractAddress ? toChecksumAddress("0x" + String(tx.contractAddress).replace(/^0x/i, "")) : "";
    if (name === "ZeroExAdapter" && !extracted.ZeroExAdapter) extracted.ZeroExAdapter = addr;
    else if (name === "MockSwapRouter" && !extracted.ZeroExAdapter) extracted.ZeroExAdapter = addr; // MockUSDC deploy uses MockSwapRouter in adapter slot
    else if (name === "DCAVault" && !extracted.DCAVault) extracted.DCAVault = addr;
    else if (name === "DCAResolver" && !extracted.DCAResolver) extracted.DCAResolver = addr;
    else if (name === "GasTank" && !extracted.GasTank) extracted.GasTank = addr;
    else if (name === "MockUSDC" && !extracted.MockUSDC) extracted.MockUSDC = addr;
    else if (name === "MockAERO" && !extracted.MockAERO) extracted.MockAERO = addr;
  }
  const key = String(CHAIN_ID);
  const entry = { chainId: CHAIN_ID, ...extracted };
  console.log("Extracted ETH Sepolia (11155111):", entry);

  const frontendDir = path.dirname(FRONTEND_PATH);
  const backendDir = path.dirname(BACKEND_PATH);
  if (!fs.existsSync(frontendDir)) fs.mkdirSync(frontendDir, { recursive: true });
  if (!fs.existsSync(backendDir)) fs.mkdirSync(backendDir, { recursive: true });

  const frontend = fs.existsSync(FRONTEND_PATH)
    ? JSON.parse(fs.readFileSync(FRONTEND_PATH, "utf8"))
    : {};
  const backend = fs.existsSync(BACKEND_PATH)
    ? JSON.parse(fs.readFileSync(BACKEND_PATH, "utf8"))
    : {};

  const existingFrontend = frontend[key] || {};
  const zero = "0x0000000000000000000000000000000000000000";
  frontend[key] = {
    chainId: CHAIN_ID,
    DCAVault: extracted.DCAVault || existingFrontend.DCAVault || zero,
    DCAResolver: extracted.DCAResolver || existingFrontend.DCAResolver || zero,
    ZeroExAdapter: extracted.ZeroExAdapter || existingFrontend.ZeroExAdapter || zero,
    GasTank: extracted.GasTank || existingFrontend.GasTank || zero,
    MockUSDC: extracted.MockUSDC || existingFrontend.MockUSDC || "",
    MockAERO: extracted.MockAERO || existingFrontend.MockAERO || "",
  };
  // Remove empty optional keys for cleaner JSON
  if (!frontend[key].MockUSDC) delete frontend[key].MockUSDC;
  if (!frontend[key].MockAERO) delete frontend[key].MockAERO;
  backend[key] = {
    chainId: CHAIN_ID,
    DCAVault: frontend[key].DCAVault,
    GasTank: frontend[key].GasTank,
  };

  fs.writeFileSync(FRONTEND_PATH, JSON.stringify(frontend, null, 2) + "\n", "utf8");
  fs.writeFileSync(BACKEND_PATH, JSON.stringify(backend, null, 2) + "\n", "utf8");
  console.log("Updated", FRONTEND_PATH);
  console.log("Updated", BACKEND_PATH);
}

main();
