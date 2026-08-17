// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {SS4PresaleV3} from "../src/sale/SS4PresaleV3.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice Deploys `SS4PresaleV3` against an ALREADY DEPLOYED `SS4Token`, funds both the sale
 *         allocation and the Early Supporter Campaign's boost reserve, grants the backend's
 *         campaign signer, and freezes the configuration.
 *
 * @dev    Why this does not deploy a token, unlike `DeploySS4.s.sol`: `$SS4` has a fixed supply
 *         minted once at construction (§5). The campaign is a change to how the sale distributes
 *         tokens, not to the token itself, so re-running the token deploy would create a second,
 *         unrelated supply and silently orphan every balance and allocation already on chain. The
 *         token address is required input here.
 *
 *         WHY A FRESH DEPLOYMENT RATHER THAN A CONFIGURATION CHANGE. `configure()` and
 *         `configureCampaign()` are atomic and one-way (§7.5), and the live v2 sale is frozen. There
 *         is no call that turns v2's three fixed bonus rates into v3's variable boost, so a campaign
 *         change costs an address. Every superseded sale stays on chain, stays frozen, and is not
 *         migrated — record the new address in deployed-ss4-contracts.json and move the presale
 *         page's env to it, as the previous five rehearsals did.
 *
 *         TESTNET REHEARSAL SCRIPT — chain-gated to BOT Chain testnet (968) so a mistyped --rpc-url
 *         cannot put a live sale somewhere unintended. A mainnet run needs the audited code, a
 *         multisig admin, and every §29 blocker resolved.
 *
 *         Required env:
 *           PRIVATE_KEY             deployer key, holding the SS4 to fund the sale
 *           SS4_TOKEN_ADDRESS       the existing $SS4 ERC-20
 *           SS4_PAYMENT_TOKEN       allowlisted stablecoin on this chain
 *           SS4_PRICE_USD_E6        4000 = $0.004
 *           SS4_SALE_ALLOCATION     SS4 base units for sale
 *           SS4_HARD_CAP_USD_E6     hard cap, USD*1e6
 *           SS4_BONUS_ALLOCATION    SS4 base units reserved for campaign boosts
 *           SS4_CAMPAIGN_SIGNER     address whose signatures attest an earned boost
 *
 *         Optional env:
 *           SS4_MAX_BOOST_BPS       default 550 (the published +5.50% campaign maximum)
 *           SS4_SALE_START          unix seconds; default now
 *           SS4_SALE_DURATION       seconds; default 14 days
 *           SS4_CLAIM_START         unix seconds; default saleEnd
 *           SS4_TGE_BPS             default 10000 (full unlock, no vesting)
 *           SS4_MIN_BUY_USD_E6      default 0
 *           SS4_WALLET_CAP_USD_E6   default 0 (uncapped)
 *           SS4_SOFT_CAP_USD_E6     default 0
 *           SS4_ADMIN               default deployer
 *           DRY_RUN                 "true" to simulate without broadcasting (§28.5)
 */
