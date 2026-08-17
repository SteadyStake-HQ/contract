// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {SS4PresaleV3} from "../../src/sale/SS4PresaleV3.sol";
import {MockUSDC, MockToken} from "../../src/MockTokens.sol";

/**
 * @dev Covers only what v3 changes. The sale mechanics it inherits by fork — pricing, caps,
 *      lifecycle, refunds, hostile tokens — are exercised against the identical code in
 *      `SS4Presale.t.sol`, and the bonus-reserve invariants against `SS4PresaleV2.t.sol`.
 *
 *      What is new and therefore tested here is the variable boost: that the rate a voucher
 *      carries is honoured exactly, that the frozen campaign maximum is a wall rather than a
 *      clamp, that a nonce is spendable once, that a v2-shaped voucher cannot be replayed
 *      into a v3 sale, and that the reserve still cannot be over-awarded or recovered out
 *      from under a buyer.
 */
contract SS4PresaleV3Test is Test {
    SS4PresaleV3 internal sale;
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
    /// A key that holds no role, for the forged-attestation cases.
    uint256 internal foreignKey = 0xB0B;

    uint64 internal constant SALE_START = 1_787_184_000; // 2026-08-20T00:00:00Z
    uint64 internal constant SALE_END = 1_788_393_600; // 2026-09-03T00:00:00Z, exclusive
    uint64 internal constant CLAIM_START = 1_788_480_000; // 2026-09-04T00:00:00Z

    uint256 internal constant PRICE_USD_E6 = 4_000; // $0.004 per SS4
    uint256 internal constant ALLOCATION = 50_000_000e18;
    uint256 internal constant HARD_CAP = 200_000e6;

    /// The campaign as the Early Supporter spec publishes it: a 5.50% ceiling over a funded reserve.
    uint256 internal constant BONUS_ALLOCATION = 3_000_000e18;
    uint16 internal constant MAX_BOOST_BPS = 550;

    /// $1,000 at $0.004 = 250,000 SS4. Every expectation below is derived from this pair.
    uint256 internal constant BUY_USDC = 1_000e6;
    uint256 internal constant BUY_SS4 = 250_000e18;

    event CampaignBoostAccrued(address indexed buyer, uint16 boostBps, uint64 nonce, uint256 ss4Amount);
    event ReferrerBound(address indexed buyer, address indexed referrer);
    event BonusReserveShort(uint256 requested, uint256 granted);

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.warp(SALE_START - 7 days);

        ss4 = new MockToken("SteadyStake", "SS4", 18);
        usdc = new MockUSDC();

        sale = _deployAndFreeze(BONUS_ALLOCATION, MAX_BOOST_BPS);

        _fundBuyer(buyer);
        _fundBuyer(buyer2);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _saleConfig() internal pure returns (SS4PresaleV3.SaleConfig memory) {
        return SS4PresaleV3.SaleConfig({
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

    function _deployAndFreeze(uint256 bonusAllocation, uint16 maxBoostBps) internal returns (SS4PresaleV3 deployed) {
        deployed = new SS4PresaleV3(address(ss4), admin);

        vm.startPrank(admin);
        deployed.setPaymentToken(address(usdc), 6, true);
        deployed.configure(_saleConfig());
        deployed.configureCampaign(
            SS4PresaleV3.CampaignConfig({bonusAllocation: bonusAllocation, maxCampaignBoostBps: maxBoostBps})
        );
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

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant VOUCHER_TYPEHASH =
        keccak256("CampaignVoucher(address buyer,uint16 boostBps,uint64 deadline,uint64 nonce,uint64 epoch)");

    /**
     * @dev The voucher digest, derived here from the EIP-712 spec rather than read back from
     *      `campaignVoucherDigest`. Two reasons, and the second is the load-bearing one:
     *
     *      1. It makes this suite an independent check on the contract's domain and type hash —
     *         a helper that asks the contract what to sign would agree with any encoding,
     *         including a wrong one. `test_campaignVoucherDigest_matchesTheSpec` ties the two.
     *      2. A helper that calls `sale` cannot be evaluated as an argument to a pranked call:
     *         the view call consumes the prank, `buyWithCampaign` then arrives from the test
     *         contract, and every voucher fails to verify for a reason that has nothing to do
     *         with the contract under test. `vm.sign` is a cheatcode and leaves a prank alone.
     */
    function _digest(address who, uint16 boostBps, uint64 deadline, uint64 nonce, uint64 epoch)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("SS4Presale"),
                keccak256("3"),
                block.chainid,
                address(sale)
            )
        );
        bytes32 structHash = keccak256(abi.encode(VOUCHER_TYPEHASH, who, boostBps, deadline, nonce, epoch));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /**
     * A voucher for `who` at `boostBps`, signed by `key`, valid for an hour.
     *
     * Signed at epoch 0 — a freshly deployed sale's epoch, and therefore every sale in this
     * suite. It is deliberately not read from the contract: that would be a call, with the
     * prank consequence described on `_digest`. The one test that bumps the epoch signs before
     * the bump and expects the resulting voucher to be refused, which is exactly right.
     */
    function _voucher(address who, uint16 boostBps, uint64 nonce, uint256 key)
        internal
        view
        returns (SS4PresaleV3.CampaignVoucher memory voucher)
    {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(who, boostBps, deadline, nonce, 0));
        voucher = SS4PresaleV3.CampaignVoucher({
            boostBps: boostBps,
            deadline: deadline,
            nonce: nonce,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// The backend's own voucher, at the campaign maximum.
    function _maxVoucher(address who, uint64 nonce) internal view returns (SS4PresaleV3.CampaignVoucher memory) {
        return _voucher(who, MAX_BOOST_BPS, nonce, signerKey);
    }

    function _openSale() internal {
        vm.warp(SALE_START + 1);
    }

    function _expectedBoost(uint16 boostBps) internal pure returns (uint256) {
        return (BUY_SS4 * boostBps) / 10_000;
    }

    // =====================================================================
    // The boost itself — a rate the voucher carries, not one the sale fixes
    // =====================================================================

    function test_boost_grantsExactlyTheAttestedRate() public {
        _openSale();

        vm.expectEmit(true, false, false, true);
        emit CampaignBoostAccrued(buyer, MAX_BOOST_BPS, 1, _expectedBoost(MAX_BOOST_BPS));

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        assertEq(sale.campaignBonusSs4(buyer), 13_750e18, "5.50% of 250,000 SS4");
        assertEq(sale.purchasedSs4(buyer), BUY_SS4, "the purchase itself is untouched");
        assertEq(sale.bonusAwarded(), 13_750e18);
    }

    /**
     * Every section total and every individual mission in the campaign spec, as a rate this
     * sale has to be able to pay to the basis point. 5 bps is the campaign's smallest step
     * (the +0.05% nothing pays today but the arithmetic must not round away), 10 the
     * first-game mission, 110/260/180 the three section maxima, 550 the published total.
     */
    function test_boost_everyPublishedRateIsPayableExactly() public {
        _openSale();
        uint16[7] memory rates = [5, 10, 20, 110, 180, 260, 550];

        for (uint256 i; i < rates.length; ++i) {
            address who = makeAddr(string(abi.encodePacked("rate", vm.toString(i))));
            _fundBuyer(who);

            vm.prank(who);
            sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _voucher(who, rates[i], 1, signerKey));

            assertEq(
                sale.campaignBonusSs4(who),
                _expectedBoost(rates[i]),
                string(abi.encodePacked("boost at ", vm.toString(rates[i]), " bps"))
            );
        }
    }

    function test_boost_zeroBpsVoucherIsValidAndAwardsNothing() public {
        _openSale();

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _voucher(buyer, 0, 1, signerKey));

        assertEq(sale.campaignBonusSs4(buyer), 0, "a wallet that earned nothing is awarded nothing");
        assertEq(sale.purchasedSs4(buyer), BUY_SS4, "but the purchase still lands");
        assertTrue(sale.voucherUsed(buyer, 1), "and the nonce is still burned");
    }

    function test_boost_plainBuyEarnsNothing() public {
        _openSale();
        vm.prank(buyer);
        sale.buy(address(usdc), BUY_USDC, 0);

        assertEq(sale.campaignBonusSs4(buyer), 0, "v3 has no on-chain-only bonus, unlike v2's holding tier");
    }

    // =====================================================================
    // The published maximum is a wall, not a clamp
    // =====================================================================

    function test_boost_aboveCampaignMaximumReverts() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory over = _voucher(buyer, MAX_BOOST_BPS + 1, 1, signerKey);

        vm.expectRevert(
            abi.encodeWithSelector(SS4PresaleV3.BoostAboveCampaignMaximum.selector, MAX_BOOST_BPS, MAX_BOOST_BPS + 1)
        );
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), over);
    }

    /**
     * The blast radius of a stolen signer key, asserted rather than argued. A key that signs
     * anything it likes still cannot exceed the rate the sale froze and published.
     */
    function test_boost_compromisedSignerCannotExceedThePublishedCampaign() public {
        _openSale();

        // Even the widest rate the type can carry is refused above the frozen ceiling.
        SS4PresaleV3.CampaignVoucher memory absurd = _voucher(buyer, type(uint16).max, 1, signerKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                SS4PresaleV3.BoostAboveCampaignMaximum.selector, MAX_BOOST_BPS, type(uint16).max
            )
        );
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), absurd);

        // And at the ceiling the worst case is bounded by the funded reserve.
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 2));
        assertLe(sale.bonusAwarded(), BONUS_ALLOCATION);
    }

    function test_quoteBoost_returnsZeroAboveTheMaximumRatherThanClamping() public {
        _openSale();
        assertEq(sale.quoteBoost(BUY_SS4, MAX_BOOST_BPS), _expectedBoost(MAX_BOOST_BPS));
        assertEq(sale.quoteBoost(BUY_SS4, MAX_BOOST_BPS + 1), 0, "a card must not quote what a buy would reject");
        assertEq(sale.quoteBoost(BUY_SS4, 0), 0);
    }

    function test_quoteBoost_matchesWhatABuyActuallyAwards() public {
        _openSale();
        uint256 quoted = sale.quoteBoost(BUY_SS4, 260);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _voucher(buyer, 260, 1, signerKey));

        assertEq(sale.campaignBonusSs4(buyer), quoted, "the card and the chain agree");
    }

    // =====================================================================
    // Voucher validity: signer, expiry, buyer binding, epoch, single use
    // =====================================================================

    function test_voucher_foreignSignerReverts() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory forged = _voucher(buyer, MAX_BOOST_BPS, 1, foreignKey);

        vm.expectRevert(SS4PresaleV3.InvalidVoucher.selector);
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), forged);
    }

    function test_voucher_expiredReverts() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory voucher = _maxVoucher(buyer, 1);
        vm.warp(voucher.deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(SS4PresaleV3.VoucherExpired.selector, voucher.deadline));
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), voucher);
    }

    function test_voucher_isNotTransferable() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory forBuyer = _maxVoucher(buyer, 1);

        vm.expectRevert(SS4PresaleV3.InvalidVoucher.selector);
        vm.prank(buyer2);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), forBuyer);
    }

    /**
     * The single-use rule, which is what stops one leaked voucher from boosting an unbounded
     * number of purchases inside its deadline.
     */
    function test_voucher_nonceIsSpendableOnce() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory voucher = _maxVoucher(buyer, 7);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), voucher);
        assertTrue(sale.voucherUsed(buyer, 7));

        vm.expectRevert(abi.encodeWithSelector(SS4PresaleV3.VoucherAlreadyUsed.selector, uint64(7)));
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), voucher);
    }

    function test_voucher_nonceSpaceIsPerWallet() public {
        _openSale();

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        // buyer2's nonce 1 is untouched by buyer having spent theirs.
        vm.prank(buyer2);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer2, 1));

        assertEq(sale.campaignBonusSs4(buyer2), _expectedBoost(MAX_BOOST_BPS));
    }

    /**
     * A reverted purchase must not consume the nonce — the wallet has to be able to retry the
     * voucher it was issued after fixing whatever the sale refused.
     */
    function test_voucher_nonceSurvivesAFailedPurchase() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory voucher = _maxVoucher(buyer, 1);

        // minSs4Out set impossibly high: the purchase reverts after the voucher was checked.
        vm.expectRevert(
            abi.encodeWithSelector(SS4PresaleV3.InsufficientOutput.selector, BUY_SS4 + 1, BUY_SS4)
        );
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0 + BUY_SS4 + 1, address(0), voucher);

        assertFalse(sale.voucherUsed(buyer, 1), "the whole transaction reverted, nonce included");

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), voucher);
        assertEq(sale.campaignBonusSs4(buyer), _expectedBoost(MAX_BOOST_BPS), "retry lands");
    }

    function test_voucher_epochBumpInvalidatesOutstandingVouchers() public {
        _openSale();
        SS4PresaleV3.CampaignVoucher memory issued = _maxVoucher(buyer, 1);

        vm.prank(admin);
        sale.bumpCampaignEpoch();

        vm.expectRevert(SS4PresaleV3.InvalidVoucher.selector);
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), issued);
    }

    function test_voucher_epochBumpDoesNotChangeThePublishedTerms() public {
        bytes32 before = sale.configHash();
        uint16 maxBefore = sale.maxCampaignBoostBps();

        vm.prank(admin);
        sale.bumpCampaignEpoch();

        assertEq(sale.configHash(), before, "the break-glass lever is not a config change");
        assertEq(sale.maxCampaignBoostBps(), maxBefore);
    }

    function test_bumpCampaignEpoch_onlyAdmin() public {
        vm.expectRevert();
        vm.prank(buyer);
        sale.bumpCampaignEpoch();
    }

    /**
     * A v2 voucher covers `(buyer, deadline, epoch)` and is signed under domain version "2".
     * Reproducing that digest here and presenting it must fail, so the two live sales cannot
     * be played against each other by a wallet holding an old attestation.
     */
    function test_voucher_v2ShapedAttestationCannotBeReplayed() public {
        _openSale();
        uint64 deadline = uint64(block.timestamp + 1 hours);

        bytes32 v2TypeHash = keccak256("CampaignVoucher(address buyer,uint64 deadline,uint64 epoch)");
        bytes32 structHash = keccak256(abi.encode(v2TypeHash, buyer, deadline, uint64(0)));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", sale.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        SS4PresaleV3.CampaignVoucher memory stale = SS4PresaleV3.CampaignVoucher({
            boostBps: MAX_BOOST_BPS,
            deadline: deadline,
            nonce: 1,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert(SS4PresaleV3.InvalidVoucher.selector);
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), stale);
    }

    /**
     * The contract's own digest against this suite's independent derivation from the EIP-712
     * spec. If these ever disagree, the backend signing against `campaignVoucherDigest` would
     * still work and every hand-built voucher in the world would not — so this is the assertion
     * that keeps the published type reproducible by anyone.
     */
    function test_campaignVoucherDigest_matchesTheSpec() public view {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        assertEq(
            sale.campaignVoucherDigest(buyer, 550, deadline, 42),
            _digest(buyer, 550, deadline, 42, 0),
            "domain and type hash reproduce byte for byte"
        );
    }

    function test_campaignVoucherDigest_isBoundToEveryField() public view {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 base = sale.campaignVoucherDigest(buyer, 550, deadline, 1);

        assertTrue(base != sale.campaignVoucherDigest(buyer2, 550, deadline, 1), "buyer");
        assertTrue(base != sale.campaignVoucherDigest(buyer, 540, deadline, 1), "boostBps");
        assertTrue(base != sale.campaignVoucherDigest(buyer, 550, deadline + 1, 1), "deadline");
        assertTrue(base != sale.campaignVoucherDigest(buyer, 550, deadline, 2), "nonce");
    }

    // =====================================================================
    // Referral — a record, and nothing more
    // =====================================================================

    function test_referral_bindsWithoutPayingAnybody() public {
        _openSale();

        vm.expectEmit(true, true, false, false);
        emit ReferrerBound(buyer, referrer);

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        assertEq(sale.referrerOf(buyer), referrer);
        assertEq(sale.referralCount(referrer), 1);
        assertEq(sale.campaignBonusSs4(referrer), 0, "the referrer is paid through their own voucher, not here");
        assertEq(sale.bonusAwarded(), 0, "and nothing left the reserve");
    }

    function test_referral_bindingIsSticky() public {
        _openSale();

        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        // A second purchase presenting a different link cannot move attribution.
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, buyer2);

        assertEq(sale.referrerOf(buyer), referrer);
        assertEq(sale.referralCount(buyer2), 0);
    }

    function test_referral_selfReferralReverts() public {
        _openSale();

        vm.expectRevert(SS4PresaleV3.SelfReferral.selector);
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, buyer);
    }

    function test_referral_selfReferralRevertsEvenOnceBound() public {
        _openSale();
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, referrer);

        vm.expectRevert(SS4PresaleV3.SelfReferral.selector);
        vm.prank(buyer);
        sale.buyWithReferral(address(usdc), BUY_USDC, 0, buyer);
    }

    function test_referral_zeroAddressIsNoReferral() public {
        _openSale();
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        assertEq(sale.referrerOf(buyer), address(0));
    }

    function test_referral_boostAndReferralCombineInOneCall() public {
        _openSale();

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, referrer, _maxVoucher(buyer, 1));

        assertEq(sale.campaignBonusSs4(buyer), _expectedBoost(MAX_BOOST_BPS));
        assertEq(sale.referrerOf(buyer), referrer);
    }

    // =====================================================================
    // The reserve: clamped, never over-awarded, never reverting a sale
    // =====================================================================

    function test_reserve_exhaustedPurchaseStillSucceeds() public {
        // A reserve far too small for one maximum boost: the award clamps to what is left.
        sale = _deployAndFreeze(1_000e18, MAX_BOOST_BPS);
        _fundBuyer(buyer);
        _openSale();

        vm.expectEmit(false, false, false, true);
        emit BonusReserveShort(_expectedBoost(MAX_BOOST_BPS), 1_000e18);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        assertEq(sale.purchasedSs4(buyer), BUY_SS4, "the sale does not fail because the budget is spent");
        assertEq(sale.campaignBonusSs4(buyer), 1_000e18);
        assertEq(sale.bonusAwarded(), 1_000e18);
    }

    function test_reserve_emptyReserveAwardsNothingAndStillSells() public {
        sale = _deployAndFreeze(1_000e18, MAX_BOOST_BPS);
        _fundBuyer(buyer);
        _fundBuyer(buyer2);
        _openSale();

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        vm.expectEmit(false, false, false, true);
        emit BonusReserveShort(_expectedBoost(MAX_BOOST_BPS), 0);

        vm.prank(buyer2);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer2, 1));

        assertEq(sale.campaignBonusSs4(buyer2), 0);
        assertEq(sale.purchasedSs4(buyer2), BUY_SS4);
        assertEq(sale.bonusRemaining(), 0);
    }

    function testFuzz_bonusAwardedNeverExceedsReserve(uint16 bpsA, uint16 bpsB, uint96 spendA, uint96 spendB) public {
        _openSale();

        // Any rate the campaign could publish, and any spend a wallet could afford.
        uint16 rateA = uint16(bound(bpsA, 0, MAX_BOOST_BPS));
        uint16 rateB = uint16(bound(bpsB, 0, MAX_BOOST_BPS));
        uint256 payA = bound(spendA, 1e6, 90_000e6);
        uint256 payB = bound(spendB, 1e6, 90_000e6);

        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), payA, 0, address(0), _voucher(buyer, rateA, 1, signerKey));
        vm.prank(buyer2);
        sale.buyWithCampaign(address(usdc), payB, 0, address(0), _voucher(buyer2, rateB, 1, signerKey));

        assertLe(sale.bonusAwarded(), BONUS_ALLOCATION, "the reserve is the ceiling on the whole campaign");
        assertEq(
            sale.bonusAwarded(),
            sale.campaignBonusSs4(buyer) + sale.campaignBonusSs4(buyer2),
            "and the total equals the sum of what wallets actually hold"
        );
    }

    function test_freeze_requiresBonusReserveToBeFunded() public {
        SS4PresaleV3 underfunded = new SS4PresaleV3(address(ss4), admin);

        vm.startPrank(admin);
        underfunded.setPaymentToken(address(usdc), 6, true);
        underfunded.configure(_saleConfig());
        underfunded.configureCampaign(
            SS4PresaleV3.CampaignConfig({bonusAllocation: BONUS_ALLOCATION, maxCampaignBoostBps: MAX_BOOST_BPS})
        );
        vm.stopPrank();

        // Sale allocation only — the campaign has nothing behind it.
        ss4.mint(address(underfunded), ALLOCATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                SS4PresaleV3.InventoryNotFunded.selector, ALLOCATION + BONUS_ALLOCATION, ALLOCATION
            )
        );
        vm.prank(admin);
        underfunded.freezeConfiguration();
    }

    // =====================================================================
    // Claims, refunds and recovery, with a boost in the position
    // =====================================================================

    function test_claim_paysPurchasePlusBoost() public {
        _openSale();
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        vm.warp(SALE_END + 1);
        vm.prank(admin);
        sale.finalize();
        vm.warp(CLAIM_START + 1);

        uint256 expected = BUY_SS4 + _expectedBoost(MAX_BOOST_BPS);
        assertEq(sale.totalEntitlement(buyer), expected);
        assertEq(sale.claimable(buyer), expected);

        vm.prank(buyer);
        sale.claim();

        assertEq(ss4.balanceOf(buyer), expected, "one claim, one schedule, purchase and boost together");
        assertEq(sale.claimable(buyer), 0);
    }

    function test_recoverUnsoldTokens_cannotTakeAnAwardedBoost() public {
        _openSale();
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        vm.warp(SALE_END + 1);
        vm.prank(admin);
        sale.finalize();

        uint256 owed = BUY_SS4 + _expectedBoost(MAX_BOOST_BPS);
        assertEq(sale.recoverableSs4(), ALLOCATION + BONUS_ALLOCATION - owed);

        vm.prank(admin);
        sale.recoverUnsoldTokens(treasury);

        // Whatever the treasury took, the buyer's whole entitlement is still claimable.
        vm.warp(CLAIM_START + 1);
        vm.prank(buyer);
        sale.claim();
        assertEq(ss4.balanceOf(buyer), owed);
    }

    function test_refund_zeroesTheCampaignBoost() public {
        _openSale();
        vm.prank(buyer);
        sale.buyWithCampaign(address(usdc), BUY_USDC, 0, address(0), _maxVoucher(buyer, 1));

        vm.prank(admin);
        sale.cancelSale(keccak256("TEST"));

        vm.prank(buyer);
        sale.refund();

        assertEq(usdc.balanceOf(buyer), 1_000_000e6, "every stablecoin back");
        assertEq(sale.campaignBonusSs4(buyer), 0, "a cancelled sale pays no boost");
        assertEq(sale.totalEntitlement(buyer), 0);
    }

    function test_vesting_appliesToTheBoostToo() public {
        // A sale with a 20% unlock and a 100-day linear tail.
        SS4PresaleV3 vesting = new SS4PresaleV3(address(ss4), admin);
        SS4PresaleV3.SaleConfig memory cfg = _saleConfig();
        cfg.tgeUnlockBps = 2_000;
        cfg.vestDurationSeconds = 100 days;

        vm.startPrank(admin);
        vesting.setPaymentToken(address(usdc), 6, true);
        vesting.configure(cfg);
        vesting.configureCampaign(
            SS4PresaleV3.CampaignConfig({bonusAllocation: BONUS_ALLOCATION, maxCampaignBoostBps: MAX_BOOST_BPS})
        );
        vesting.grantRole(vesting.CAMPAIGN_SIGNER_ROLE(), signer);
        vm.stopPrank();
        ss4.mint(address(vesting), ALLOCATION + BONUS_ALLOCATION);
        vm.prank(admin);
        vesting.freezeConfiguration();

        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(vesting), type(uint256).max);

        vm.warp(SALE_START + 1);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = vesting.campaignVoucherDigest(buyer, MAX_BOOST_BPS, deadline, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.prank(buyer);
        vesting.buyWithCampaign(
            address(usdc),
            BUY_USDC,
            0,
            address(0),
            SS4PresaleV3.CampaignVoucher({
                boostBps: MAX_BOOST_BPS,
                deadline: deadline,
                nonce: 1,
                signature: abi.encodePacked(r, s, v)
            })
        );

        vm.warp(SALE_END + 1);
        vm.prank(admin);
        vesting.finalize();

        uint256 total = BUY_SS4 + _expectedBoost(MAX_BOOST_BPS);
        vm.warp(CLAIM_START);
        assertEq(vesting.vestedAmount(buyer, uint64(block.timestamp)), (total * 2_000) / 10_000, "20% at TGE");

        vm.warp(CLAIM_START + 50 days);
        assertEq(
            vesting.vestedAmount(buyer, uint64(block.timestamp)),
            (total * 2_000) / 10_000 + ((total - (total * 2_000) / 10_000) * 50 days) / (100 days),
            "boost vests on the same curve as the purchase"
        );

        vm.warp(CLAIM_START + 100 days);
        assertEq(vesting.vestedAmount(buyer, uint64(block.timestamp)), total, "fully vested");
    }

    // =====================================================================
    // Campaign configuration
    // =====================================================================

    function test_configureCampaign_rejectsMaximumAboveCeiling() public {
        SS4PresaleV3 fresh = new SS4PresaleV3(address(ss4), admin);
        vm.expectRevert(SS4PresaleV3.InvalidBoostConfig.selector);
        vm.prank(admin);
        fresh.configureCampaign(
            SS4PresaleV3.CampaignConfig({bonusAllocation: BONUS_ALLOCATION, maxCampaignBoostBps: 2_001})
        );
    }

    function test_configureCampaign_rejectsMaximumWithNoReserve() public {
        SS4PresaleV3 fresh = new SS4PresaleV3(address(ss4), admin);
        vm.expectRevert(SS4PresaleV3.InvalidBoostConfig.selector);
        vm.prank(admin);
        fresh.configureCampaign(SS4PresaleV3.CampaignConfig({bonusAllocation: 0, maxCampaignBoostBps: MAX_BOOST_BPS}));
    }

    function test_configureCampaign_rejectsReserveWithNoMaximum() public {
        SS4PresaleV3 fresh = new SS4PresaleV3(address(ss4), admin);
        vm.expectRevert(SS4PresaleV3.InvalidBoostConfig.selector);
        vm.prank(admin);
        fresh.configureCampaign(SS4PresaleV3.CampaignConfig({bonusAllocation: BONUS_ALLOCATION, maxCampaignBoostBps: 0}));
    }

    function test_configureCampaign_noCampaignAtAllIsValid() public {
        SS4PresaleV3 fresh = new SS4PresaleV3(address(ss4), admin);

        vm.startPrank(admin);
        fresh.setPaymentToken(address(usdc), 6, true);
        fresh.configure(_saleConfig());
        fresh.configureCampaign(SS4PresaleV3.CampaignConfig({bonusAllocation: 0, maxCampaignBoostBps: 0}));
        vm.stopPrank();

        ss4.mint(address(fresh), ALLOCATION);
        vm.prank(admin);
        fresh.freezeConfiguration();

        assertTrue(fresh.configFrozen());
        assertEq(fresh.maxCampaignBoostBps(), 0);

        // With no campaign, even a correctly signed voucher buys at the base rate — or rather,
        // does not buy at all, because every rate is above a zero maximum.
        usdc.mint(buyer, BUY_USDC);
        vm.prank(buyer);
        usdc.approve(address(fresh), type(uint256).max);
        vm.warp(SALE_START + 1);

        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = fresh.campaignVoucherDigest(buyer, 1, deadline, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.expectRevert(abi.encodeWithSelector(SS4PresaleV3.BoostAboveCampaignMaximum.selector, uint16(0), uint16(1)));
        vm.prank(buyer);
        fresh.buyWithCampaign(
            address(usdc),
            BUY_USDC,
            0,
            address(0),
            SS4PresaleV3.CampaignVoucher({
                boostBps: 1,
                deadline: deadline,
                nonce: 1,
                signature: abi.encodePacked(r, s, v)
            })
        );
    }

    function test_configureCampaign_rejectedAfterFreeze() public {
        vm.expectRevert(SS4PresaleV3.ConfigAlreadyFrozen.selector);
        vm.prank(admin);
        sale.configureCampaign(
            SS4PresaleV3.CampaignConfig({bonusAllocation: BONUS_ALLOCATION, maxCampaignBoostBps: 2_000})
        );
    }

    /// The campaign maximum is part of what a buyer agreed to, so it has to be in the hash.
    function test_configHash_coversTheCampaignMaximum() public {
        bytes32 at550 = sale.configHash();

        SS4PresaleV3 other = _deployAndFreeze(BONUS_ALLOCATION, 500);
        assertTrue(other.configHash() != at550, "a different published maximum is a different sale");
    }
}
