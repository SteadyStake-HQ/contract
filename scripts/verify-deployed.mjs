#!/usr/bin/env node
/**
 * Verify deployed SteadyStake contracts on a chain's block explorer.
 *
 * `forge verify-contract` SIGILLs on the deploy machine (same as `forge script`, see
 * DEPLOY_BOT_CHAIN.md), so this rebuilds a solc standard-JSON input from the Foundry artifact's
 * own metadata and posts it to the explorer's API directly.
 *
 *   node scripts/verify-deployed.mjs 56              # all four contracts
 *   node scripts/verify-deployed.mjs 137 DCAVault    # just one
 *
 * Chains 56/137 go to Etherscan's V2 multichain API and need ETHERSCAN_API_KEY (contracts/.env).
 * Chain 2222 goes to Sourcify: Kavascan's verifier (api.verify.mintscan.io) only accepts solc up
 * to 0.8.30 and these were built with 0.8.35, so it can never match there.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");

// Build dir that reproduces each chain's on-chain bytecode. Each chain got its own build for a
// reason — see the DEPLOY_*.md for that chain before changing any of this.
const CHAINS = {
  56: { build: "out-bsc", verifier: "etherscan" },
  137: { build: "out-poly", verifier: "etherscan" },
  2222: { build: "out-paris", verifier: "sourcify" },
};

const CONTRACTS = {
  ZeroExAdapter: { artifact: "SwapHelper.sol/ZeroExAdapter.json", id: "src/SwapHelper.sol:ZeroExAdapter" },
  DCAVault: { artifact: "DCAVault.sol/DCAVault.json", id: "src/DCAVault.sol:DCAVault" },
  DCAResolver: { artifact: "DCAResolver.sol/DCAResolver.json", id: "src/DCAResolver.sol:DCAResolver" },
  GasTank: { artifact: "GasTank.sol/GasTank.json", id: "src/GasTank.sol:GasTank" },
};

// Constructor args are read back off-chain rather than trusted from a broadcast file, in the
// declared order of each constructor.
const CTOR_GETTERS = {
  ZeroExAdapter: ["USDC()", "ZERO_EX_ROUTER()"],
  DCAVault: ["swapRouter()", "usdc()"],
  DCAResolver: ["dcaVault()"],
  GasTank: ["usdc()"],
};

const RPC = {
  56: "https://bsc-dataseed.binance.org",
  137: "https://polygon-bor-rpc.publicnode.com",
  2222: "https://evm.kava.io",
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function loadEnv() {
  const p = path.join(ROOT, ".env");
  if (!fs.existsSync(p)) return;
  for (const line of fs.readFileSync(p, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "").trim();
  }
}

async function rpc(chainId, method, params) {
  const res = await fetch(RPC[chainId], {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result;
}

let keccak256, toHex;
try {
  ({ keccak256, toHex } = await import("../../backend/node_modules/viem/_esm/index.js"));
} catch {
  console.warn("! viem not resolvable — skipping the source-hash pre-check");
}

/**
 * Rebuild the exact standard-JSON input solc saw, from the artifact's embedded metadata.
 * Foundry normalises CRLF to LF before handing sources to solc, so the working copy's line
 * endings must be normalised too or every keccak (and therefore the metadata hash, and therefore
 * the bytecode) comes out different.
 */
function standardJson(build, name) {
  const art = JSON.parse(fs.readFileSync(path.join(ROOT, build, CONTRACTS[name].artifact), "utf8"));
  const meta = typeof art.metadata === "string" ? JSON.parse(art.metadata) : art.metadata;

  const sources = {};
  for (const [srcPath, info] of Object.entries(meta.sources)) {
    const content = fs.readFileSync(path.join(ROOT, srcPath), "utf8").replace(/\r\n/g, "\n");
    if (keccak256 && keccak256(toHex(content)) !== info.keccak256) {
      throw new Error(
        `${srcPath} on disk does not match what ${build} was compiled from.\n` +
          `  Check out the revision that produced this deployment, or rebuild.`,
      );
    }
    sources[srcPath] = { content };
  }

  const settings = JSON.parse(JSON.stringify(meta.settings));
  delete settings.compilationTarget;
  settings.outputSelection = { "*": { "*": ["abi", "evm.bytecode", "evm.deployedBytecode"] } };

  return { input: { language: "Solidity", sources, settings }, compiler: meta.compiler.version };
}

async function constructorArgs(chainId, name) {
  const addr = addresses(chainId)[name];
  const words = [];
  for (const sig of CTOR_GETTERS[name]) {
    // every one of these getters returns a single address, so the raw 32-byte word the node
    // returns is already its ABI encoding
    const selector = keccak256 ? keccak256(toHex(sig)).slice(0, 10) : null;
    if (!selector) throw new Error("viem required to derive constructor args");
    const word = await rpc(chainId, "eth_call", [{ to: addr, data: selector }, "latest"]);
    words.push(word.slice(2));
  }
  return words.join("");
}

