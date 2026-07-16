#!/usr/bin/env node
/**
 * Reads the latest Base Sepolia (84532) deploy broadcast and updates
 * frontend/config/deployed-addresses.json and backend/deployed-addresses.json.
 * Run after: forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify
 *
 * Base Sepolia uses DeployTestnet which deploys MockSwapRouter (mapped to ZeroExAdapter in config).
 */
const fs = require("fs");
const path = require("path");

const CHAIN_ID = 84532;
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
  const a = addr.replace(/^0x/i, "").toLowerCase();
  const cs = "0x" + a;
  return cs;
}

function main() {
  const runPath = findLatestRun();
  if (!runPath) {
    console.warn("No broadcast run found. Deploy with: forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify");
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
    MockDEGEN: "",
    MockCBETH: "",
  };
  for (const tx of data.transactions || []) {
    if (tx.transactionType !== "CREATE") continue;
    const name = tx.contractName;
    const addr = tx.contractAddress ? toChecksumAddress("0x" + String(tx.contractAddress).replace(/^0x/i, "")) : "";
    if (name === "DCAVault" && !extracted.DCAVault) extracted.DCAVault = addr;
    else if (name === "DCAResolver" && !extracted.DCAResolver) extracted.DCAResolver = addr;
    else if (name === "MockSwapRouter" && !extracted.ZeroExAdapter) extracted.ZeroExAdapter = addr;
    else if (name === "GasTank" && !extracted.GasTank) extracted.GasTank = addr;
    else if (name === "MockUSDC" && !extracted.MockUSDC) extracted.MockUSDC = addr;
    else if (name === "MockAERO" && !extracted.MockAERO) extracted.MockAERO = addr;
    else if (name === "MockDEGEN" && !extracted.MockDEGEN) extracted.MockDEGEN = addr;
    else if (name === "MockCBETH" && !extracted.MockCBETH) extracted.MockCBETH = addr;
  }
  const entry = { chainId: CHAIN_ID, ...extracted };
  console.log("Extracted Base Sepolia (84532):", entry);

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

  const existingFrontend = frontend["84532"] || {};
  const existingBackend = backend["84532"] || {};
  frontend["84532"] = {
    chainId: CHAIN_ID,
    DCAVault: entry.DCAVault || existingFrontend.DCAVault || "0x0000000000000000000000000000000000000000",
    DCAResolver: entry.DCAResolver || existingFrontend.DCAResolver || "0x0000000000000000000000000000000000000000",
    ZeroExAdapter: entry.ZeroExAdapter || existingFrontend.ZeroExAdapter || "0x0000000000000000000000000000000000000000",
    GasTank: entry.GasTank || existingFrontend.GasTank || "0x0000000000000000000000000000000000000000",
    MockUSDC: entry.MockUSDC || existingFrontend.MockUSDC || "",
    MockAERO: entry.MockAERO || existingFrontend.MockAERO || "",
    MockDEGEN: entry.MockDEGEN || existingFrontend.MockDEGEN || "",
    MockCBETH: entry.MockCBETH || existingFrontend.MockCBETH || "",
  };
  backend["84532"] = {
    chainId: CHAIN_ID,
    DCAVault: frontend["84532"].DCAVault,
    GasTank: frontend["84532"].GasTank,
  };

  fs.writeFileSync(FRONTEND_PATH, JSON.stringify(frontend, null, 2) + "\n", "utf8");
  fs.writeFileSync(BACKEND_PATH, JSON.stringify(backend, null, 2) + "\n", "utf8");
  console.log("Updated", FRONTEND_PATH);
  console.log("Updated", BACKEND_PATH);
}

main();
