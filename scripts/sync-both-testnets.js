#!/usr/bin/env node
/**
 * Reads the latest broadcast for Base Sepolia (84532) and Ethereum Sepolia (11155111)
 * and updates frontend/config/deployed-addresses.json and backend/deployed-addresses.json
 * for both chains. Preserves other chain IDs in both files.
 *
 * Run after deploying both testnets:
 *   Base Sepolia:  forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify
 *   ETH Sepolia:   forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC --rpc-url eth_sepolia --broadcast --verify
 *
 * Usage (from repo root): node contracts/scripts/sync-both-testnets.js
 */
const fs = require("fs");
const path = require("path");

const FRONTEND_PATH = path.join(__dirname, "..", "..", "frontend", "config", "deployed-addresses.json");
const BACKEND_PATH = path.join(__dirname, "..", "..", "backend", "deployed-addresses.json");
const BROADCAST_BASE = path.join(__dirname, "..", "broadcast", "Deploy.s.sol");

function findLatestRun(chainId) {
  const dir = path.join(BROADCAST_BASE, String(chainId));
  if (!fs.existsSync(dir)) return null;
  const runLatest = path.join(dir, "run-latest.json");
  if (fs.existsSync(runLatest)) return runLatest;
  const files = fs.readdirSync(dir).filter((f) => f.startsWith("run-") && f.endsWith(".json"));
  if (files.length === 0) return null;
  files.sort();
  return path.join(dir, files[files.length - 1]);
}

function toChecksumAddress(addr) {
  if (!addr || addr.length !== 42) return addr;
  const a = String(addr).replace(/^0x/i, "").toLowerCase();
  return "0x" + a;
}

function extractBaseSepolia(data) {
  const extracted = {
    DCAVault: "", DCAResolver: "", ZeroExAdapter: "", GasTank: "",
    MockUSDC: "", MockAERO: "", MockDEGEN: "", MockCBETH: "",
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
  return extracted;
}

function extractEthSepolia(data) {
  const extracted = {
    DCAVault: "", DCAResolver: "", ZeroExAdapter: "", GasTank: "",
    MockUSDC: "", MockAERO: "",
  };
  for (const tx of data.transactions || []) {
    if (tx.transactionType !== "CREATE") continue;
    const name = tx.contractName;
    const addr = tx.contractAddress ? toChecksumAddress("0x" + String(tx.contractAddress).replace(/^0x/i, "")) : "";
    if (name === "ZeroExAdapter" && !extracted.ZeroExAdapter) extracted.ZeroExAdapter = addr;
    else if (name === "MockSwapRouter" && !extracted.ZeroExAdapter) extracted.ZeroExAdapter = addr;
    else if (name === "DCAVault" && !extracted.DCAVault) extracted.DCAVault = addr;
    else if (name === "DCAResolver" && !extracted.DCAResolver) extracted.DCAResolver = addr;
    else if (name === "GasTank" && !extracted.GasTank) extracted.GasTank = addr;
    else if (name === "MockUSDC" && !extracted.MockUSDC) extracted.MockUSDC = addr;
    else if (name === "MockAERO" && !extracted.MockAERO) extracted.MockAERO = addr;
  }
  return extracted;
}

const ZERO = "0x0000000000000000000000000000000000000000";

function main() {
  const frontend = fs.existsSync(FRONTEND_PATH)
    ? JSON.parse(fs.readFileSync(FRONTEND_PATH, "utf8"))
    : {};
  const backend = fs.existsSync(BACKEND_PATH)
    ? JSON.parse(fs.readFileSync(BACKEND_PATH, "utf8"))
    : {};

  // Base Sepolia (84532)
  const run84532 = findLatestRun(84532);
  if (run84532) {
    const data = JSON.parse(fs.readFileSync(run84532, "utf8"));
    const ext = extractBaseSepolia(data);
    const existing = frontend["84532"] || {};
    frontend["84532"] = {
      chainId: 84532,
      DCAVault: ext.DCAVault || existing.DCAVault || ZERO,
      DCAResolver: ext.DCAResolver || existing.DCAResolver || ZERO,
      ZeroExAdapter: ext.ZeroExAdapter || existing.ZeroExAdapter || ZERO,
      GasTank: ext.GasTank || existing.GasTank || ZERO,
      MockUSDC: ext.MockUSDC || existing.MockUSDC || "",
      MockAERO: ext.MockAERO || existing.MockAERO || "",
      MockDEGEN: ext.MockDEGEN || existing.MockDEGEN || "",
      MockCBETH: ext.MockCBETH || existing.MockCBETH || "",
    };
    backend["84532"] = { chainId: 84532, DCAVault: frontend["84532"].DCAVault, GasTank: frontend["84532"].GasTank };
    console.log("Updated addresses from Base Sepolia (84532) broadcast.");
  } else {
    console.warn("No Base Sepolia (84532) broadcast found; skipping. Deploy with: forge script script/Deploy.s.sol:DeployTestnet --rpc-url base_sepolia --broadcast --verify");
  }

  // Ethereum Sepolia (11155111)
  const run11155111 = findLatestRun(11155111);
  if (run11155111) {
    const data = JSON.parse(fs.readFileSync(run11155111, "utf8"));
    const ext = extractEthSepolia(data);
    const existing = frontend["11155111"] || {};
    frontend["11155111"] = {
      chainId: 11155111,
      DCAVault: ext.DCAVault || existing.DCAVault || ZERO,
      DCAResolver: ext.DCAResolver || existing.DCAResolver || ZERO,
      ZeroExAdapter: ext.ZeroExAdapter || existing.ZeroExAdapter || ZERO,
      GasTank: ext.GasTank || existing.GasTank || ZERO,
      MockUSDC: ext.MockUSDC || existing.MockUSDC || "",
      MockAERO: ext.MockAERO || existing.MockAERO || "",
    };
    if (!frontend["11155111"].MockUSDC) delete frontend["11155111"].MockUSDC;
    if (!frontend["11155111"].MockAERO) delete frontend["11155111"].MockAERO;
    backend["11155111"] = { chainId: 11155111, DCAVault: frontend["11155111"].DCAVault, GasTank: frontend["11155111"].GasTank };
    console.log("Updated addresses from Ethereum Sepolia (11155111) broadcast.");
  } else {
    console.warn("No Ethereum Sepolia (11155111) broadcast found; skipping. Deploy with: forge script script/Deploy.s.sol:DeployEthSepoliaWithMockUSDC --rpc-url eth_sepolia --broadcast --verify");
  }

  if (!run84532 && !run11155111) {
    console.error("No broadcast found for either testnet. Deploy at least one chain first.");
    process.exit(1);
  }

  const frontendDir = path.dirname(FRONTEND_PATH);
  const backendDir = path.dirname(BACKEND_PATH);
  if (!fs.existsSync(frontendDir)) fs.mkdirSync(frontendDir, { recursive: true });
  if (!fs.existsSync(backendDir)) fs.mkdirSync(backendDir, { recursive: true });

  fs.writeFileSync(FRONTEND_PATH, JSON.stringify(frontend, null, 2) + "\n", "utf8");
  fs.writeFileSync(BACKEND_PATH, JSON.stringify(backend, null, 2) + "\n", "utf8");
  console.log("Written:", FRONTEND_PATH);
  console.log("Written:", BACKEND_PATH);
}

main();