contract DeploySS4PresaleV3 is Script {
    uint256 internal constant BOT_TESTNET = 968;

    /// @dev The campaign the spec publishes: +5.50% maximum across its three sections.
    uint16 internal constant DEFAULT_MAX_BOOST_BPS = 550;

    struct Params {
        address token;
        address paymentToken;
        uint8 paymentDecimals;
        uint256 saleAllocation;
        uint256 bonusAllocation;
        uint256 priceUsdE6;
        uint64 saleStart;
        uint64 saleEnd;
        uint64 claimStart;
        uint16 tgeBps;
        uint256 minBuyUsdE6;
        uint256 walletCapUsdE6;
        uint256 softCapUsdE6;
        uint256 hardCapUsdE6;
        uint16 maxBoostBps;
        address campaignSigner;
        address admin;
        address deployer;
    }

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool dryRun = vm.envOr("DRY_RUN", false);

        require(
            block.chainid == BOT_TESTNET,
            "DeploySS4PresaleV3: refusing to run on a chain that is not BOT Chain testnet (968)"
        );

        Params memory p = _readParams(deployer);
        _logPlan(p);

        if (dryRun) {
            console2.log("");
            console2.log("DRY_RUN=true -- nothing was broadcast.");
            return;
        }

        vm.startBroadcast(pk);

        SS4PresaleV3 presale = new SS4PresaleV3(p.token, p.admin);

        if (p.admin == deployer) {
            presale.setPaymentToken(p.paymentToken, p.paymentDecimals, true);
            _configure(presale, p);

            // The signer is granted before the freeze so the campaign is complete at the moment the
            // terms become immutable. It is a role, not a frozen parameter, so it stays rotatable
            // afterwards — a hot key must be replaceable without redeploying the sale.
            presale.grantRole(presale.CAMPAIGN_SIGNER_ROLE(), p.campaignSigner);

            // Both pools, in one transfer, before the freeze: `freezeConfiguration` asserts the
            // contract holds saleAllocation + bonusAllocation, so this ordering is required rather
            // than merely conventional.
            IERC20(p.token).transfer(address(presale), p.saleAllocation + p.bonusAllocation);

            presale.freezeConfiguration();
        }

        vm.stopBroadcast();

        _logResult(presale, p);
    }

    /// @dev Split out purely to keep `run()` under the stack limit.
    function _configure(SS4PresaleV3 presale, Params memory p) internal {
        presale.configure(
            SS4PresaleV3.SaleConfig({
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

        presale.configureCampaign(
            SS4PresaleV3.CampaignConfig({
                bonusAllocation: p.bonusAllocation,
                maxCampaignBoostBps: p.maxBoostBps
            })
        );
    }

    function _readParams(address deployer) internal view returns (Params memory p) {
        p.deployer = deployer;
        p.token = vm.envAddress("SS4_TOKEN_ADDRESS");
        p.paymentToken = vm.envAddress("SS4_PAYMENT_TOKEN");
        p.saleAllocation = vm.envUint("SS4_SALE_ALLOCATION");
        p.bonusAllocation = vm.envUint("SS4_BONUS_ALLOCATION");
        p.priceUsdE6 = vm.envUint("SS4_PRICE_USD_E6");
        p.hardCapUsdE6 = vm.envUint("SS4_HARD_CAP_USD_E6");
        p.campaignSigner = vm.envAddress("SS4_CAMPAIGN_SIGNER");
        p.admin = vm.envOr("SS4_ADMIN", deployer);

        // §28.7: reject every TBD placeholder rather than deploying a zeroed economy.
        require(p.token != address(0), "SS4_TOKEN_ADDRESS unset");
        require(p.paymentToken != address(0), "SS4_PAYMENT_TOKEN unset");
        require(p.saleAllocation != 0, "SS4_SALE_ALLOCATION unset");
        require(p.priceUsdE6 != 0, "SS4_PRICE_USD_E6 unset");
        require(p.hardCapUsdE6 != 0, "SS4_HARD_CAP_USD_E6 unset");
        // A campaign with no signer could never pay the boost it publishes.
        require(p.campaignSigner != address(0), "SS4_CAMPAIGN_SIGNER unset");

        p.paymentDecimals = IERC20Metadata(p.paymentToken).decimals();

        p.maxBoostBps = uint16(vm.envOr("SS4_MAX_BOOST_BPS", uint256(DEFAULT_MAX_BOOST_BPS)));
        // The pair is refused by `configureCampaign` too; caught here so the run aborts before gas.
        require(
            (p.bonusAllocation == 0) == (p.maxBoostBps == 0),
            "SS4_BONUS_ALLOCATION and SS4_MAX_BOOST_BPS must be set or cleared together"
        );

        p.saleStart = uint64(vm.envOr("SS4_SALE_START", block.timestamp));
        p.saleEnd = p.saleStart + uint64(vm.envOr("SS4_SALE_DURATION", uint256(14 days)));
        p.claimStart = uint64(vm.envOr("SS4_CLAIM_START", uint256(p.saleEnd)));
        p.tgeBps = uint16(vm.envOr("SS4_TGE_BPS", uint256(10_000)));
        p.minBuyUsdE6 = vm.envOr("SS4_MIN_BUY_USD_E6", uint256(0));
        p.walletCapUsdE6 = vm.envOr("SS4_WALLET_CAP_USD_E6", uint256(0));
        p.softCapUsdE6 = vm.envOr("SS4_SOFT_CAP_USD_E6", uint256(0));

        // The deployer has to be able to fund BOTH pools, or the freeze fails after the contract is
        // already on chain. Checked here so the run aborts before spending gas.
        uint256 required = p.saleAllocation + p.bonusAllocation;
        uint256 held = IERC20(p.token).balanceOf(deployer);
        require(held >= required, "deployer holds less SS4 than saleAllocation + bonusAllocation");

        // Inventory * price is the most the sale could ever take in; the cap must fit inside it.
        uint256 inventoryValueUsdE6 = (p.saleAllocation * p.priceUsdE6) / 1e18;
        require(inventoryValueUsdE6 >= p.hardCapUsdE6, "hard cap exceeds what the inventory can sell");
    }

    function _logPlan(Params memory p) internal pure {
        console2.log("=== SS4PresaleV3 deployment plan (BOT Chain testnet, 968) ===");
        console2.log("token:            ", p.token);
        console2.log("payment token:    ", p.paymentToken);
        console2.log("payment decimals: ", p.paymentDecimals);
        console2.log("sale allocation:  ", p.saleAllocation);
        console2.log("bonus allocation: ", p.bonusAllocation);
        console2.log("price usdE6:      ", p.priceUsdE6);
        console2.log("sale start:       ", p.saleStart);
        console2.log("sale end:         ", p.saleEnd);
        console2.log("claim start:      ", p.claimStart);
        console2.log("min buy usdE6:    ", p.minBuyUsdE6);
        console2.log("wallet cap usdE6: ", p.walletCapUsdE6);
        console2.log("soft cap usdE6:   ", p.softCapUsdE6);
        console2.log("hard cap usdE6:   ", p.hardCapUsdE6);
        console2.log("--- Early Supporter Campaign ---");
        console2.log("max boost bps:    ", p.maxBoostBps);
        console2.log("campaign signer:  ", p.campaignSigner);
        console2.log("admin:            ", p.admin);

        // The worst case a single boost rate can demand: every token sold at the published maximum.
        // Under-reserving is legal (awards clamp) but it should be a decision, not a surprise.
        uint256 worstCase = (p.saleAllocation * p.maxBoostBps) / 10_000;
        console2.log("worst-case boost demand:", worstCase);
        if (worstCase > p.bonusAllocation) {
            console2.log("NOTE: reserve is below the worst case -- awards will clamp once it is spent.");
        }
    }

    function _logResult(SS4PresaleV3 presale, Params memory p) internal view {
        console2.log("");
        console2.log("=== deployed ===");
        console2.log("SS4PresaleV3:  ", address(presale));
        console2.log("configFrozen:  ", presale.configFrozen());
        console2.log("presale SS4:   ", IERC20(p.token).balanceOf(address(presale)));
        console2.log("bonusRemaining:", presale.bonusRemaining());
        console2.log("maxBoostBps:   ", presale.maxCampaignBoostBps());
        console2.log("sale state (0=Configured,1=Active,2=Ended):", uint8(presale.state()));
        console2.log("domainSeparator (the backend must sign under this):");
        console2.logBytes32(presale.domainSeparator());
        console2.log("configHash:");
        console2.logBytes32(presale.configHash());
        console2.log("");
        console2.log("Backend env: SS4_PRESALE_ADDRESS_968, SS4_CAMPAIGN_SIGNER_KEY");
        console2.log("Presale env: NEXT_PUBLIC_PRESALE_ADDRESS, NEXT_PUBLIC_PRESALE_VERSION=3");
        if (p.admin != p.deployer) {
            console2.log("NOTE: admin != deployer -> the admin must configure, fund, and freeze the sale.");
        }
    }
}