function addresses(chainId) {
  const p = path.resolve(ROOT, "..", "backend", "deployed-addresses.json");
  const entry = JSON.parse(fs.readFileSync(p, "utf8"))[String(chainId)];
  if (!entry) throw new Error(`no deployed addresses for chain ${chainId}`);
  return entry;
}

async function post(api, params) {
  const res = await fetch(api, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return { status: "0", result: `HTTP ${res.status}: ${text.slice(0, 300)}` };
  }
}

/** Cheap idempotence check, so a re-run is a no-op rather than a resubmission. */
async function alreadyVerified(chainId, address) {
  if (CHAINS[chainId].verifier === "sourcify") {
    const j = await (await fetch(`https://sourcify.dev/server/v2/contract/${chainId}/${address}`)).json();
    return j.match ? `already ${j.match}` : null;
  }
  const key = process.env.ETHERSCAN_API_KEY;
  const api = `https://api.etherscan.io/v2/api?chainid=${chainId}`;
  const j = await (
    await fetch(`${api}&module=contract&action=getsourcecode&address=${address}&apikey=${key}`)
  ).json();
  return j.result?.[0]?.SourceCode ? "already verified" : null;
}

async function viaEtherscan(chainId, name, address, input, compiler, ctor) {
  const key = process.env.ETHERSCAN_API_KEY;
  if (!key) throw new Error("ETHERSCAN_API_KEY is not set (contracts/.env)");
  const api = `https://api.etherscan.io/v2/api?chainid=${chainId}`;

  const submit = await post(api, {
    apikey: key,
    module: "contract",
    action: "verifysourcecode",
    codeformat: "solidity-standard-json-input",
    contractaddress: address,
    contractname: CONTRACTS[name].id,
    compilerversion: `v${compiler}`,
    constructorArguements: ctor,
    sourceCode: JSON.stringify(input),
  });
  if (String(submit.status) !== "1") throw new Error(String(submit.result).slice(0, 300));

  for (let i = 0; i < 25; i++) {
    await sleep(5000);
    const st = await post(api, { apikey: key, module: "contract", action: "checkverifystatus", guid: submit.result });
    const r = String(st.result || "");
    if (/pass|verified/i.test(r)) return r;
    if (/^fail|unable|error/i.test(r)) throw new Error(r.slice(0, 300));
  }
  throw new Error("timed out polling for verification status");
}

async function viaSourcify(chainId, name, address, input, compiler) {
  const server = "https://sourcify.dev/server";
  const res = await fetch(`${server}/v2/verify/${chainId}/${address}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ stdJsonInput: input, compilerVersion: compiler, contractIdentifier: CONTRACTS[name].id }),
  });
  const sub = await res.json();
  if (!sub.verificationId) throw new Error(JSON.stringify(sub).slice(0, 300));

  for (let i = 0; i < 30; i++) {
    await sleep(4000);
    const job = await (await fetch(`${server}/v2/verify/${sub.verificationId}`)).json();
    if (!job.isJobCompleted) continue;
    if (job.error) throw new Error(`${job.error.customCode || ""} ${job.error.message || ""}`.slice(0, 300));
    return `${job.contract?.match} (creation ${job.contract?.creationMatch}, runtime ${job.contract?.runtimeMatch})`;
  }
  throw new Error("timed out polling for verification status");
}

loadEnv();

const chainId = Number(process.argv[2]);
if (!CHAINS[chainId]) {
  console.error(`usage: node scripts/verify-deployed.mjs <${Object.keys(CHAINS).join("|")}> [Contract,...]`);
  process.exit(1);
}
const names = (process.argv[3] || Object.keys(CONTRACTS).join(",")).split(",");
const { build, verifier } = CHAINS[chainId];
const addrs = addresses(chainId);

let failed = 0;
for (const name of names) {
  const address = addrs[name];
  process.stdout.write(`[${chainId}] ${name} ${address} via ${verifier} (${build}) ... `);
  try {
    const done = await alreadyVerified(chainId, address);
    if (done) {
      console.log(`OK — ${done}`);
      continue;
    }
    const { input, compiler } = standardJson(build, name);
    const ctor = await constructorArgs(chainId, name);
    const msg =
      verifier === "etherscan"
        ? await viaEtherscan(chainId, name, address, input, compiler, ctor)
        : await viaSourcify(chainId, name, address, input, compiler);
    console.log(`OK — ${msg}`);
  } catch (e) {
    failed++;
    console.log(`FAILED\n    ${e.message}`);
  }
}
// exitCode rather than process.exit(): forcing the process down while keep-alive sockets are
// still open trips a libuv assertion on Windows
process.exitCode = failed ? 1 : 0;
