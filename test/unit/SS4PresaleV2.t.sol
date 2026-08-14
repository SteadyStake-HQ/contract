// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {SS4PresaleV2} from "../../src/sale/SS4PresaleV2.sol";
import {MockUSDC, MockToken} from "../../src/MockTokens.sol";

/**
 * @dev Covers only what v2 adds. The sale mechanics it inherits by fork — pricing, caps,
 *      lifecycle, refunds, hostile tokens — are exercised against the identical code in
 *      `SS4Presale.t.sol`; repeating them here would be 900 lines that pass for reasons
 *      already established. What is NOT already established, and is tested here, is that
 *      the bonus accounting cannot break those invariants: that awarded bonuses are owed
 *      inventory a treasury cannot recover, that they vest and claim like purchases, and
 *      that no campaign path can revert a purchase or mint past the reserve.
 */
contract SS4PresaleV2Test is Test {
    SS4PresaleV2 internal sale;
    MockToken internal ss4;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal referrer = makeAddr("referrer");
    address internal treasury = makeAddr("treasury");

    /// The backend's campaign signer, as a key this test can actually sign with.
    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    uint64 internal constant SALE_START = 1_786_924_800; // 2026-08-17T00:00:00Z
    uint64 internal constant SALE_END = 1_788_134_400; // 2026-08-31T00:00:00Z, exclusive
    uint64 internal constant CLAIM_START = 1_788_220_800; // 2026-09-01T00:00:00Z

    uint256 internal constant PRICE_USD_E6 = 25_000; // $0.025 per SS4
    uint256 internal constant ALLOCATION = 20_000_000e18;
    uint256 internal constant HARD_CAP = 500_000e6;

    // The campaign as the presale publishes it: 2% social, 3% holding, 10% referral,
    // 1 BOT to qualify, and a reserve at the full 15% worst case of the allocation.
    uint256 internal constant BONUS_ALLOCATION = 3_000_000e18; // 15% of ALLOCATION
    uint16 internal constant SOCIAL_BPS = 200;
    uint16 internal constant HOLD_BPS = 300;
    uint16 internal constant REFERRAL_BPS = 1_000;
    uint256 internal constant HOLD_WEI = 1e18;

    /// $1,000 at $0.025 = 40,000 SS4. Every expectation below is derived from this.
    uint256 internal constant BUY_USDC = 1_000e6;
    uint256 internal constant BUY_SS4 = 40_000e18;

    event CampaignBonusAccrued(address indexed buyer, uint256 socialSs4, uint256 holdSs4);
    event ReferralAccrued(address indexed referrer, address indexed buyer, uint256 ss4Amount);
    event ReferrerBound(address indexed buyer, address indexed referrer);
    event BonusReserveShort(uint256 requested, uint256 granted);

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.warp(SALE_START - 7 days);

        ss4 = new MockToken("SteadyStake", "SS4", 18);
        usdc = new MockUSDC();

        sale = _deployAndFreeze(BONUS_ALLOCATION);

        _fundBuyer(buyer);
        _fundBuyer(buyer2);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _saleConfig() internal pure returns (SS4PresaleV2.SaleConfig memory) {
        return SS4PresaleV2.SaleConfig({
            saleAllocation: ALLOCATION,
            priceUsdE6: PRICE_USD_E6,
            saleStart: SALE_START,
            saleEnd: SALE_END,
            claimStart: CLAIM_START,
            claimDeadline: 0,
            tgeUnlockBps: 10_000,
            vestCliffSeconds: 0,
            vestDurationSeconds: 0,
            minPurchaseUsdE6: 0,
            maxPurchasePerWalletUsdE6: 0,
            softCapUsdE6: 0,
            hardCapUsdE6: HARD_CAP
        });
    }

    function _campaignConfig(uint256 bonusAllocation) internal pure returns (SS4PresaleV2.CampaignConfig memory) {
        return SS4PresaleV2.CampaignConfig({
            bonusAllocation: bonusAllocation,
            socialBonusBps: SOCIAL_BPS,
            holdBonusBps: HOLD_BPS,
            referralBonusBps: REFERRAL_BPS,
            holdRequirementWei: HOLD_WEI
        });
    }

    function _deployAndFreeze(uint256 bonusAllocation) internal returns (SS4PresaleV2 deployed) {
        deployed = new SS4PresaleV2(address(ss4), admin);

        vm.startPrank(admin);
        deployed.setPaymentToken(address(usdc), 6, true);
        deployed.configure(_saleConfig());
        deployed.configureCampaign(_campaignConfig(bonusAllocation));
        deployed.grantRole(deployed.CAMPAIGN_SIGNER_ROLE(), signer);
        vm.stopPrank();

        ss4.mint(address(deployed), ALLOCATION + bonusAllocation);

        vm.prank(admin);
        deployed.freezeConfiguration();
    }

    function _fundBuyer(address who) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(address(sale), type(uint256).max);
    }

    /// A voucher for `who`, signed by `key`, valid for an hour.
    function _voucher(address who, uint256 key) internal view returns (uint64 deadline, bytes memory signature) {
        deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = sale.campaignVoucherDigest(who, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _openSale() internal {
        vm.warp(SALE_START + 1);
    }

    // =====================================================================
    // Social bonus — the signed half
    // =====================================================================

    function test_socialBonus_grantsPublishedRate() public {
        _openSale();
        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);

        vm.expectEmit(true, false, false, true);
        emit CampaignBonusAccrued(buyer, (BUY_SS4 * SOCIAL_BPS) / 10_000, 0);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), deadline, sig);

        assertEq(sale.campaignBonusSs4(buyer), 800e18, "2% of 40,000 SS4");
        assertEq(sale.purchasedSs4(buyer), BUY_SS4, "the purchase itself is untouched");
    }

    function test_socialBonus_notGrantedWithoutVoucher() public {
        _openSale();
        vm.prank(buyer);
        sale.buy(address(usdc), BUY_USDC, 0);

        assertEq(sale.campaignBonusSs4(buyer), 0);
    }

    function test_socialBonus_expiredVoucherReverts() public {
        _openSale();
        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(SS4PresaleV2.VoucherExpired.selector, deadline));
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), deadline, sig);
    }

    function test_socialBonus_foreignSignerReverts() public {
        _openSale();
        (uint64 deadline, bytes memory sig) = _voucher(buyer, 0xBEEF); // not granted the role

        vm.expectRevert(SS4PresaleV2.InvalidVoucher.selector);
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), deadline, sig);
    }

    /// A voucher is bound to one wallet: buyer2 cannot present the one issued to buyer.
    function test_socialBonus_voucherIsNotTransferable() public {
        _openSale();
        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);

        vm.expectRevert(SS4PresaleV2.InvalidVoucher.selector);
        vm.prank(buyer2);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), deadline, sig);
    }

    /// The break-glass path: bumping the epoch invalidates every voucher already issued.
    function test_socialBonus_epochBumpInvalidatesOutstandingVouchers() public {
        _openSale();
        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);

        vm.prank(admin);
        sale.bumpCampaignEpoch();

        vm.expectRevert(SS4PresaleV2.InvalidVoucher.selector);
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), deadline, sig);
    }

    function test_bumpCampaignEpoch_onlyAdmin() public {
        vm.expectRevert();
        vm.prank(buyer);
        sale.bumpCampaignEpoch();
    }

    // =====================================================================
    // Holding bonus — the trustless half
    // =====================================================================

    function test_holdBonus_grantedAtThreshold() public {
        _openSale();
        vm.deal(buyer, HOLD_WEI);

        vm.prank(buyer);
        sale.buy(address(usdc), BUY_USDC, 0);

        assertEq(sale.campaignBonusSs4(buyer), 1_200e18, "3% of 40,000 SS4");
    }

    function test_holdBonus_notGrantedBelowThreshold() public {
        _openSale();
        vm.deal(buyer, HOLD_WEI - 1);

        vm.prank(buyer);
        sale.buy(address(usdc), BUY_USDC, 0);

        assertEq(sale.campaignBonusSs4(buyer), 0);
    }

    /// Both tiers on one purchase: 2% + 3% = 5%.
    function test_bonuses_stack() public {
        _openSale();
        vm.deal(buyer, 10 ether);
        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), deadline, sig);

        assertEq(sale.campaignBonusSs4(buyer), 2_000e18, "5% of 40,000 SS4");
    }

    // =====================================================================
    // Referral
    // =====================================================================

    function test_referral_creditsReferrerNotReferee() public {
        _openSale();

        vm.expectEmit(true, true, false, true);
        emit ReferrerBound(buyer, referrer);
        vm.expectEmit(true, true, false, true);
        emit ReferralAccrued(referrer, buyer, (BUY_SS4 * REFERRAL_BPS) / 10_000);

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        assertEq(sale.referralBonusSs4(referrer), 4_000e18, "10% of 40,000 SS4");
        assertEq(sale.purchasedSs4(buyer), BUY_SS4, "referee's own tokens are not reduced");
        assertEq(sale.campaignBonusSs4(buyer), 0, "a referral is not a campaign bonus");
        assertEq(sale.referrerOf(buyer), referrer);
        assertEq(sale.referralCount(referrer), 1);
    }

    function test_referral_selfReferralReverts() public {
        _openSale();
        vm.expectRevert(SS4PresaleV2.SelfReferral.selector);
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, buyer);
    }

    /// Attribution is set once. A second link cannot move an existing relationship.
    function test_referral_bindingIsSticky() public {
        _openSale();

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, buyer2);

        assertEq(sale.referrerOf(buyer), referrer, "still the original referrer");
        assertEq(sale.referralBonusSs4(buyer2), 0, "the late link earns nothing");
        assertEq(sale.referralBonusSs4(referrer), 8_000e18, "and keeps earning on repeat buys");
        assertEq(sale.referralCount(referrer), 1, "one referee, not one per purchase");
    }

    /// A bound referrer keeps earning even when the caller stops passing the argument.
    function test_referral_boundReferrerEarnsOnPlainBuy() public {
        _openSale();

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        vm.prank(buyer);
        sale.buy(address(usdc), BUY_USDC, 0);

        assertEq(sale.referralBonusSs4(referrer), 8_000e18);
    }

    function test_referral_zeroAddressIsNoReferral() public {
        _openSale();
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, address(0));

        assertEq(sale.referrerOf(buyer), address(0));
        assertEq(sale.bonusAwarded(), 0);
    }

    // =====================================================================
    // The reserve is a hard ceiling
    // =====================================================================

    /**
     * The property that matters most: when the marketing budget is gone the sale keeps
     * selling. A campaign that could revert a purchase would turn a spent reserve into an
     * outage.
     */
    function test_reserve_exhaustedPurchaseStillSucceeds() public {
        // A reserve deliberately too small for one full referral award.
        SS4PresaleV2 small = _deployTinyReserve(1_000e18);
        _openSale();

        vm.startPrank(buyer);
        usdc.approve(address(small), type(uint256).max);

        vm.expectEmit(false, false, false, true);
        emit BonusReserveShort((BUY_SS4 * REFERRAL_BPS) / 10_000, 1_000e18);
        small.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        // And a second purchase, with nothing left at all, still goes through.
        small.buy(address(usdc), BUY_USDC, 0);
        vm.stopPrank();

        assertEq(small.referralBonusSs4(referrer), 1_000e18, "clamped to the reserve");
        assertEq(small.bonusAwarded(), 1_000e18, "never exceeds the reserve");
        assertEq(small.bonusRemaining(), 0);
        assertEq(small.purchasedSs4(buyer), BUY_SS4 * 2, "both purchases landed");
    }

    function test_reserve_neverOverAwardsAcrossManyBuyers() public {
        SS4PresaleV2 small = _deployTinyReserve(5_000e18);
        _openSale();

        for (uint256 i; i < 10; ++i) {
            address who = address(uint160(0xB0B0 + i));
            usdc.mint(who, BUY_USDC);
            vm.deal(who, 10 ether); // every one of them qualifies for the holding bonus
            vm.startPrank(who);
            usdc.approve(address(small), type(uint256).max);
            small.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);
            vm.stopPrank();
        }

        assertEq(small.bonusAwarded(), 5_000e18, "exactly the reserve, not a wei more");
        assertEq(small.bonusRemaining(), 0);
    }

    function _deployTinyReserve(uint256 reserve) internal returns (SS4PresaleV2 deployed) {
        deployed = new SS4PresaleV2(address(ss4), admin);
        vm.startPrank(admin);
        deployed.setPaymentToken(address(usdc), 6, true);
        deployed.configure(_saleConfig());
        deployed.configureCampaign(_campaignConfig(reserve));
        deployed.grantRole(deployed.CAMPAIGN_SIGNER_ROLE(), signer);
        vm.stopPrank();
        ss4.mint(address(deployed), ALLOCATION + reserve);
        vm.prank(admin);
        deployed.freezeConfiguration();
    }

    // =====================================================================
    // Funding, claiming and recovery must all count bonuses as real inventory
    // =====================================================================

    function test_freeze_requiresBonusReserveToBeFunded() public {
        SS4PresaleV2 underfunded = new SS4PresaleV2(address(ss4), admin);
        vm.startPrank(admin);
        underfunded.setPaymentToken(address(usdc), 6, true);
        underfunded.configure(_saleConfig());
        underfunded.configureCampaign(_campaignConfig(BONUS_ALLOCATION));
        vm.stopPrank();

        // Sale allocation only — the campaign has nothing behind it.
        ss4.mint(address(underfunded), ALLOCATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                SS4PresaleV2.InventoryNotFunded.selector, ALLOCATION + BONUS_ALLOCATION, ALLOCATION
            )
        );
        vm.prank(admin);
        underfunded.freezeConfiguration();
    }

    function test_claim_paysPurchasePlusBothBonuses() public {
        _openSale();
        vm.deal(buyer, 10 ether);
        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, referrer, deadline, sig);

        vm.warp(SALE_END + 1);
        vm.prank(admin);
        sale.finalize();
        vm.warp(CLAIM_START + 1);

        // 40,000 purchased + 2,000 campaign (5%) = 42,000
        assertEq(sale.totalEntitlement(buyer), 42_000e18);
        vm.prank(buyer);
        sale.claim();
        assertEq(ss4.balanceOf(buyer), 42_000e18);

        // The referrer bought nothing and still claims their 10%.
        vm.prank(referrer);
        sale.claim();
        assertEq(ss4.balanceOf(referrer), 4_000e18);
    }

    /**
     * A treasury must not be able to recover inventory that is owed as a bonus. This is
     * the invariant the whole `outstandingEntitlement` change exists to preserve.
     */
    function test_recoverUnsoldTokens_cannotTakeAwardedBonuses() public {
        _openSale();
        vm.deal(buyer, 10 ether);

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);
        // 40,000 sold, 1,200 hold bonus + 4,000 referral = 5,200 awarded.

        vm.warp(SALE_END + 1);
        vm.prank(admin);
        sale.finalize();

        uint256 held = ss4.balanceOf(address(sale));
        uint256 owed = 40_000e18 + 5_200e18;
        assertEq(sale.outstandingEntitlement(), owed);
        assertEq(sale.recoverableSs4(), held - owed);

        vm.prank(admin);
        sale.recoverUnsoldTokens(treasury);

        // Everything still owed is still here, and both parties can still claim it.
        assertEq(ss4.balanceOf(address(sale)), owed);
        vm.warp(CLAIM_START + 1);
        vm.prank(buyer);
        sale.claim();
        vm.prank(referrer);
        sale.claim();
        assertEq(ss4.balanceOf(address(sale)), 0, "exact, with no dust stranded");
    }

    function test_refund_zeroesCampaignBonus() public {
        _openSale();
        vm.deal(buyer, 10 ether);

        vm.prank(buyer);
        sale.buy(address(usdc), BUY_USDC, 0);
        assertEq(sale.campaignBonusSs4(buyer), 1_200e18);

        vm.prank(admin);
        sale.cancelSale(keccak256("TEST"));

        vm.prank(buyer);
        sale.refund();

        assertEq(sale.campaignBonusSs4(buyer), 0);
        assertEq(sale.totalEntitlement(buyer), 0);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6, "stablecoins came back in full");
    }

    /// Vesting applies to the whole entitlement, bonuses included, on one schedule.
    function test_vesting_appliesToBonuses() public {
        SS4PresaleV2 vested = new SS4PresaleV2(address(ss4), admin);
        SS4PresaleV2.SaleConfig memory cfg = _saleConfig();
        cfg.tgeUnlockBps = 5_000; // half at TGE
        cfg.vestDurationSeconds = 100 days;

        vm.startPrank(admin);
        vested.setPaymentToken(address(usdc), 6, true);
        vested.configure(cfg);
        vested.configureCampaign(_campaignConfig(BONUS_ALLOCATION));
        vm.stopPrank();
        ss4.mint(address(vested), ALLOCATION + BONUS_ALLOCATION);
        vm.prank(admin);
        vested.freezeConfiguration();

        _openSale();
        vm.deal(buyer, 10 ether);
        vm.startPrank(buyer);
        usdc.approve(address(vested), type(uint256).max);
        vested.buy(address(usdc), BUY_USDC, 0); // 40,000 + 1,200 hold bonus
        vm.stopPrank();

        vm.warp(SALE_END + 1);
        vm.prank(admin);
        vested.finalize();
        vm.warp(CLAIM_START);

        assertEq(vested.claimable(buyer), 20_600e18, "half of 41,200, bonus included");
    }

    // =====================================================================
    // Campaign configuration validation
    // =====================================================================

    function test_configureCampaign_rejectsRateAboveCeiling() public {
        SS4PresaleV2 fresh = new SS4PresaleV2(address(ss4), admin);
        SS4PresaleV2.CampaignConfig memory cfg = _campaignConfig(BONUS_ALLOCATION);
        cfg.referralBonusBps = 2_001;

        vm.expectRevert(SS4PresaleV2.InvalidBonusRate.selector);
        vm.prank(admin);
        fresh.configureCampaign(cfg);
    }

    function test_configureCampaign_rejectsRatesWithNoReserve() public {
        SS4PresaleV2 fresh = new SS4PresaleV2(address(ss4), admin);
        SS4PresaleV2.CampaignConfig memory cfg = _campaignConfig(0);

        vm.expectRevert(SS4PresaleV2.InvalidBonusRate.selector);
        vm.prank(admin);
        fresh.configureCampaign(cfg);
    }

    /// A holding rate with no threshold would pay every wallet; the pair moves together.
    function test_configureCampaign_rejectsHoldRateWithoutThreshold() public {
        SS4PresaleV2 fresh = new SS4PresaleV2(address(ss4), admin);
        SS4PresaleV2.CampaignConfig memory cfg = _campaignConfig(BONUS_ALLOCATION);
        cfg.holdRequirementWei = 0;

        vm.expectRevert(SS4PresaleV2.InvalidBonusRate.selector);
        vm.prank(admin);
        fresh.configureCampaign(cfg);
    }

    function test_configureCampaign_rejectedAfterFreeze() public {
        vm.expectRevert(SS4PresaleV2.ConfigAlreadyFrozen.selector);
        vm.prank(admin);
        sale.configureCampaign(_campaignConfig(BONUS_ALLOCATION));
    }

    /// A campaign-free sale is a valid configuration, not an incomplete one.
    function test_configureCampaign_zeroEverythingIsValid() public {
        SS4PresaleV2 plain = new SS4PresaleV2(address(ss4), admin);
        vm.startPrank(admin);
        plain.setPaymentToken(address(usdc), 6, true);
        plain.configure(_saleConfig());
        plain.configureCampaign(
            SS4PresaleV2.CampaignConfig({
                bonusAllocation: 0,
                socialBonusBps: 0,
                holdBonusBps: 0,
                referralBonusBps: 0,
                holdRequirementWei: 0
            })
        );
        vm.stopPrank();
        ss4.mint(address(plain), ALLOCATION);
        vm.prank(admin);
        plain.freezeConfiguration();

        _openSale();
        vm.startPrank(buyer);
        usdc.approve(address(plain), type(uint256).max);
        plain.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);
        vm.stopPrank();

        assertEq(plain.bonusAwarded(), 0, "no reserve, no awards, no revert");
        assertEq(plain.purchasedSs4(buyer), BUY_SS4);
    }

    // =====================================================================
    // The UI quotes from the chain — so the chain's own quote must be right
    // =====================================================================

    function test_quoteBonus_matchesWhatABuyActuallyAwards() public {
        _openSale();
        vm.deal(buyer, 10 ether);

        // Bind a referrer first, so the referral leg of the quote is live.
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), 1e6, 0, referrer);

        uint256 beforeCampaign = sale.campaignBonusSs4(buyer);
        uint256 beforeReferral = sale.referralBonusSs4(referrer);

        (uint256 social, uint256 hold, uint256 referral) = sale.quoteBonus(buyer, BUY_SS4, true);

        (uint64 deadline, bytes memory sig) = _voucher(buyer, signerKey);
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, referrer, deadline, sig);

        assertEq(sale.campaignBonusSs4(buyer) - beforeCampaign, social + hold, "own bonuses");
        assertEq(sale.referralBonusSs4(referrer) - beforeReferral, referral, "referrer's cut");
    }

    function test_quoteBonus_reportsZeroHoldBelowThreshold() public {
        _openSale();
        vm.deal(buyer, HOLD_WEI - 1);
        (, uint256 hold,) = sale.quoteBonus(buyer, BUY_SS4, false);
        assertEq(hold, 0);
    }

    // =====================================================================
    // Fuzz: the reserve is the ceiling, whatever the purchase sizes
    // =====================================================================

    function testFuzz_bonusAwardedNeverExceedsReserve(uint96 a, uint96 b, uint96 c) public {
        _openSale();
        uint256[3] memory amounts = [uint256(a), uint256(b), uint256(c)];

        for (uint256 i; i < 3; ++i) {
            uint256 amount = bound(amounts[i], 1e6, 100_000e6);
            address who = address(uint160(0xF00D + i));
            usdc.mint(who, amount);
            vm.deal(who, 10 ether);
            vm.startPrank(who);
            usdc.approve(address(sale), type(uint256).max);
            // Hard cap is $500k and each buy is capped at $100k, so three always fit.
            sale.buyWithReferral(address(usdc), amount, 0, referrer);
            vm.stopPrank();
        }

        assertLe(sale.bonusAwarded(), BONUS_ALLOCATION);
        assertEq(sale.bonusAwarded() + sale.bonusRemaining(), BONUS_ALLOCATION);
    }
}
