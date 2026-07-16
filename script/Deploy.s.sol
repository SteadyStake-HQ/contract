// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {DCAResolver} from "../src/DCAResolver.sol";
import {GasTank} from "../src/GasTank.sol";
import {MockSwapRouter, ZeroExAdapter} from "../src/SwapHelper.sol";
import {MockUSDC, MockAERO, MockDEGEN, MockCBETH} from "../src/MockTokens.sol";
import {Constants} from "../src/Constants.sol";

contract DeployTestnet is Script {
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
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}

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

contract DeployMainnet is Script {
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
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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

contract DeployBNB is Script {
    // BNB Chain (BSC) mainnet addresses
    address constant BNB_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant BNB_ZERO_EX_ROUTER = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(BNB_USDC, BNB_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), BNB_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(BNB_USDC);
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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

contract DeployKava is Script {
    // Kava EVM mainnet (chain 2222)
    address constant KAVA_USDC = 0xfA9343C3897324496A05fC75abeD6bAC29f8A40f; // Multichain USDC (6 decimals)
    address constant KAVA_ZERO_EX_ROUTER = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x placeholder; swap may require 0x Kava support

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(KAVA_USDC, KAVA_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), KAVA_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(KAVA_USDC);
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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

contract DeployPolygon is Script {
    // Polygon mainnet (chain 137)
    address constant POLYGON_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // Circle native USDC (6 decimals)
    address constant POLYGON_ZERO_EX_ROUTER = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x Exchange Proxy

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ZeroExAdapter adapter = new ZeroExAdapter(POLYGON_USDC, POLYGON_ZERO_EX_ROUTER);
        DCAVault vault = new DCAVault(address(adapter), POLYGON_USDC);
        DCAResolver resolver = new DCAResolver(address(vault));
        GasTank gasTank = new GasTank(POLYGON_USDC);
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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

contract DeploySonic is Script {
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
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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

/// @notice Ethereum Sepolia (chain 11155111): USDC + 0x Exchange Proxy
contract DeployEthSepolia is Script {
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
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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
contract DeployEthSepoliaWithMockUSDC is Script {
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
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}
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
contract DeployGasTankBaseSepolia is Script {
    address constant BASE_SEPOLIA_USDC = 0x74C0cdB54B5bEB5fCf1073B8f1f6c583381c44D6;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        GasTank gasTank = new GasTank(BASE_SEPOLIA_USDC);
        gasTank.setGasCostPerExecution(5000); // $0.005 per execution (Base Sepolia)
        try vm.envAddress("RELAYER_ADDRESS") returns (address relayer) {
            if (relayer != address(0)) gasTank.setExecutor(relayer);
        } catch {}

        vm.stopBroadcast();

        console2.log("=== GasTank Base Sepolia ===");
        console2.log("USDC (existing):", BASE_SEPOLIA_USDC);
        console2.log("GasTank:", address(gasTank));
    }
}

// Helper for console logging
import {console2} from "forge-std/console2.sol";
