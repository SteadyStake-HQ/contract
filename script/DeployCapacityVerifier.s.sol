// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {AutoPlanCapacityVerifier} from "../src/AutoPlanCapacityVerifier.sol";

/**
 * @notice Deploys one AutoPlanCapacityVerifier per DCA network (§18.3). The EIP-712 domain
 *         name/version MUST match the backend capacity signer exactly, or every permit fails.
 *
 * @dev    Required env:
 *           PRIVATE_KEY     deployer key
 *           CAPACITY_SIGNER backend capacity-authorizer address granted SIGNER_ROLE (§16.2)
 *         Optional env:
 *           VERIFIER_ADMIN  DEFAULT_ADMIN holder; defaults to deployer for testnet, multisig on mainnet
 *           VAULT_ADDRESS   DCA vault granted VAULT_ROLE (the only caller of consumePermit).
 *                           May be left unset until the vault integration lands (Phase 6).
 *           EIP712_NAME     domain name  (default "Echo Arena Capacity")
 *           EIP712_VERSION  domain version (default "1")
 *
 *         Role grants happen in-broadcast only when admin == deployer; otherwise the multisig
 *         must grant SIGNER_ROLE / VAULT_ROLE after deployment.
 */
contract DeployCapacityVerifier is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address signer = vm.envAddress("CAPACITY_SIGNER");
        require(signer != address(0), "CAPACITY_SIGNER unset");

        address admin = vm.envOr("VERIFIER_ADMIN", deployer);
        address vault = vm.envOr("VAULT_ADDRESS", address(0));
        string memory name = vm.envOr("EIP712_NAME", string("Echo Arena Capacity"));
        string memory version = vm.envOr("EIP712_VERSION", string("1"));

        vm.startBroadcast(deployerPrivateKey);

        AutoPlanCapacityVerifier verifier = new AutoPlanCapacityVerifier(name, version, admin);

        if (admin == deployer) {
            verifier.grantRole(verifier.SIGNER_ROLE(), signer);
            if (vault != address(0)) {
                verifier.grantRole(verifier.VAULT_ROLE(), vault);
            }
        }

        vm.stopBroadcast();

        console2.log("=== AutoPlanCapacityVerifier ===");
        console2.log("verifier:", address(verifier));
        console2.log("admin:   ", admin);
        console2.log("signer:  ", signer);
        console2.log("vault:   ", vault);
        console2.log("domain:  ", name);
        if (admin != deployer) {
            console2.log("NOTE: admin != deployer -> multisig must grant SIGNER_ROLE / VAULT_ROLE.");
        }
    }
}
