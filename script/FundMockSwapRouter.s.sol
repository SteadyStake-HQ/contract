// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * Fund an already-deployed MockSwapRouter on Base Sepolia with output tokens
 * so it can fulfill USDC -> AERO/DEGEN/cbETH swaps.
 * Run: forge script script/FundMockSwapRouter.s.sol:FundMockSwapRouterBaseSepolia --rpc-url <BASE_SEPOLIA_RPC> --broadcast
 */
contract FundMockSwapRouterBaseSepolia is Script {
    // Base Sepolia deployed addresses (must match frontend/config/contracts.ts BASE_SEPOLIA_TOKENS)
    address constant ROUTER = 0x31E7944eF2e5D9f9bEcf60bBfB2ED1CD93D4685e;
    address constant MOCK_AERO = 0xE17D603EbD845AF1da46269A1F01512Bc18d3928;
    address constant MOCK_DEGEN = 0x45ADdb2ecB6E510F62cB4Ed84E0329470D72032D;
    address constant MOCK_CBETH = 0x40132aD82ff25D738f8C699D137E45011149B36B;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        IMintable(MOCK_AERO).mint(ROUTER, 100_000e18);
        IMintable(MOCK_DEGEN).mint(ROUTER, 100_000e18);
        IMintable(MOCK_CBETH).mint(ROUTER, 1_000e18);

        vm.stopBroadcast();
        console2.log("Funded MockSwapRouter at", ROUTER);
    }
}
