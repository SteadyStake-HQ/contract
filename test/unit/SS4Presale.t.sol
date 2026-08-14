// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {SS4Presale} from "../../src/sale/SS4Presale.sol";
import {MockUSDC, MockToken, MockUSDT, MockFeeToken} from "../../src/MockTokens.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @dev 6-decimal stablecoin that supports ERC-2612, like Circle USDC.
contract MockUSDCPermit is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Re-enters `buy` from inside `transferFrom` to prove the guard holds.
contract MaliciousReentrantToken is ERC20 {
    SS4Presale public presale;
    bool private _attacking;

    constructor() ERC20("Evil", "EVIL") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setPresale(SS4Presale presale_) external {
        presale = presale_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!_attacking && address(presale) != address(0)) {
            _attacking = true;
            presale.buy(address(this), amount, 0);
            _attacking = false;
        }
        return super.transferFrom(from, to, amount);
    }
}

contract SS4PresaleTest is Test {
    SS4Presale internal presale;
    MockToken internal ss4;
    MockUSDC internal usdc; // 6 decimals
    MockToken internal usdc18; // 18 decimals, e.g. Binance-Peg USDC on BNB Chain (§21)

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal outsider = makeAddr("outsider");

    // §7.2 recommended interpretation of the 17–30 August 2026 sale window.
    uint64 internal constant SALE_START = 1_786_924_800; // 2026-08-17T00:00:00Z
    uint64 internal constant SALE_END = 1_788_134_400; // 2026-08-31T00:00:00Z, exclusive
    uint64 internal constant CLAIM_START = 1_788_220_800; // 2026-09-01T00:00:00Z

    // Illustrative test economics only — every one of these is a §29 deployment blocker.
    uint256 internal constant PRICE_USD_E6 = 25_000; // $0.025 per SS4
    uint256 internal constant ALLOCATION = 20_000_000e18; // $500,000 worth
    uint256 internal constant MIN_BUY = 10e6; // $10
    uint256 internal constant WALLET_CAP = 50_000e6; // $50,000
    uint256 internal constant SOFT_CAP = 100_000e6;
    uint256 internal constant HARD_CAP = 500_000e6;

    event Purchase(address indexed buyer, address indexed paymentToken, uint256 paymentAmount, uint256 ss4Amount);
    event Claim(address indexed buyer, uint256 ss4Amount);
    event Refund(address indexed buyer, address indexed paymentToken, uint256 paymentAmount);

    function setUp() public {
        vm.warp(SALE_START - 7 days);

        ss4 = new MockToken("SteadyStake", "SS4", 18);
        usdc = new MockUSDC();
        usdc18 = new MockToken("Binance-Peg USDC", "USDC", 18);

        presale = _deployAndFreeze(ALLOCATION, MIN_BUY, WALLET_CAP, SOFT_CAP, HARD_CAP, 10_000, 0, 0);

        _fundBuyer(buyer, 1_000_000e6, 1_000_000e18);
        _fundBuyer(buyer2, 1_000_000e6, 1_000_000e18);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _config(
        uint256 allocation,
        uint256 minBuy,
        uint256 walletCap,
        uint256 softCap,
        uint256 hardCap,
        uint16 tgeBps,
        uint64 cliff,
        uint64 duration
    ) internal pure returns (SS4Presale.SaleConfig memory) {
        return SS4Presale.SaleConfig({
            saleAllocation: allocation,
            priceUsdE6: PRICE_USD_E6,
            saleStart: SALE_START,
            saleEnd: SALE_END,
            claimStart: CLAIM_START,
            claimDeadline: 0,
            tgeUnlockBps: tgeBps,
            vestCliffSeconds: cliff,
            vestDurationSeconds: duration,
            minPurchaseUsdE6: minBuy,
            maxPurchasePerWalletUsdE6: walletCap,
            softCapUsdE6: softCap,
            hardCapUsdE6: hardCap
        });
    }

    /// Default full-unlock, no-limits configuration used by the hostile-token tests.
    function _defaultConfig() internal pure returns (SS4Presale.SaleConfig memory) {
        return _config(ALLOCATION, 0, 0, 0, HARD_CAP, 10_000, 0, 0);
    }

    function _deployAndFreeze(
        uint256 allocation,
        uint256 minBuy,
        uint256 walletCap,
        uint256 softCap,
        uint256 hardCap,
        uint16 tgeBps,
        uint64 cliff,
        uint64 duration
    ) internal returns (SS4Presale sale) {
        sale = new SS4Presale(address(ss4), admin);

        vm.startPrank(admin);
        sale.setPaymentToken(address(usdc), 6, true);
        sale.setPaymentToken(address(usdc18), 18, true);
        sale.configure(_config(allocation, minBuy, walletCap, softCap, hardCap, tgeBps, cliff, duration));
        vm.stopPrank();

        // §7.7: inventory must be in place before the sale can open — the freeze enforces it.
        ss4.mint(address(sale), allocation);

        vm.prank(admin);
        sale.freezeConfiguration();
    }

    function _fundBuyer(address who, uint256 usdcAmount, uint256 usdc18Amount) internal {
        usdc.mint(who, usdcAmount);
        usdc18.mint(who, usdc18Amount);
        vm.startPrank(who);
        usdc.approve(address(presale), type(uint256).max);
        usdc18.approve(address(presale), type(uint256).max);
        vm.stopPrank();
    }

    function _openSale() internal {
        vm.warp(SALE_START);
    }

    /// @dev Takes the sale exactly to its soft cap. The per-wallet cap is half the soft
    ///      cap, so this deliberately needs two buyers — one wallet cannot get there.
    ///      Leaves `buyer` holding BUYER_SS4 and the sale holding 2 * BUYER_SS4 sold.
    function _reachSoftCap() internal {
        vm.prank(buyer);
        presale.buy(address(usdc), WALLET_CAP, 0);
        vm.prank(buyer2);
        presale.buy(address(usdc), WALLET_CAP, 0);
    }

    /// $50,000 at $0.025 = 2,000,000 SS4.
    uint256 internal constant BUYER_SS4 = 2_000_000e18;

    function _endAndFinalize() internal {
        vm.warp(SALE_END);
        vm.prank(admin);
        presale.finalize();
    }

    // ---------------------------------------------------------------------
    // Configuration and freeze (§7.5)
    // ---------------------------------------------------------------------

    function test_Freeze_BlocksEveryEconomicChange() public {
        vm.startPrank(admin);
        vm.expectRevert(SS4Presale.ConfigAlreadyFrozen.selector);
        presale.configure(_defaultConfig());
        vm.expectRevert(SS4Presale.ConfigAlreadyFrozen.selector);
        presale.setPaymentToken(address(usdc), 6, false);
        vm.stopPrank();

        assertTrue(presale.configFrozen());
        assertTrue(presale.configHash() != bytes32(0), "config hash published");
    }

    /// §28.7: the freeze must reject a configuration still holding TBD placeholders.
    function test_Freeze_RejectsUnconfiguredSale() public {
        SS4Presale bare = new SS4Presale(address(ss4), admin);

        vm.prank(admin);
        vm.expectRevert(SS4Presale.IncompleteConfiguration.selector);
        bare.freezeConfiguration();

        vm.startPrank(admin);
        bare.configure(_config(ALLOCATION, MIN_BUY, WALLET_CAP, SOFT_CAP, HARD_CAP, 10_000, 0, 0));
        // No accepted payment token yet.
        vm.expectRevert(SS4Presale.IncompleteConfiguration.selector);
        bare.freezeConfiguration();

        bare.setPaymentToken(address(usdc), 6, true);
        // Still unfunded.
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.InventoryNotFunded.selector, ALLOCATION, 0));
        bare.freezeConfiguration();
        vm.stopPrank();
    }

    function test_SetPaymentToken_WrongDecimals_Reverts() public {
        SS4Presale bare = new SS4Presale(address(ss4), admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.DecimalsMismatch.selector, 18, 6));
        bare.setPaymentToken(address(usdc), 18, true);
    }

    function test_SetPaymentToken_RejectsSs4Itself() public {
        SS4Presale bare = new SS4Presale(address(ss4), admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.ProtectedToken.selector, address(ss4)));
        bare.setPaymentToken(address(ss4), 18, true);
    }

    function test_Config_OnlyConfigRole() public {
        SS4Presale bare = new SS4Presale(address(ss4), admin);
        vm.prank(outsider);
        vm.expectRevert();
        bare.configure(_defaultConfig());
    }

    /// The bundle is validated as a whole; an inconsistent bundle is never half-applied.
    function test_Configure_RejectsInvalidBundles() public {
        SS4Presale bare = new SS4Presale(address(ss4), admin);
        vm.startPrank(admin);

        SS4Presale.SaleConfig memory cfg = _defaultConfig();
        cfg.saleEnd = SALE_START - 1; // end before start
        vm.expectRevert(SS4Presale.InvalidSchedule.selector);
        bare.configure(cfg);

        cfg = _defaultConfig();
        cfg.claimStart = SALE_END - 1; // claims before the sale is over
        vm.expectRevert(SS4Presale.InvalidSchedule.selector);
        bare.configure(cfg);

        cfg = _defaultConfig();
        cfg.softCapUsdE6 = HARD_CAP + 1;
        vm.expectRevert(SS4Presale.InvalidCaps.selector);
        bare.configure(cfg);

        // A partial TGE unlock with no vesting window would strand the remainder.
        cfg = _defaultConfig();
        cfg.tgeUnlockBps = 2_500;
        cfg.vestDurationSeconds = 0;
        vm.expectRevert(SS4Presale.InvalidVesting.selector);
        bare.configure(cfg);

        cfg = _defaultConfig();
        cfg.priceUsdE6 = 0;
        vm.expectRevert(SS4Presale.ZeroAmount.selector);
        bare.configure(cfg);

        vm.stopPrank();
        assertEq(bare.saleStart(), 0, "nothing was applied");
    }

    // ---------------------------------------------------------------------
    // Sale window (§26.2 "before start, at start, immediately before end, at end")
    // ---------------------------------------------------------------------

    function test_Buy_BeforeStart_Reverts() public {
        vm.warp(SALE_START - 1);
        assertEq(uint8(presale.state()), uint8(SS4Presale.SaleState.Configured));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SaleNotActive.selector, SS4Presale.SaleState.Configured));
        presale.buy(address(usdc), 100e6, 0);
    }

    function test_Buy_AtStartAndJustBeforeEnd_Succeeds() public {
        vm.warp(SALE_START);
        vm.prank(buyer);
        presale.buy(address(usdc), 100e6, 0);

        vm.warp(SALE_END - 1);
        vm.prank(buyer);
        presale.buy(address(usdc), 100e6, 0);

        assertEq(presale.purchasedUsdE6(buyer), 200e6);
    }

    /// `saleEnd` is exclusive (§7.2): the boundary second itself is already over.
    function test_Buy_AtEnd_Reverts() public {
        vm.warp(SALE_END);
        assertEq(uint8(presale.state()), uint8(SS4Presale.SaleState.Ended));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SaleNotActive.selector, SS4Presale.SaleState.Ended));
        presale.buy(address(usdc), 100e6, 0);
    }

    // ---------------------------------------------------------------------
    // Price math (§7.4, §26.2 "6-decimal and 18-decimal payment math")
    // ---------------------------------------------------------------------

    /// 100 USDC at $0.025 buys exactly 4,000 SS4.
    function test_Buy_SixDecimalMath() public {
        _openSale();

        vm.expectEmit(true, true, true, true);
        emit Purchase(buyer, address(usdc), 100e6, 4_000e18);

        vm.prank(buyer);
        uint256 out = presale.buy(address(usdc), 100e6, 0);

        assertEq(out, 4_000e18, "4000 SS4 for $100");
        assertEq(presale.purchasedSs4(buyer), 4_000e18);
        assertEq(presale.raisedUsdE6(), 100e6);
        assertEq(usdc.balanceOf(address(presale)), 100e6);
    }

    /// The same $100 paid in an 18-decimal stablecoin must buy the same 4,000 SS4.
    function test_Buy_EighteenDecimalMath_MatchesSixDecimal() public {
        _openSale();

        vm.prank(buyer);
        uint256 outSix = presale.buy(address(usdc), 100e6, 0);
        vm.prank(buyer2);
        uint256 outEighteen = presale.buy(address(usdc18), 100e18, 0);

        assertEq(outEighteen, outSix, "decimals must not change the price");
        assertEq(outEighteen, 4_000e18);
        assertEq(presale.raisedUsdE6(), 200e6);
    }

    function test_PreviewPurchase_MatchesBuy() public {
        _openSale();
        (uint256 usdE6, uint256 quoted) = presale.previewPurchase(address(usdc), 250e6);
        assertEq(usdE6, 250e6);

        vm.prank(buyer);
        uint256 actual = presale.buy(address(usdc), 250e6, quoted);
        assertEq(actual, quoted, "preview is binding at a fixed price");
    }

    function test_Buy_BelowMinSs4Out_Reverts() public {
        _openSale();
        (, uint256 quoted) = presale.previewPurchase(address(usdc), 100e6);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.InsufficientOutput.selector, quoted + 1, quoted));
        presale.buy(address(usdc), 100e6, quoted + 1);
    }

    function test_Buy_UnsupportedToken_Reverts() public {
        _openSale();
        MockToken random = new MockToken("Random", "RND", 18);
        random.mint(buyer, 1_000e18);
        vm.startPrank(buyer);
        random.approve(address(presale), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.PaymentTokenNotAccepted.selector, address(random)));
        presale.buy(address(random), 100e18, 0);
        vm.stopPrank();
    }

    /// A dust payment that prices to zero SS4 must be rejected, not silently taken (§7.4).
    function test_Buy_RoundsToZero_Reverts() public {
        SS4Presale sale = _deployAndFreeze(ALLOCATION, 0, 0, 0, HARD_CAP, 10_000, 0, 0);
        _openSale();

        usdc.mint(buyer, 1e6);
        vm.startPrank(buyer);
        usdc.approve(address(sale), type(uint256).max);
        vm.expectRevert(SS4Presale.ZeroAmount.selector);
        sale.buy(address(usdc), 0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Caps (§7.7)
    // ---------------------------------------------------------------------

    function test_Buy_BelowMinimum_Reverts() public {
        _openSale();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.BelowMinimumPurchase.selector, MIN_BUY, 5e6));
        presale.buy(address(usdc), 5e6, 0);
    }

    /// The wallet cap aggregates across purchases and across payment tokens.
    function test_Buy_WalletCap_AggregatesAcrossTokens() public {
        _openSale();

        vm.prank(buyer);
        presale.buy(address(usdc), 30_000e6, 0);
        vm.prank(buyer);
        presale.buy(address(usdc18), 19_000e18, 0);
        assertEq(presale.purchasedUsdE6(buyer), 49_000e6);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.ExceedsWalletCap.selector, WALLET_CAP, 51_000e6));
        presale.buy(address(usdc), 2_000e6, 0);

        // Exactly at the cap is fine.
        vm.prank(buyer);
        presale.buy(address(usdc), 1_000e6, 0);
        assertEq(presale.purchasedUsdE6(buyer), WALLET_CAP);
    }

    /// Exact sellout succeeds; one base unit more must not (§26.2).
    function test_Buy_ExactSellout_ThenOneUnitOversell_Reverts() public {
        // $100 of inventory: 4,000 SS4 at $0.025.
        SS4Presale sale = _deployAndFreeze(4_000e18, 0, 0, 0, HARD_CAP, 10_000, 0, 0);
        _openSale();

        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(sale), type(uint256).max);

        sale.buy(address(usdc), 100e6, 0);
        assertEq(sale.tokensSold(), 4_000e18, "exact sellout");
        assertEq(uint8(sale.state()), uint8(SS4Presale.SaleState.Ended), "sold out ends the sale");

        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SaleNotActive.selector, SS4Presale.SaleState.Ended));
        sale.buy(address(usdc), 1, 0);
        vm.stopPrank();
    }

    function test_Buy_HardCap_BlocksOverfill() public {
        // Inventory far exceeds the hard cap, so the USD cap is the binding limit.
        SS4Presale sale = _deployAndFreeze(ALLOCATION, 0, 0, 0, 1_000e6, 10_000, 0, 0);
        _openSale();

        usdc.mint(buyer, 10_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(sale), type(uint256).max);

        sale.buy(address(usdc), 900e6, 0);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.ExceedsHardCap.selector, 100e6, 200e6));
        sale.buy(address(usdc), 200e6, 0);

        sale.buy(address(usdc), 100e6, 0);
        assertEq(sale.raisedUsdE6(), 1_000e6);
        assertEq(uint8(sale.state()), uint8(SS4Presale.SaleState.Ended), "hard cap ends the sale");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Finalization and treasury (§7.7)
    // ---------------------------------------------------------------------

    function test_Finalize_BeforeEnd_Reverts() public {
        _openSale();
        _reachSoftCap();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SaleNotEnded.selector, SS4Presale.SaleState.Active));
        presale.finalize();
    }

    function test_Finalize_BelowSoftCap_Reverts() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 1_000e6, 0);

        vm.warp(SALE_END);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SoftCapNotReached.selector, SOFT_CAP, 1_000e6));
        presale.finalize();
    }

    function test_WithdrawRaisedFunds_BeforeFinalization_Reverts() public {
        _openSale();
        _reachSoftCap();

        vm.prank(admin);
        vm.expectRevert(SS4Presale.SaleNotFinalized.selector);
        presale.withdrawRaisedFunds(treasury);
    }

    function test_WithdrawRaisedFunds_AfterFinalization_MovesEveryToken() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 50_000e6, 0);
        vm.prank(buyer2);
        presale.buy(address(usdc18), 50_000e18, 0);

        _endAndFinalize();

        vm.prank(admin);
        presale.withdrawRaisedFunds(treasury);

        assertEq(usdc.balanceOf(treasury), 50_000e6);
        assertEq(usdc18.balanceOf(treasury), 50_000e18);
        assertEq(usdc.balanceOf(address(presale)), 0);

        // Second withdrawal is a no-op, not a double payout.
        vm.prank(admin);
        presale.withdrawRaisedFunds(treasury);
        assertEq(usdc.balanceOf(treasury), 50_000e6);
    }

    function test_RecoverUnsoldTokens_LeavesBuyerEntitlementsIntact() public {
        _openSale();
        _reachSoftCap();
        _endAndFinalize();

        uint256 owed = presale.outstandingEntitlement();
        assertEq(owed, BUYER_SS4 * 2);

        vm.prank(admin);
        presale.recoverUnsoldTokens(treasury);

        assertEq(ss4.balanceOf(treasury), ALLOCATION - owed, "only the unsold remainder left");
        assertEq(ss4.balanceOf(address(presale)), owed, "every claim still covered");

        // Both buyers can still be paid in full out of what is left.
        vm.warp(CLAIM_START);
        vm.prank(buyer);
        presale.claim();
        vm.prank(buyer2);
        presale.claim();
        assertEq(ss4.balanceOf(buyer), BUYER_SS4);
        assertEq(ss4.balanceOf(buyer2), BUYER_SS4);
        assertEq(ss4.balanceOf(address(presale)), 0, "nothing stranded");
    }

    function test_RecoverUnsupportedToken_RefusesSs4AndPaymentTokens() public {
        _endAndFinalizeEmpty();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.ProtectedToken.selector, address(ss4)));
        presale.recoverUnsupportedToken(address(ss4), treasury);

        vm.expectRevert(abi.encodeWithSelector(SS4Presale.ProtectedToken.selector, address(usdc)));
        presale.recoverUnsupportedToken(address(usdc), treasury);
        vm.stopPrank();
    }

    function _endAndFinalizeEmpty() internal {
        SS4Presale sale = _deployAndFreeze(ALLOCATION, 0, 0, 0, HARD_CAP, 10_000, 0, 0);
        presale = sale;
        vm.warp(SALE_END);
        vm.prank(admin);
        sale.finalize();
    }

    // ---------------------------------------------------------------------
    // Claims and vesting (§7.7)
    // ---------------------------------------------------------------------

    function test_Claim_BeforeFinalization_Reverts() public {
        _openSale();
        _reachSoftCap();

        vm.warp(CLAIM_START);
        vm.prank(buyer);
        vm.expectRevert(SS4Presale.SaleNotFinalized.selector);
        presale.claim();
    }

    function test_Claim_BeforeClaimStart_Reverts() public {
        _openSale();
        _reachSoftCap();
        _endAndFinalize();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.ClaimsNotOpen.selector, CLAIM_START));
        presale.claim();
    }

    function test_Claim_FullUnlock_PaysOnceThenReverts() public {
        _openSale();
        _reachSoftCap();
        _endAndFinalize();
        vm.warp(CLAIM_START);

        vm.expectEmit(true, true, true, true);
        emit Claim(buyer, BUYER_SS4);
        vm.prank(buyer);
        presale.claim();

        assertEq(ss4.balanceOf(buyer), BUYER_SS4);
        assertEq(presale.claimable(buyer), 0);

        vm.prank(buyer);
        vm.expectRevert(SS4Presale.NothingToClaim.selector);
        presale.claim();
    }

    /// 25% at TGE, remainder linear over 90 days after a 30-day cliff — no cliff jump (§6.1).
    function test_Claim_PartialVesting_Curve() public {
        SS4Presale sale = _deployAndFreeze(ALLOCATION, 0, 0, 0, HARD_CAP, 2_500, 30 days, 90 days);
        _openSale();

        usdc.mint(buyer, 100e6);
        vm.startPrank(buyer);
        usdc.approve(address(sale), type(uint256).max);
        sale.buy(address(usdc), 100e6, 0); // 4,000 SS4
        vm.stopPrank();

        vm.warp(SALE_END);
        vm.prank(admin);
        sale.finalize();

        uint256 total = 4_000e18;

        vm.warp(CLAIM_START - 1);
        assertEq(sale.claimable(buyer), 0, "nothing before claim start");

        vm.warp(CLAIM_START);
        assertEq(sale.claimable(buyer), total / 4, "25% at TGE");

        vm.warp(CLAIM_START + 30 days - 1);
        assertEq(sale.claimable(buyer), total / 4, "still only TGE right before the cliff");

        // At the cliff the linear portion starts from zero: no catch-up lump.
        vm.warp(CLAIM_START + 30 days);
        assertEq(sale.claimable(buyer), total / 4, "no jump at the cliff");

        vm.warp(CLAIM_START + 30 days + 45 days);
        assertEq(sale.claimable(buyer), total / 4 + (total * 3 / 4) / 2, "half of the remainder");

        vm.prank(buyer);
        sale.claim();
        uint256 taken = ss4.balanceOf(buyer);

        vm.warp(CLAIM_START + 30 days + 90 days);
        assertEq(sale.claimable(buyer), total - taken, "exact remainder at the end");

        vm.prank(buyer);
        sale.claim();
        assertEq(ss4.balanceOf(buyer), total, "fully vested, nothing stranded");
    }

    // ---------------------------------------------------------------------
    // Cancellation and refunds (§7.7)
    // ---------------------------------------------------------------------

    function test_Refund_ReturnsEveryTokenOnce() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 5_000e6, 0);
        vm.prank(buyer);
        presale.buy(address(usdc18), 3_000e18, 0);

        uint256 usdcBefore = usdc.balanceOf(buyer);
        uint256 usdc18Before = usdc18.balanceOf(buyer);

        vm.prank(admin);
        presale.cancelSale(keccak256("legal review"));

        assertEq(presale.refundable(buyer, address(usdc)), 5_000e6);

        vm.prank(buyer);
        presale.refund();

        assertEq(usdc.balanceOf(buyer), usdcBefore + 5_000e6);
        assertEq(usdc18.balanceOf(buyer), usdc18Before + 3_000e18);
        assertEq(presale.purchasedSs4(buyer), 0, "entitlement cleared with the refund");

        vm.prank(buyer);
        vm.expectRevert(SS4Presale.NothingToRefund.selector);
        presale.refund();
    }

    /// A cancelled sale owes no SS4, so the whole allocation must be returnable — while
    /// the stablecoins owed as refunds stay locked in the contract (§25.3).
    function test_RecoverUnsoldTokens_AfterCancellation_ReturnsAllInventory() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 5_000e6, 0);

        vm.prank(admin);
        presale.cancelSale(bytes32(0));

        vm.prank(admin);
        presale.recoverUnsoldTokens(treasury);

        assertEq(ss4.balanceOf(treasury), ALLOCATION, "full allocation returned");
        assertEq(ss4.balanceOf(address(presale)), 0);
        assertEq(usdc.balanceOf(address(presale)), 5_000e6, "refund money untouched");

        // The buyer's refund still works afterwards.
        vm.prank(buyer);
        presale.refund();
        assertEq(presale.refundable(buyer, address(usdc)), 0);
    }

    function test_RecoverUnsoldTokens_BeforeSettlement_Reverts() public {
        _openSale();
        _reachSoftCap();

        vm.prank(admin);
        vm.expectRevert(SS4Presale.SaleNotSettled.selector);
        presale.recoverUnsoldTokens(treasury);
    }

    function test_Refund_BeforeCancellation_Reverts() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 5_000e6, 0);

        vm.prank(buyer);
        vm.expectRevert(SS4Presale.SaleNotCancelled.selector);
        presale.refund();
    }

    function test_Cancel_ThenFinalize_Reverts_AndViceVersa() public {
        _openSale();
        _reachSoftCap(); // even a fully successful raise cannot be finalized once cancelled

        vm.prank(admin);
        presale.cancelSale(bytes32(0));

        vm.warp(SALE_END);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SaleNotEnded.selector, SS4Presale.SaleState.Cancelled));
        presale.finalize();

        vm.prank(admin);
        vm.expectRevert(SS4Presale.SaleAlreadySettled.selector);
        presale.cancelSale(bytes32(0));
    }

    /// Buyer funds must never be strandable when the sale misses its soft cap.
    function test_CancelIfSoftCapMissed_IsPermissionless() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 1_000e6, 0);
        vm.warp(SALE_END);

        vm.prank(outsider);
        presale.cancelIfSoftCapMissed();

        assertEq(uint8(presale.state()), uint8(SS4Presale.SaleState.Cancelled));
        vm.prank(buyer);
        presale.refund();
        assertEq(presale.refundable(buyer, address(usdc)), 0);
    }

    function test_CancelIfSoftCapMissed_WhenReached_Reverts() public {
        _openSale();
        _reachSoftCap();
        vm.warp(SALE_END);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.SoftCapNotReached.selector, SOFT_CAP, 100_000e6));
        presale.cancelIfSoftCapMissed();
    }

    // ---------------------------------------------------------------------
    // Pause scope (§22.3)
    // ---------------------------------------------------------------------

    function test_Pause_StopsPurchases_ButNotRefunds() public {
        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), 5_000e6, 0);

        vm.prank(admin);
        presale.pausePurchases();

        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        presale.buy(address(usdc), 5_000e6, 0);

        vm.prank(admin);
        presale.cancelSale(bytes32(0));

        // Still paused; the refund must go through anyway.
        vm.prank(buyer);
        presale.refund();
        assertEq(presale.refundable(buyer, address(usdc)), 0);
    }

    function test_Pause_DoesNotBlockClaims() public {
        _openSale();
        _reachSoftCap();
        _endAndFinalize();

        vm.prank(admin);
        presale.pausePurchases();

        vm.warp(CLAIM_START);
        vm.prank(buyer);
        presale.claim();
        assertEq(ss4.balanceOf(buyer), BUYER_SS4);
    }

    // ---------------------------------------------------------------------
    // Hostile tokens (§26.2 "reentrancy and malicious-token tests")
    // ---------------------------------------------------------------------

    function test_Buy_ReentrantPaymentToken_Reverts() public {
        MaliciousReentrantToken evil = new MaliciousReentrantToken();

        SS4Presale sale = new SS4Presale(address(ss4), admin);
        vm.startPrank(admin);
        sale.setPaymentToken(address(evil), 6, true);
        sale.configure(_defaultConfig());
        vm.stopPrank();
        ss4.mint(address(sale), ALLOCATION);
        vm.prank(admin);
        sale.freezeConfiguration();

        evil.setPresale(sale);
        evil.mint(buyer, 10_000e6);
        _openSale();

        vm.startPrank(buyer);
        evil.approve(address(sale), type(uint256).max);
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        sale.buy(address(evil), 100e6, 0);
        vm.stopPrank();
    }

    /// A fee-on-transfer token delivers less than stated; the balance-delta check rejects it.
    function test_Buy_FeeOnTransferToken_Reverts() public {
        MockFeeToken fee = new MockFeeToken(100); // 1%

        SS4Presale sale = new SS4Presale(address(ss4), admin);
        vm.startPrank(admin);
        sale.setPaymentToken(address(fee), 18, true);
        sale.configure(_defaultConfig());
        vm.stopPrank();
        ss4.mint(address(sale), ALLOCATION);
        vm.prank(admin);
        sale.freezeConfiguration();

        fee.mint(buyer, 1_000e18);
        _openSale();

        vm.startPrank(buyer);
        fee.approve(address(sale), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SS4Presale.UnexpectedAmountReceived.selector, 100e18, 99e18));
        sale.buy(address(fee), 100e18, 0);
        vm.stopPrank();
    }

    /// Real USDT returns nothing from transferFrom; SafeERC20 must still handle it (§7.3).
    function test_Buy_ReturnlessUSDT_Works() public {
        MockUSDT usdt = new MockUSDT();

        SS4Presale sale = new SS4Presale(address(ss4), admin);
        vm.startPrank(admin);
        sale.setPaymentToken(address(usdt), 6, true);
        sale.configure(_defaultConfig());
        vm.stopPrank();
        ss4.mint(address(sale), ALLOCATION);
        vm.prank(admin);
        sale.freezeConfiguration();

        usdt.mint(buyer, 1_000e6);
        _openSale();

        vm.startPrank(buyer);
        usdt.approve(address(sale), 100e6);
        uint256 out = sale.buy(address(usdt), 100e6, 0);
        vm.stopPrank();

        assertEq(out, 4_000e18);
        assertEq(usdt.balanceOf(address(sale)), 100e6);
    }

    function test_BuyWithPermit_Works() public {
        MockUSDCPermit permitUsdc = new MockUSDCPermit();
        uint256 buyerKey = 0xB0B;
        address permitBuyer = vm.addr(buyerKey);

        SS4Presale sale = new SS4Presale(address(ss4), admin);
        vm.startPrank(admin);
        sale.setPaymentToken(address(permitUsdc), 6, true);
        sale.configure(_defaultConfig());
        vm.stopPrank();
        ss4.mint(address(sale), ALLOCATION);
        vm.prank(admin);
        sale.freezeConfiguration();

        permitUsdc.mint(permitBuyer, 1_000e6);
        _openSale();

        uint256 amount = 100e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                permitBuyer,
                address(sale),
                amount,
                permitUsdc.nonces(permitBuyer),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permitUsdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);

        vm.prank(permitBuyer);
        uint256 out = sale.buyWithPermit(address(permitUsdc), amount, 0, deadline, v, r, s);

        assertEq(out, 4_000e18);
        assertEq(permitUsdc.balanceOf(address(sale)), amount);
    }

    // ---------------------------------------------------------------------
    // Accounting invariants (§26.7)
    // ---------------------------------------------------------------------

    function testFuzz_Accounting_SoldNeverExceedsAllocation(uint96 a, uint96 b) public {
        uint256 amountA = uint256(a) % 40_000e6;
        uint256 amountB = uint256(b) % 40_000e6;
        vm.assume(amountA >= MIN_BUY && amountB >= MIN_BUY);

        _openSale();
        vm.prank(buyer);
        presale.buy(address(usdc), amountA, 0);
        vm.prank(buyer2);
        presale.buy(address(usdc), amountB, 0);

        assertLe(presale.tokensSold(), presale.saleAllocation(), "sold <= allocation");
        assertLe(presale.raisedUsdE6(), presale.hardCapUsdE6(), "raised <= hard cap");
        assertEq(
            presale.purchasedSs4(buyer) + presale.purchasedSs4(buyer2),
            presale.tokensSold(),
            "entitlements reconcile with sold"
        );
        assertEq(usdc.balanceOf(address(presale)), presale.raisedByToken(address(usdc)), "held == recorded");
    }

    function testFuzz_ClaimedNeverExceedsPurchased(uint96 amount, uint32 elapsed) public {
        uint256 payment = MIN_BUY + (uint256(amount) % 40_000e6);

        SS4Presale sale = _deployAndFreeze(ALLOCATION, 0, 0, 0, HARD_CAP, 2_500, 30 days, 90 days);
        _openSale();

        usdc.mint(buyer, payment);
        vm.startPrank(buyer);
        usdc.approve(address(sale), type(uint256).max);
        uint256 bought = sale.buy(address(usdc), payment, 0);
        vm.stopPrank();

        vm.warp(SALE_END);
        vm.prank(admin);
        sale.finalize();

        vm.warp(uint256(CLAIM_START) + elapsed);
        uint256 owed = sale.claimable(buyer);
        assertLe(owed, bought, "never more than purchased");

        if (owed > 0) {
            vm.prank(buyer);
            sale.claim();
            assertEq(ss4.balanceOf(buyer), owed);
            assertLe(sale.claimedSs4(buyer), sale.purchasedSs4(buyer));
        }
    }
}
