// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {DCAResolver} from "../src/DCAResolver.sol";
import {GasTank} from "../src/GasTank.sol";
import {MockSwapRouter, ZeroExAdapter} from "../src/SwapHelper.sol";
import {UniV2SwapAdapter} from "../src/UniV2SwapAdapter.sol";
import {MockUSDC, MockAERO, MockDEGEN, MockCBETH} from "../src/MockTokens.sol";
import {Constants} from "../src/Constants.sol";

/**
 * @notice Wires the relayer as the GasTank executor, and refuses to deploy without one.
 * @dev This used to be a `try vm.envAddress("RELAYER_ADDRESS") … catch {}` in every deploy
 *      contract. When RELAYER_ADDRESS was absent the catch swallowed it and the GasTank went
 *      live with executor == address(0) — which makes every recordExecution revert with
 *      OnlyExecutor, so user gas is never deducted and nothing anywhere reports a problem.
 *      Failing the deploy is the only way that stays visible.
 */
abstract contract GasTankExecutorSetup is Script {
    function _wireExecutor(GasTank gasTank) internal {
        // Reverts when RELAYER_ADDRESS is unset — deliberately fatal.
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        require(relayer != address(0), "RELAYER_ADDRESS must not be the zero address");
        gasTank.setExecutor(relayer);
        require(gasTank.executor() == relayer, "GasTank executor was not set");
    }
}

