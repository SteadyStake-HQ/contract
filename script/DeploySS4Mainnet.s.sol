// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {SS4Token} from "../src/token/SS4Token.sol";
import {SS4PresaleV3} from "../src/sale/SS4PresaleV3.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice The production launch: deploys `SS4Token` and `SS4PresaleV3` to BOT Chain mainnet (677),
 *         funds both the sale allocation and the Early Supporter Campaign's boost reserve, grants
 *         the backend's campaign signer, and freezes the configuration.
 *
 * @dev    WHY THIS EXISTS ALONGSIDE THE TWO REHEARSAL SCRIPTS. `DeploySS4.s.sol` and
 *         `DeploySS4PresaleV3.s.sol` are both hard-gated to chain 968, deliberately, so a mistyped
 *         `--rpc-url` cannot put real supply somewhere unintended. Relaxing either guard would
 *         delete that protection for every future rehearsal, so mainnet gets its own script with
 *         the mirror-image guard: this one refuses to run anywhere EXCEPT 677.
 *
 *         WHY TOKEN AND SALE TOGETHER, UNLIKE THE V3 REHEARSAL SCRIPT. On testnet the token already
 *         existed, so the V3 script took its address as input. Mainnet has neither, and `$SS4` has a
 *         fixed supply minted once in the constructor (§5) — there is no second chance to mint. One
 *         script means the token and the sale that carves out of it are created in a single
 *         broadcast, so a half-finished launch cannot leave a supply on chain with no sale behind
 *         it.
 *
 *         ORDERING IS LOAD-BEARING, not stylistic. `freezeConfiguration()` asserts the contract
 *         already holds `saleAllocation + bonusAllocation`, so the funding transfer must precede it.
 *         The campaign signer is granted before the freeze so the campaign is complete at the moment
 *         the terms become immutable — though the role itself stays rotatable afterwards, because a
 *         hot key must be replaceable without redeploying the sale.
 *
 *         A SALE START IN THE PAST IS INTENTIONAL AND LEGAL. `configure()` validates only that
 *         `saleStart != 0`, `saleStart < saleEnd` and `claimStart >= saleEnd`; it does not require a
 *         future start. Deploying after the published window opens therefore makes the sale Active
 *         the moment the freeze confirms, which is the correct behaviour for a launch that slipped
 *         past its own opening bell — not a reason to move the published dates.
 *
 *         §7.5 CONFIGURATION IS ATOMIC AND ONE-WAY. Once frozen, no call can reprice, reschedule or
 *         re-cap this sale; every correction costs a fresh address. Run with `DRY_RUN=true` first
 *         and read the printed plan against the published terms line by line.
 *
 *         Required env:
 *           PRIVATE_KEY             deployer key, funded with BOT for gas
 *           SS4_TOTAL_SUPPLY        fixed total supply in base units
 *           SS4_PAYMENT_TOKEN       the settlement stablecoin on this chain (BOT Chain: USDT, 6 dec)
 *           SS4_PRICE_USD_E6        4000 = $0.004
 *           SS4_SALE_ALLOCATION     SS4 base units for sale, carved from the Investors pool (§3.2)
 *           SS4_BONUS_ALLOCATION    SS4 base units reserved for campaign boosts
 *           SS4_HARD_CAP_USD_E6     hard cap, USD*1e6
 *           SS4_CAMPAIGN_SIGNER     address whose signatures attest an earned boost
 *
 *         Allocation recipients — each defaults to the deployer, and every one of them is
 *         permanent. §3.3 wants six predeployed controlled destinations here:
 *           SS4_COMMUNITY, SS4_TEAM, SS4_INVESTORS, SS4_TREASURY, SS4_LIQUIDITY, SS4_ECOSYSTEM
 *
 *         Optional env:
 *           SS4_TOKEN_NAME          default "SteadyStake"
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
contract DeploySS4Mainnet is Script {
    uint256 internal constant BOT_MAINNET = 677;

    /// @dev The campaign the spec publishes: +5.50% maximum across its three sections.
    uint16 internal constant DEFAULT_MAX_BOOST_BPS = 550;

    struct Params {
        string name;
        uint256 totalSupply;
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
            block.chainid == BOT_MAINNET,
            "DeploySS4Mainnet: refusing to run on a chain that is not BOT Chain mainnet (677)"
        );

        Params memory p = _readParams(deployer);
        SS4Token.Allocations memory recipients = _readRecipients(deployer);

        _logPlan(p);
        _logRecipients(recipients, p);

        if (dryRun) {
            console2.log("");
            console2.log("DRY_RUN=true -- nothing was broadcast.");
            return;
        }

        vm.startBroadcast(pk);

        // §30 step 3: the six fixed allocations are minted here, once, and never again.
        SS4Token token = new SS4Token(p.name, "SS4", p.totalSupply, recipients);

        // §30 step 5: the sale is always deployed second — it takes the token address.
        SS4PresaleV3 presale = new SS4PresaleV3(address(token), p.admin);

        if (p.admin == deployer) {
            presale.setPaymentToken(p.paymentToken, p.paymentDecimals, true);
            _configure(presale, p);

            // Granted before the freeze so the campaign is complete the moment the terms become
            // immutable. Still a role, not a frozen parameter, so it stays rotatable afterwards.
            presale.grantRole(presale.CAMPAIGN_SIGNER_ROLE(), p.campaignSigner);

            // Both pools in one transfer, before the freeze: `freezeConfiguration` asserts the
            // contract holds saleAllocation + bonusAllocation, so this ordering is required rather
            // than merely conventional.
            //
            // The sale is funded from whichever recipient holds the Investors pool (§3.2). When that
            // is not the deployer, the transfer below has nothing to send and the deploy stops here
            // with the sale unfrozen — see the guard in `_readParams`.
            IERC20(address(token)).transfer(address(presale), p.saleAllocation + p.bonusAllocation);

            presale.freezeConfiguration();
        }

        vm.stopBroadcast();

        _logResult(token, presale, p);
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
            SS4PresaleV3.CampaignConfig({bonusAllocation: p.bonusAllocation, maxCampaignBoostBps: p.maxBoostBps})
        );
    }

    /**
     * @dev §3.3 asks for six predeployed, controlled destinations. Each defaults to the deployer so
     *      a launch is not blocked on six vaults existing, but the default is loud in the printed
     *      plan rather than silent — minting the whole supply to one EOA is a decision, and it is
     *      permanent: the token has no mint function, no owner and no migration path.
     */
    function _readRecipients(address deployer) internal view returns (SS4Token.Allocations memory a) {
        a.community = vm.envOr("SS4_COMMUNITY", deployer);
        a.team = vm.envOr("SS4_TEAM", deployer);
        a.investors = vm.envOr("SS4_INVESTORS", deployer);
        a.treasury = vm.envOr("SS4_TREASURY", deployer);
        a.liquidity = vm.envOr("SS4_LIQUIDITY", deployer);
        a.ecosystem = vm.envOr("SS4_ECOSYSTEM", deployer);
    }

    function _readParams(address deployer) internal view returns (Params memory p) {
        p.deployer = deployer;
        p.name = vm.envOr("SS4_TOKEN_NAME", string("SteadyStake"));
        p.totalSupply = vm.envUint("SS4_TOTAL_SUPPLY");
        p.paymentToken = vm.envAddress("SS4_PAYMENT_TOKEN");
        p.saleAllocation = vm.envUint("SS4_SALE_ALLOCATION");
        p.bonusAllocation = vm.envUint("SS4_BONUS_ALLOCATION");
        p.priceUsdE6 = vm.envUint("SS4_PRICE_USD_E6");
        p.hardCapUsdE6 = vm.envUint("SS4_HARD_CAP_USD_E6");
        p.campaignSigner = vm.envAddress("SS4_CAMPAIGN_SIGNER");
        p.admin = vm.envOr("SS4_ADMIN", deployer);

        // §28.7: reject every TBD placeholder rather than deploying a zeroed economy.
        require(p.totalSupply != 0, "SS4_TOTAL_SUPPLY unset");
        require(p.paymentToken != address(0), "SS4_PAYMENT_TOKEN unset");
        require(p.saleAllocation != 0, "SS4_SALE_ALLOCATION unset");
        require(p.priceUsdE6 != 0, "SS4_PRICE_USD_E6 unset");
        require(p.hardCapUsdE6 != 0, "SS4_HARD_CAP_USD_E6 unset");
        // A campaign with no signer could never pay the boost it publishes.
        require(p.campaignSigner != address(0), "SS4_CAMPAIGN_SIGNER unset");

        // Read from the token rather than trusted from env: every amount the sale quotes is scaled
        // by this, so a wrong value misprices the entire raise.
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

        // The sale must fit inside the Investors pool it is carved from (§3.2). Both pools come out
        // of that 15%, so the campaign reserve counts against it too.
        uint256 investorPool = (p.totalSupply * 1500) / 10_000;
        require(
            p.saleAllocation + p.bonusAllocation <= investorPool,
            "sale + bonus allocation exceeds the Investors 15% pool"
        );

        // Inventory * price is the most the sale could ever take in; the cap must fit inside it.
        uint256 inventoryValueUsdE6 = (p.saleAllocation * p.priceUsdE6) / 1e18;
        require(inventoryValueUsdE6 >= p.hardCapUsdE6, "hard cap exceeds what the inventory can sell");

        // Funding comes from the Investors recipient. If that is not the deployer, the transfer in
        // `run()` would revert after the token and sale are already on chain — an unrecoverable
        // half-launch, since the token cannot be redeployed to the same supply. Abort before gas.
        if (p.admin == deployer) {
            require(
                vm.envOr("SS4_INVESTORS", deployer) == deployer,
                "SS4_INVESTORS must be the deployer, or the deployer cannot fund the sale before the freeze"
            );
        }
    }

    function _logPlan(Params memory p) internal view {
        console2.log("=== $SS4 MAINNET deployment plan (BOT Chain, 677) ===");
        console2.log("token name:       ", p.name);
        console2.log("total supply:     ", p.totalSupply);
        console2.log("payment token:    ", p.paymentToken);
        console2.log("payment decimals: ", p.paymentDecimals);
        console2.log("sale allocation:  ", p.saleAllocation);
        console2.log("bonus allocation: ", p.bonusAllocation);
        console2.log("price usdE6:      ", p.priceUsdE6);
        console2.log("sale start:       ", p.saleStart);
        console2.log("sale end:         ", p.saleEnd);
        console2.log("claim start:      ", p.claimStart);
        console2.log("tge bps:          ", p.tgeBps);
        console2.log("min buy usdE6:    ", p.minBuyUsdE6);
        console2.log("wallet cap usdE6: ", p.walletCapUsdE6);
        console2.log("soft cap usdE6:   ", p.softCapUsdE6);
        console2.log("hard cap usdE6:   ", p.hardCapUsdE6);
        console2.log("--- Early Supporter Campaign ---");
        console2.log("max boost bps:    ", p.maxBoostBps);
        console2.log("campaign signer:  ", p.campaignSigner);
        console2.log("admin:            ", p.admin);
        console2.log("block.timestamp:  ", block.timestamp);

        // A start already behind us is legal and means "open on freeze". Say so explicitly, because
        // the alternative reading — a mistyped date — looks identical in the numbers above.
        if (p.saleStart <= block.timestamp) {
            console2.log("NOTE: saleStart is in the past -> the sale is ACTIVE the moment the freeze confirms.");
        }

        // The worst case a single boost rate can demand: every token sold at the published maximum.
        // Under-reserving is legal (awards clamp) but it should be a decision, not a surprise.
        uint256 worstCase = (p.saleAllocation * p.maxBoostBps) / 10_000;
        console2.log("worst-case boost demand:", worstCase);
        if (worstCase > p.bonusAllocation) {
            console2.log("NOTE: reserve is below the worst case -- awards will clamp once it is spent.");
        }
    }

    function _logRecipients(SS4Token.Allocations memory a, Params memory p) internal pure {
        console2.log("--- allocation recipients (PERMANENT: no mint, no owner, no migration) ---");
        console2.log("community 35%:", a.community);
        console2.log("team      15%:", a.team);
        console2.log("investors 15%:", a.investors);
        console2.log("treasury  15%:", a.treasury);
        console2.log("liquidity 10%:", a.liquidity);
        console2.log("ecosystem 10%:", a.ecosystem);

        if (
            a.community == p.deployer && a.team == p.deployer && a.investors == p.deployer
                && a.treasury == p.deployer && a.liquidity == p.deployer && a.ecosystem == p.deployer
        ) {
            console2.log("WARNING: every pool mints to the deployer EOA, which is what 3.3 and 22.1 forbid.");
            console2.log("         The supply is transferable afterwards, but the mint events and");
            console2.log("         allocationRecipients() record this address permanently.");
        }
    }

    function _logResult(SS4Token token, SS4PresaleV3 presale, Params memory p) internal view {
        console2.log("");
        console2.log("=== deployed ===");
        console2.log("SS4Token:      ", address(token));
        console2.log("SS4PresaleV3:  ", address(presale));
        console2.log("configFrozen:  ", presale.configFrozen());
        console2.log("presale SS4:   ", token.balanceOf(address(presale)));
        console2.log("bonusRemaining:", presale.bonusRemaining());
        console2.log("maxBoostBps:   ", presale.maxCampaignBoostBps());
        console2.log("sale state (0=Configured,1=Active,2=Ended):", uint8(presale.state()));
        console2.log("domainSeparator (the backend must sign under this):");
        console2.logBytes32(presale.domainSeparator());
        console2.log("configHash:");
        console2.logBytes32(presale.configHash());
        console2.log("");
        console2.log("Backend env: CAMPAIGN_CHAIN_ID=677, SS4_CAMPAIGN_SIGNER_KEY");
        console2.log("Presale env: NEXT_PUBLIC_PRESALE_CHAIN_ID=677, NEXT_PUBLIC_PRESALE_ADDRESS");
        if (p.admin != p.deployer) {
            console2.log("NOTE: admin != deployer -> the admin must configure, fund, and freeze the sale.");
        }
    }
}
