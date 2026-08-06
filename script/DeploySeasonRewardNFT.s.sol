// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {SeasonRewardNFT} from "../src/SeasonRewardNFT.sol";

/**
 * @notice Deploys the SeasonRewardNFT soulbound reward collection. Canonical on Base (§13.1).
 *
 * @dev    Required env:
 *           PRIVATE_KEY deployer key
 *         Optional env:
 *           NFT_ADMIN   DEFAULT_ADMIN / finalizer / minter / pauser holder. Defaults to the
 *                       deployer for testnet; set to the multisig on mainnet (§18.2 / §24).
 */
contract DeploySeasonRewardNFT is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address admin = vm.envOr("NFT_ADMIN", deployer);

        vm.startBroadcast(deployerPrivateKey);
        SeasonRewardNFT nft = new SeasonRewardNFT(admin);
        vm.stopBroadcast();

        console2.log("=== SeasonRewardNFT ===");
        console2.log("nft:  ", address(nft));
        console2.log("admin:", admin);
    }
}