contract DeployTestnet is GasTankExecutorSetup {
    // Base Sepolia addresses (using 0x Protocol instead of 1inch)
    address constant ZERO_EX_ROUTER = 0xDef1C0ded9bEf7C1100000000000000000000000;
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy mock tokens for testing
        MockUSDC usdc = new MockUSDC();
        MockAERO aero = new MockAERO();
        MockDEGEN degen = new MockDEGEN();
        MockCBETH cbeth = new MockCBETH();
        
        // Deploy mock swap router (use same USDC as vault)
        MockSwapRouter swapRouter = new MockSwapRouter(address(usdc));
        
        // Deploy main DCA vault
        DCAVault vault = new DCAVault(address(swapRouter), address(usdc));
        
        // Deploy Gelato resolver
        DCAResolver resolver = new DCAResolver(address(vault));

        // Deploy GasTank (user-funded gas for DCA execution)
        GasTank gasTank = new GasTank(address(usdc));
        gasTank.setGasCostPerExecution(5000); // $0.005 per execution (Base Sepolia)
        _wireExecutor(gasTank);

        // Allow vault to fund user gas in one tx (createScheduleAndEnrollWithGas)
        vault.setGasTank(address(gasTank));

        // Auto-execution: first plan per user free; additional plans pay fee (10 USDC on testnet)
        vault.setAdditionalAutoPlanFeeUsdc6(10e6);
        vault.setAutoPlanFeeRecipient(msg.sender);

        // Mint test tokens to deployer
        usdc.mint(msg.sender, 10000e6); // 10k USDC
        aero.mint(msg.sender, 10000e18);
        degen.mint(msg.sender, 10000e18);
        cbeth.mint(msg.sender, 100e18);

        // Fund MockSwapRouter with output tokens so it can fulfill USDC -> AERO/DEGEN/cbETH swaps
        aero.mint(address(swapRouter), 100_000e18);
        degen.mint(address(swapRouter), 100_000e18);
        cbeth.mint(address(swapRouter), 1_000e18);

        vm.stopBroadcast();
        
        // Log deployment addresses
        console2.log("=== SteadyStake Deployment ===");
        console2.log("MockUSDC:", address(usdc));
        console2.log("MockAERO:", address(aero));
        console2.log("MockDEGEN:", address(degen));
        console2.log("MockCBETH:", address(cbeth));
        console2.log("SwapRouter:", address(swapRouter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

contract DeployMainnet is GasTankExecutorSetup {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Base mainnet: USDC and 0x adapter
        address usdc = Constants.USDC;
        address zeroExRouter = Constants.ZERO_EX_ROUTER;

        ZeroExAdapter adapter = new ZeroExAdapter(usdc, zeroExRouter);
        DCAVault vault = new DCAVault(address(adapter), usdc);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(usdc);
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake Base Mainnet ===");
        console2.log("USDC (existing):", usdc);
        console2.log("ZeroExAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

contract DeployBNB is GasTankExecutorSetup {
    // BNB Chain (BSC) mainnet addresses
    //
    // Binance-Peg USD Coin. NOTE: this token has **18 decimals**, not the 6 that Circle-issued USDC
    // uses on Base/Polygon. Every liquid BSC stablecoin (USDC, USDT, BUSD, FDUSD, USD1, DAI) is
    // 18-decimal; the only 6-decimal options are bridged wrappers (axlUSDC, Wormhole USDCet) whose
    // total supply is a few hundred thousand dollars — too thin to settle into. DCAVault therefore
    // derives its deposit cap from usdc.decimals(), and the frontend/backend read the per-chain
    // stable decimals from getStableDecimals(56) === 18 rather than assuming 6.
    address constant BNB_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    // 0x Swap API v2 AllowanceHolder. The legacy Exchange Proxy (0xDef1C0ded9bec7F1a...25EfF) that
    // used to be here is unusable: /swap/v1 is sunset (404s), so v2 + AllowanceHolder is the only
    // route that still returns executable calldata.
    address constant BNB_ZERO_EX_ROUTER = 0x0000000000001fF3684f28c67538d4D072C22734;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(BNB_USDC, BNB_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), BNB_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(BNB_USDC);
        // $0.01 per run. GasTank balances are denominated in the settlement token's own base
        // units, so on 18-decimal BSC that is 1e16, not the 10_000 used on 6-decimal chains.
        gasTank.setGasCostPerExecution(0.01e18);
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake BNB Mainnet ===");
        console2.log("USDC (existing):", BNB_USDC);
        console2.log("ZeroExAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

contract DeployKava is GasTankExecutorSetup {
    // Kava EVM mainnet (chain 2222)
    //
    // Stablecoin: native Tether USDt (6 decimals, ~160M supply). NOT the old Multichain USDC
    // (0xfA9343C3...A40f) — the Multichain bridge collapsed in 2023 and that token is stranded.
    address constant KAVA_USDC = 0x919C1c267BC06a7039e03fcc2eF738525769109c;
    // NOTE: Kava has no working swap route yet, so this deployment's adapter is INERT.
    // 0x does not support chain 2222 (its API rejects the chainId outright), and the only DEX,
    // Equilibre, is a Solidly fork — it exposes weth() and getPair(a,b,bool stable), so
    // UniV2SwapAdapter cannot even be constructed against it (its constructor calls WETH()).
    // The adapter below is deployed only to satisfy DCAVault's non-zero swapRouter requirement;
    // any swap attempt reverts on ZeroExAdapter's "No output received" guard rather than
    // consuming user funds. Replace it via vault.setSwapRouter() once an Equilibre adapter exists.
    address constant KAVA_ZERO_EX_ROUTER = 0x0000000000001fF3684f28c67538d4D072C22734;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(KAVA_USDC, KAVA_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), KAVA_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(KAVA_USDC);
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake Kava Mainnet ===");
        console2.log("USDC (existing):", KAVA_USDC);
        console2.log("ZeroExAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

contract DeployPolygon is GasTankExecutorSetup {
    // Polygon mainnet (chain 137)
    address constant POLYGON_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // Circle native USDC (6 decimals)
    // 0x Swap API v2 AllowanceHolder. The legacy Exchange Proxy (0xDef1C0de...) is NOT usable any
    // more: the /swap/v1 endpoint that produced its calldata is sunset (404), so v2 + AllowanceHolder
    // is the only route that still yields executable swap data.
    address constant POLYGON_ZERO_EX_ROUTER = 0x0000000000001fF3684f28c67538d4D072C22734;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(POLYGON_USDC, POLYGON_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), POLYGON_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(POLYGON_USDC);
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake Polygon Mainnet ===");
        console2.log("USDC (existing):", POLYGON_USDC);
        console2.log("ZeroExAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

contract DeploySonic is GasTankExecutorSetup {
    // Sonic mainnet (chain 146)
    address constant SONIC_USDC = 0x29219dd400f2Bf60E5a23d13Be72B486D4038894;
    // 0x Swap API v2 uses the shared AllowanceHolder entrypoint on Sonic.
    address constant SONIC_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(SONIC_USDC, SONIC_ALLOWANCE_HOLDER);
        DCAVault vault = new DCAVault(address(adapter), SONIC_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(SONIC_USDC);
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake Sonic Mainnet ===");
        console2.log("USDC (existing):", SONIC_USDC);
        console2.log("AllowanceHolder:", SONIC_ALLOWANCE_HOLDER);
        console2.log("ZeroExAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

/// @notice BOT Chain mainnet (chain 677). No 0x aggregator; swaps route through BDEX V2 (Uniswap V2 fork).
/// @dev The chain's stablecoin is bridged USDT (6 decimals) — it takes the vault's "USDC" slot.
contract DeployBotMainnet is GasTankExecutorSetup {
    address constant BOT_USDT = 0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C; // 6 decimals
    address constant BOT_BDEX_V2_ROUTER02 = 0x1414eD29FdFD322c3c0a830330ed982E2D629e76;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        UniV2SwapAdapter adapter = new UniV2SwapAdapter(BOT_USDT, BOT_BDEX_V2_ROUTER02);
        DCAVault vault = new DCAVault(address(adapter), BOT_USDT);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(BOT_USDT);
        gasTank.setGasCostPerExecution(50000); // $0.05 per execution (BOT Chain)
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake BOT Chain Mainnet (677) ===");
        console2.log("USDT (stable):", BOT_USDT);
        console2.log("BDEX V2 Router02:", BOT_BDEX_V2_ROUTER02);
        console2.log("UniV2SwapAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

/// @notice BOT Chain testnet (chain 968). Same shape as mainnet, against the testnet BDEX V2 deployment.
/// @dev Uses the real testnet USDT + real BDEX liquidity (not mocks), so the testnet run exercises
///      the same code path as mainnet. Get tBOT for gas at https://faucet.botchain.ai/basic.
contract DeployBotTestnet is GasTankExecutorSetup {
    address constant BOT_TESTNET_USDT = 0x75edC9335175Fc0552D51D48439F229c10420fe3; // 6 decimals
    address constant BOT_TESTNET_BDEX_V2_ROUTER02 = 0xD6425a02f0845B8D99e349C34D2E7A576E177345;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        UniV2SwapAdapter adapter = new UniV2SwapAdapter(BOT_TESTNET_USDT, BOT_TESTNET_BDEX_V2_ROUTER02);
        DCAVault vault = new DCAVault(address(adapter), BOT_TESTNET_USDT);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(BOT_TESTNET_USDT);
        gasTank.setGasCostPerExecution(50000); // $0.05 per execution (BOT Chain)
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        // Auto-execution: first plan per user free; additional plans pay a fee (10 USDT on testnet)
        vault.setAdditionalAutoPlanFeeUsdc6(10e6);
        vault.setAutoPlanFeeRecipient(msg.sender);

        vm.stopBroadcast();

        console2.log("=== SteadyStake BOT Chain Testnet (968) ===");
        console2.log("USDT (stable):", BOT_TESTNET_USDT);
        console2.log("BDEX V2 Router02:", BOT_TESTNET_BDEX_V2_ROUTER02);
        console2.log("UniV2SwapAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

/**
 * @notice BOT Chain testnet (968): self-contained mock stack — MockUSDC + MockSwapRouter.
 * @dev Use this instead of `DeployBotTestnet` when you have no bridged testnet USDT. The
 * faucet (https://faucet.botchain.ai/basic) only dispenses tBOT for gas, and BDEX testnet
 * liquidity is thin, so the real-USDT deployment is hard to exercise end to end. Here the
 * vault settles in a mintable MockUSDC and swaps through MockSwapRouter's fixed rates,
 * which needs no external liquidity at all. `--legacy` is still required: BOT Chain uses
 * type-0 gas pricing.
 */
contract DeployBotTestnetWithMockUSDC is GasTankExecutorSetup {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockUSDC usdc = new MockUSDC();
        MockAERO aero = new MockAERO();
        MockSwapRouter swapRouter = new MockSwapRouter(address(usdc));
        DCAVault vault = new DCAVault(address(swapRouter), address(usdc));
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(address(usdc));
        gasTank.setGasCostPerExecution(50000); // $0.05 per execution, matching DeployBotTestnet
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        // Auto-execution: first plan per user free; additional plans pay a fee (10 USDC on testnet)
        vault.setAdditionalAutoPlanFeeUsdc6(10e6);
        vault.setAutoPlanFeeRecipient(msg.sender);

        // Seed the deployer to test with, and the router so it can pay out swaps.
        usdc.mint(msg.sender, 10000e6);
        aero.mint(msg.sender, 10000e18);
        aero.mint(address(swapRouter), 100_000e18);

        vm.stopBroadcast();

        console2.log("=== SteadyStake BOT Chain Testnet (968, MockUSDC) ===");
        console2.log("MockUSDC:", address(usdc));
        console2.log("MockAERO:", address(aero));
        console2.log("SwapRouter:", address(swapRouter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

/// @notice Ethereum Sepolia (chain 11155111): USDC + 0x Exchange Proxy
contract DeployEthSepolia is GasTankExecutorSetup {
    // ETH Sepolia: Chainlink CCIP USDC (6 decimals)
    address constant ETH_SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant ETH_SEPOLIA_ZERO_EX_ROUTER = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(ETH_SEPOLIA_USDC, ETH_SEPOLIA_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), ETH_SEPOLIA_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(ETH_SEPOLIA_USDC);
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vm.stopBroadcast();

        console2.log("=== SteadyStake Ethereum Sepolia ===");
        console2.log("USDC (existing):", ETH_SEPOLIA_USDC);
        console2.log("ZeroExAdapter:", address(adapter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

/// @notice Ethereum Sepolia (chain 11155111): deploy new MockUSDC + full stack (MockSwapRouter, DCAVault, DCAResolver, GasTank)
contract DeployEthSepoliaWithMockUSDC is GasTankExecutorSetup {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockUSDC usdc = new MockUSDC();
        MockAERO aero = new MockAERO();
        MockSwapRouter swapRouter = new MockSwapRouter(address(usdc));
        DCAVault vault = new DCAVault(address(swapRouter), address(usdc));
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(address(usdc));
        gasTank.setGasCostPerExecution(10000); // $0.01 per execution (ETH Sepolia)
        _wireExecutor(gasTank);
        vault.setGasTank(address(gasTank));

        vault.setAdditionalAutoPlanFeeUsdc6(10e6);
        vault.setAutoPlanFeeRecipient(msg.sender);

        usdc.mint(msg.sender, 10000e6);
        aero.mint(msg.sender, 10000e18);
        aero.mint(address(swapRouter), 100_000e18);

        vm.stopBroadcast();

        console2.log("=== SteadyStake Ethereum Sepolia (MockUSDC) ===");
        console2.log("MockUSDC:", address(usdc));
        console2.log("MockAERO:", address(aero));
        console2.log("SwapRouter:", address(swapRouter));
        console2.log("DCAVault:", address(vault));
        console2.log("DCAResolver:", address(resolver));
        console2.log("GasTank:", address(gasTank));
    }
}

/// @notice Deploy only GasTank on Base Sepolia (uses existing USDC). Keeps existing DCAVault/Resolver.
contract DeployGasTankBaseSepolia is GasTankExecutorSetup {
    address constant BASE_SEPOLIA_USDC = 0x74C0cdB54B5bEB5fCf1073B8f1f6c583381c44D6;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        GasTank gasTank = new GasTank(BASE_SEPOLIA_USDC);
        gasTank.setGasCostPerExecution(5000); // $0.005 per execution (Base Sepolia)
        _wireExecutor(gasTank);

        vm.stopBroadcast();

        console2.log("=== GasTank Base Sepolia ===");
        console2.log("USDC (existing):", BASE_SEPOLIA_USDC);
        console2.log("GasTank:", address(gasTank));
    }
}

// Helper for console logging
import {console2} from "forge-std/console2.sol";
