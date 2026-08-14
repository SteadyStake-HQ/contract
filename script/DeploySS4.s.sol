// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {SS4Token} from "../src/token/SS4Token.sol";
import {SS4Presale} from "../src/sale/SS4Presale.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice Deploys `SS4Token` and `SS4Presale` together, funds the sale from the Investors
 *         pool, and freezes the sale configuration (outline §30 steps 3, 5, 6).
 *
 * @dev    TESTNET REHEARSAL SCRIPT. This must not be pointed at a production chain as-is:
 *         it defaults every allocation recipient to the deployer EOA, which §3.3 and §22.1
 *         forbid for a real launch ("never mint the entire supply to a deployer EOA").
 *         A mainnet run requires the six predeployed vault/multisig addresses, the audited
 *         code, and every §29 blocker resolved. The script refuses to run on a chain id
 *         that is not explicitly allowlisted below, so a mistyped --rpc-url cannot put
 *         real supply somewhere unintended.
 *
 *         Required env:
 *           PRIVATE_KEY          deployer key
 *           SS4_TOTAL_SUPPLY     fixed total supply in base units (§29 blocker #2)
 *           SS4_PRICE_USD_E6     presale price, USD scaled by 1e6 (25000 = $0.025)
 *           SS4_SALE_ALLOCATION  SS4 base units carved out for the sale, from Investors (§3.2)
 *           SS4_PAYMENT_TOKEN    exact allowlisted stablecoin address on this chain
 *           SS4_HARD_CAP_USD_E6  hard cap in USD*1e6
 *
 *         Optional env:
 *           SS4_TOKEN_NAME       default "SteadyStake" (§5.2 recommends it; confirm)
 *           SS4_SOFT_CAP_USD_E6  default 0 (no soft cap / no cancellation threshold)
 *           SS4_MIN_BUY_USD_E6   default 0
 *           SS4_WALLET_CAP_USD_E6 default 0 (uncapped)
 *           SS4_SALE_START       unix seconds; default block.timestamp (opens immediately)
 *           SS4_SALE_DURATION    seconds; default 14 days
 *           SS4_CLAIM_START      unix seconds; default saleEnd
 *           SS4_TGE_BPS          default 10000 (full unlock at claim, no vesting)
 *           SS4_ADMIN            presale admin; default deployer
 *           DRY_RUN              "true" to simulate and print without broadcasting (§28.5)
 */
contract DeploySS4 is Script {
    /// Chains this rehearsal script is permitted to touch. BOT Chain testnet only.
    uint256 internal constant BOT_TESTNET = 968;

    struct Params {
        string name;
        uint256 totalSupply;
        uint256 saleAllocation;
        uint256 priceUsdE6;
        address paymentToken;
        uint8 paymentDecimals;
        uint64 saleStart;
        uint64 saleEnd;
        uint64 claimStart;
        uint16 tgeBps;
        uint256 minBuyUsdE6;
        uint256 walletCapUsdE6;
        uint256 softCapUsdE6;
        uint256 hardCapUsdE6;
        address admin;
        address deployer;
    }

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool dryRun = vm.envOr("DRY_RUN", false);

        require(
            block.chainid == BOT_TESTNET,
            "DeploySS4: refusing to run on a chain that is not BOT Chain testnet (968)"
        );

        Params memory p = _readParams(deployer);
        _logPlan(p);

        if (dryRun) {
            console2.log("");
            console2.log("DRY_RUN=true -- nothing was broadcast.");
            return;
        }

        vm.startBroadcast(pk);

        // §30 step 3: mint the six fixed allocations directly to their final recipients.
        // On this testnet rehearsal every recipient is the deployer; see the contract note.
        SS4Token token = new SS4Token(
            p.name,
            "SS4",
            p.totalSupply,
            SS4Token.Allocations({
                community: deployer,
                team: deployer,
                investors: deployer,
                treasury: deployer,
                liquidity: deployer,
                ecosystem: deployer
            })
        );

        // §30 step 5: the presale is always deployed second — it takes the token address.
        SS4Presale presale = new SS4Presale(address(token), p.admin);

        if (p.admin == deployer) {
            presale.setPaymentToken(p.paymentToken, p.paymentDecimals, true);
            presale.configure(
                SS4Presale.SaleConfig({
                    saleAllocation: p.saleAllocation,
                    priceUsdE6: p.priceUsdE6,
                    saleStart: p.saleStart,
                    saleEnd: p.saleEnd,
                    claimStart: p.claimStart,
                    claimDeadline: 0,
                    tgeUnlockBps: p.tgeBps,
                    vestCliffSeconds: 0,
                    vestDurationSeconds: 0,
                    minPurchaseUsdE6: p.minBuyUsdE6,
                    maxPurchasePerWalletUsdE6: p.walletCapUsdE6,
                    softCapUsdE6: p.softCapUsdE6,
                    hardCapUsdE6: p.hardCapUsdE6
                })
            );

            // Fund the sale out of the Investors pool (§3.2) before freezing: the freeze
            // itself asserts the inventory is present, so this ordering is required.
            token.transfer(address(presale), p.saleAllocation);

            // §30 step 6.
            presale.freezeConfiguration();
        }

        vm.stopBroadcast();

        _logResult(token, presale, p);
    }

    function _readParams(address deployer) internal view returns (Params memory p) {
        p.deployer = deployer;
        p.name = vm.envOr("SS4_TOKEN_NAME", string("SteadyStake"));
        p.totalSupply = vm.envUint("SS4_TOTAL_SUPPLY");
        p.saleAllocation = vm.envUint("SS4_SALE_ALLOCATION");
        p.priceUsdE6 = vm.envUint("SS4_PRICE_USD_E6");
        p.paymentToken = vm.envAddress("SS4_PAYMENT_TOKEN");
        p.hardCapUsdE6 = vm.envUint("SS4_HARD_CAP_USD_E6");
        p.admin = vm.envOr("SS4_ADMIN", deployer);

        // §28.7: reject every TBD placeholder rather than deploying a zeroed economy.
        require(p.totalSupply != 0, "SS4_TOTAL_SUPPLY unset");
        require(p.saleAllocation != 0, "SS4_SALE_ALLOCATION unset");
        require(p.priceUsdE6 != 0, "SS4_PRICE_USD_E6 unset");
        require(p.paymentToken != address(0), "SS4_PAYMENT_TOKEN unset");
        require(p.hardCapUsdE6 != 0, "SS4_HARD_CAP_USD_E6 unset");

        // The sale must fit inside the Investors pool it is carved from (§3.2).
        uint256 investorPool = (p.totalSupply * 1500) / 10000;
        require(p.saleAllocation <= investorPool, "sale allocation exceeds the Investors 15% pool");

        p.paymentDecimals = IERC20Metadata(p.paymentToken).decimals();

        p.saleStart = uint64(vm.envOr("SS4_SALE_START", block.timestamp));
        p.saleEnd = p.saleStart + uint64(vm.envOr("SS4_SALE_DURATION", uint256(14 days)));
        p.claimStart = uint64(vm.envOr("SS4_CLAIM_START", uint256(p.saleEnd)));
        p.tgeBps = uint16(vm.envOr("SS4_TGE_BPS", uint256(10_000)));
        p.minBuyUsdE6 = vm.envOr("SS4_MIN_BUY_USD_E6", uint256(0));
        p.walletCapUsdE6 = vm.envOr("SS4_WALLET_CAP_USD_E6", uint256(0));
        p.softCapUsdE6 = vm.envOr("SS4_SOFT_CAP_USD_E6", uint256(0));

        // Cross-check the inventory against the cap so the two cannot disagree silently:
        // inventory * price is the most the sale could ever take in.
        uint256 inventoryValueUsdE6 = (p.saleAllocation * p.priceUsdE6) / 1e18;
        require(inventoryValueUsdE6 >= p.hardCapUsdE6, "hard cap exceeds what the inventory can sell");
    }

    function _logPlan(Params memory p) internal pure {
        console2.log("=== $SS4 deployment plan (BOT Chain testnet, 968) ===");
        console2.log("token name:      ", p.name);
        console2.log("total supply:    ", p.totalSupply);
        console2.log("sale allocation: ", p.saleAllocation);
        console2.log("price usdE6:     ", p.priceUsdE6);
        console2.log("payment token:   ", p.paymentToken);
        console2.log("payment decimals:", p.paymentDecimals);
        console2.log("sale start:      ", p.saleStart);
        console2.log("sale end:        ", p.saleEnd);
        console2.log("claim start:     ", p.claimStart);
        console2.log("tge bps:         ", p.tgeBps);
        console2.log("min buy usdE6:   ", p.minBuyUsdE6);
        console2.log("wallet cap usdE6:", p.walletCapUsdE6);
        console2.log("soft cap usdE6:  ", p.softCapUsdE6);
        console2.log("hard cap usdE6:  ", p.hardCapUsdE6);
        console2.log("admin:           ", p.admin);
    }

    function _logResult(SS4Token token, SS4Presale presale, Params memory p) internal view {
        console2.log("");
        console2.log("=== deployed ===");
        console2.log("SS4Token:   ", address(token));
        console2.log("SS4Presale: ", address(presale));
        console2.log("configFrozen:", presale.configFrozen());
        console2.log("presale SS4 balance:", token.balanceOf(address(presale)));
        console2.log("sale state (0=Configured,1=Active,2=Ended):", uint8(presale.state()));
        if (p.admin != p.deployer) {
            console2.log("NOTE: admin != deployer -> the admin must configure, fund, and freeze the sale.");
        }
    }
}
