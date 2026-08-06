// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {StablecoinGamePassCheckout} from "../src/StablecoinGamePassCheckout.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice Deploys one StablecoinGamePassCheckout for a payment network and seeds the beta pass
 *         plans (§5.1), priced in the stablecoin's own decimals.
 *
 * @dev    Testnet-first. Required env:
 *           PRIVATE_KEY        deployer key
 *           STABLECOIN_ADDRESS exact allowlisted stablecoin (USDC on Base, USDT on BOT, ...)
 *           TREASURY_ADDRESS   where pass revenue lands (kept apart from vault/gas capital, §24)
 *         Optional env:
 *           PASS_ADMIN         DEFAULT_ADMIN holder. Defaults to the deployer so this script can
 *                              seed plans in one broadcast. On mainnet, set it to the multisig and
 *                              re-grant/revoke admin afterwards (§24).
 *
 *         Plan ids: 1 = Day (24h/$0.99), 2 = Week (7d/$3.99), 3 = Month (30d/$9.99),
 *         4 = Hour (1h/$0.01, test only).
 *
 *         These must stay identical to PASS_PLANS in backend/src/payments/pass-plans.ts. The pass
 *         indexer activates a pass only when the PassPaid `amount` equals the amount the backend
 *         computed for the intent, so a price that differs here by one atomic unit takes the
 *         player's stablecoin and grants nothing.
 */
contract DeployGamePassCheckout is Script {
    uint8 internal constant PLAN_DAY = 1;
    uint8 internal constant PLAN_WEEK = 2;
    uint8 internal constant PLAN_MONTH = 3;
    /// Id 4 is retired: it was a $0.01 1-Hour test tier, removed from PASS_PLANS. Do not reuse it.

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address stablecoin = vm.envAddress("STABLECOIN_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        require(stablecoin != address(0), "STABLECOIN_ADDRESS unset");
        require(treasury != address(0), "TREASURY_ADDRESS unset");

        address admin = vm.envOr("PASS_ADMIN", deployer);

        // Price the passes in the token's real decimals so $0.99 is 990000 at 6dp and 0.99e18 at 18dp.
        uint8 decimals = IERC20Metadata(stablecoin).decimals();
        require(decimals >= 2, "stablecoin decimals < 2");
        uint256 unit = 10 ** (uint256(decimals) - 2); // one cent
        uint256 dayPrice = 99 * unit; // $0.99
        uint256 weekPrice = 399 * unit; // $3.99
        uint256 monthPrice = 999 * unit; // $9.99

        vm.startBroadcast(deployerPrivateKey);

        StablecoinGamePassCheckout checkout =
            new StablecoinGamePassCheckout(stablecoin, treasury, admin);

        // Only the admin may seed plans; possible in this broadcast only when admin == deployer.
        if (admin == deployer) {
            checkout.setPlan(PLAN_DAY, 1 days, dayPrice, true);
            checkout.setPlan(PLAN_WEEK, 7 days, weekPrice, true);
            checkout.setPlan(PLAN_MONTH, 30 days, monthPrice, true);
        }

        vm.stopBroadcast();

        console2.log("=== StablecoinGamePassCheckout ===");
        console2.log("checkout:  ", address(checkout));
        console2.log("stablecoin:", stablecoin);
        console2.log("treasury:  ", treasury);
        console2.log("admin:     ", admin);
        console2.log("decimals:  ", decimals);
        if (admin != deployer) {
            console2.log("NOTE: admin != deployer -> multisig must seed plans via setPlan().");
        }
    }
}
