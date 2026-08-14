// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title SS4PresaleV2
 * @notice `SS4Presale` plus the launch campaign: a social-task bonus, an on-chain
 *         BOT-holding bonus, and a referral reward. Implements the SS4 Smart-Contract
 *         Implementation Outline §7 with the campaign extension.
 *
 * @dev    WHY THIS IS A FORK, NOT A SUBCLASS. `SS4Presale`'s `_buy` is `private` and its
 *         accounting fields are plain storage, so there is no seam to extend through.
 *         More importantly the v1 deployment on BOT testnet has `configFrozen == true`:
 *         its terms are, by design, unchangeable. A campaign that pays out `$SS4` has to
 *         be part of the frozen bundle a buyer is agreeing to, which means a new sale
 *         contract and a new freeze — not a satellite that could be re-pointed later.
 *
 *         Everything in v1 is preserved verbatim: lifecycle, USD-normalized accounting,
 *         pull-only claims and refunds, the settlement gates on treasury operations. Read
 *         the v1 NatSpec for those; this file documents only what the campaign adds.
 *
 *         THE THREE BONUSES. All three pay in `$SS4` out of a `bonusAllocation` that is
 *         funded and frozen alongside the sale allocation, and all three are best-effort
 *         against that reserve: when it runs dry a purchase still succeeds, it simply
 *         stops earning. A sale must never revert because a marketing budget is spent.
 *
 *         1. Social (`socialBonusBps`, 2%). Off-chain by nature — following an account or
 *            joining a channel leaves no trace an EVM can read. The backend verifies the
 *            tasks and signs an EIP-712 `CampaignVoucher`; this contract checks the
 *            signature against `CAMPAIGN_SIGNER_ROLE` and applies its own frozen rate. The
 *            voucher deliberately carries NO bonus amount: a compromised signer can grant
 *            2% to a wallet that did not earn it, bounded by the reserve, and can never
 *            grant more than the published rate.
 *
 *         2. Holding (`holdBonusBps`, 3%). Trustless: the buyer's native BOT balance is
 *            read during the purchase. No signature, no oracle, no snapshot to dispute.
 *            Note that gas for the purchase is debited before execution, so a wallet
 *            holding exactly the requirement will miss it by the gas cost — the UI must
 *            say "hold 1 BOT plus gas", not "hold 1 BOT".
 *
 *         3. Referral (`referralBonusBps`, 10%). Credited to the referrer, computed on the
 *            referee's purchased `$SS4`, and never taken out of the referee's own tokens.
 *            A wallet's referrer is bound on its first referred purchase and ignored on
 *            every later one, so attribution cannot be moved after the fact.
 *
 *         WHAT THIS CONTRACT DOES NOT DO. The top-3 buyer prizes (50/30/20 USDT) are not
 *         here. `purchasedUsdE6` already makes the leaderboard exactly computable from
 *         `Purchase` events, so maintaining a sorted top-3 on-chain would add storage
 *         writes to every purchase to reproduce a number anyone can already derive. The
 *         prizes are settled off-chain against that public record.
 */
contract SS4PresaleV2 is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Roles (§22.2)
    // ---------------------------------------------------------------------

    /// @notice May set economic parameters before the freeze, and nothing after it.
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    /// @notice May finalize or cancel the sale under the published rules.
    bytes32 public constant SALE_FINALIZER_ROLE = keccak256("SALE_FINALIZER_ROLE");
    /// @notice May pause new purchases only. Never refunds, never claims (§22.3).
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice May move settled proceeds and recover unsold inventory after finalization.
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    /**
     * @notice Signs campaign vouchers attesting that a wallet completed the social tasks.
     * @dev    A hot backend key, and held deliberately apart from every other role: it is
     *         the one key in this system that lives on an internet-facing server, and the
     *         most it can do is award the published social rate out of a capped reserve.
     */
    bytes32 public constant CAMPAIGN_SIGNER_ROLE = keccak256("CAMPAIGN_SIGNER_ROLE");

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Bound on the payment-token allowlist, so refund/withdraw loops stay bounded (§25.1).
    uint256 public constant MAX_PAYMENT_TOKENS = 8;

    /// @dev USD scale used for prices, caps, and per-wallet accounting.
    uint256 private constant USD_SCALE = 1e6;

    /// @dev `$SS4` has 18 decimals (§5.2), fixed at compile time.
    uint256 private constant SS4_SCALE = 1e18;

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /**
     * @dev Ceiling on each configurable bonus rate, checked at configuration time.
     *      2_000 bps (20%) is far above any rate this campaign publishes; it exists so a
     *      fat-fingered configure() cannot set a rate that would drain the reserve on the
     *      first purchase, and so a reviewer can bound the contract's behaviour without
     *      trusting the deployment inputs.
     */
    uint16 private constant MAX_BONUS_BPS = 2_000;

    /// @dev EIP-712 type hash for the social-task attestation. See `CampaignVoucher` below.
    bytes32 private constant CAMPAIGN_VOUCHER_TYPEHASH =
        keccak256("CampaignVoucher(address buyer,uint64 deadline,uint64 epoch)");

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum SaleState {
        Configured,
        Active,
        Ended,
        Finalized,
        Cancelled
    }

    struct PaymentToken {
        bool accepted;
        uint8 decimals;
        bool known;
    }

    /**
     * @notice The economic configuration of the sale itself. Field-for-field identical to
     *         v1, so a deployment script, an indexer or an audit checklist written against
     *         `SS4Presale.configure` applies here unchanged.
     */
    struct SaleConfig {
        uint256 saleAllocation;
        uint256 priceUsdE6;
        uint64 saleStart;
        uint64 saleEnd;
        uint64 claimStart;
        uint64 claimDeadline;
        uint16 tgeUnlockBps;
        uint64 vestCliffSeconds;
        uint64 vestDurationSeconds;
        uint256 minPurchaseUsdE6;
        uint256 maxPurchasePerWalletUsdE6;
        uint256 softCapUsdE6;
        uint256 hardCapUsdE6;
    }

    /**
     * @notice The campaign, configured and frozen as its own bundle.
     *
     * @dev    Separate from `SaleConfig` for two reasons. It keeps the sale's own terms
     *         byte-identical to v1's, so the two can be diffed; and v1's `configure()`
     *         already sat close enough to the stack limit that the config hash had to be
     *         computed in groups (see `_computeConfigHash`) — folding five more fields
     *         into that one call would have pushed it over.
     *
     * @param bonusAllocation     `$SS4` reserved for all three bonuses combined. Funded
     *                            into this contract on top of `saleAllocation` before the
     *                            freeze, and recoverable if unspent after settlement.
     * @param socialBonusBps      Rate granted against a valid voucher. 200 = 2%.
     * @param holdBonusBps        Rate granted when the buyer's native balance clears
     *                            `holdRequirementWei`. 300 = 3%.
     * @param referralBonusBps    Rate credited to the referrer on the referee's purchase.
     *                            1_000 = 10%.
     * @param holdRequirementWei  Native BOT a buyer must hold to earn `holdBonusBps`.
     *                            1e18 = 1 BOT. Zero disables the holding bonus entirely
     *                            rather than granting it to everyone.
     */
    struct CampaignConfig {
        uint256 bonusAllocation;
        uint16 socialBonusBps;
        uint16 holdBonusBps;
        uint16 referralBonusBps;
        uint256 holdRequirementWei;
    }

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------

    /// @notice The `$SS4` token being sold. Set once at deployment (§7.5).
    IERC20 public immutable ss4;

    // ---------------------------------------------------------------------
    // Frozen-at-freeze configuration (§7.5)
    // ---------------------------------------------------------------------

    uint256 public saleAllocation;
    uint256 public priceUsdE6;

    uint64 public saleStart;
    uint64 public saleEnd; // exclusive (§7.2)
    uint64 public claimStart;
    uint64 public claimDeadline;

    uint16 public tgeUnlockBps;
    uint64 public vestCliffSeconds;
    uint64 public vestDurationSeconds;

    uint256 public minPurchaseUsdE6;
    uint256 public maxPurchasePerWalletUsdE6;
    uint256 public hardCapUsdE6;
    uint256 public softCapUsdE6;

    /// @notice `$SS4` reserved for campaign and referral bonuses (§ campaign extension).
    uint256 public bonusAllocation;
    uint16 public socialBonusBps;
    uint16 public holdBonusBps;
    uint16 public referralBonusBps;
    uint256 public holdRequirementWei;

    bool public configFrozen;
    bytes32 public configHash;

    /**
     * @notice Bumped to invalidate every campaign voucher issued so far.
     * @dev    The one campaign lever that survives the freeze, and it can only ever take
     *         bonuses away, never grant them: it is the response to a leaked signer key.
     *         Economic terms stay immutable — the rate a voucher pays is frozen, this only
     *         controls whether outstanding vouchers still verify.
     */
    uint64 public campaignEpoch;

    // ---------------------------------------------------------------------
    // Payment tokens
    // ---------------------------------------------------------------------

    mapping(address => PaymentToken) public paymentTokens;
    address[] private _paymentTokenList;

    // ---------------------------------------------------------------------
    // Sale accounting
    // ---------------------------------------------------------------------

    uint256 public tokensSold;
    uint256 public tokensClaimed;
    uint256 public raisedUsdE6;

    mapping(address => uint256) public raisedByToken;
    mapping(address => uint256) public purchasedSs4;
    mapping(address => uint256) public claimedSs4;
    mapping(address => uint256) public purchasedUsdE6;
    mapping(address => mapping(address => uint256)) public contributedByToken;

    // ---------------------------------------------------------------------
    // Campaign accounting
    // ---------------------------------------------------------------------

    /// @notice `$SS4` awarded from `bonusAllocation` so far, across all three bonuses.
    uint256 public bonusAwarded;
    /// @notice Social + holding bonus earned by this wallet on its own purchases.
    mapping(address => uint256) public campaignBonusSs4;
    /// @notice Referral bonus earned by this wallet on purchases it referred.
    mapping(address => uint256) public referralBonusSs4;
    /// @notice Who referred this wallet. Bound on the first referred purchase, then fixed.
    mapping(address => address) public referrerOf;
    /// @notice How many distinct wallets this address has referred, for the dashboard.
    mapping(address => uint256) public referralCount;

    bool public finalized;
    bool public cancelled;
    mapping(address => uint256) public withdrawnByToken;

    // ---------------------------------------------------------------------
    // Events (§7.8)
    // ---------------------------------------------------------------------

    event ConfigurationFrozen(bytes32 configHash);
    event Purchase(address indexed buyer, address indexed paymentToken, uint256 paymentAmount, uint256 ss4Amount);
    event SaleFinalized(address[] paymentTokens, uint256[] totalRaisedByToken, uint256 tokensSold);
    event SaleCancelled(bytes32 reasonHash);
    event Claim(address indexed buyer, uint256 ss4Amount);
    event Refund(address indexed buyer, address indexed paymentToken, uint256 paymentAmount);
    event RaisedFundsWithdrawn(address indexed paymentToken, uint256 amount, address indexed recipient);
    event UnsoldTokensRecovered(uint256 amount, address indexed recipient);
    event PurchasesPaused(address account);
    event PurchasesUnpaused(address account);

    event PaymentTokenConfigured(address indexed token, uint8 decimals, bool accepted);
    event SaleConfigured(SaleConfig config);
    event CampaignConfigured(CampaignConfig config);
    event UnclaimedTokensSwept(uint256 amount, address indexed recipient);

    /// @notice Social and/or holding bonus credited to a buyer on one purchase.
    event CampaignBonusAccrued(address indexed buyer, uint256 socialSs4, uint256 holdSs4);
    /// @notice Referral bonus credited to `referrer` for `buyer`'s purchase.
    event ReferralAccrued(address indexed referrer, address indexed buyer, uint256 ss4Amount);
    /// @notice A wallet's referrer, recorded once and never changed afterwards.
    event ReferrerBound(address indexed buyer, address indexed referrer);
    /**
     * @notice The bonus reserve could not cover a full award; `granted` was paid instead.
     * @dev    Emitted rather than reverted on purpose — see the contract NatSpec. A
     *         monitor watching for this knows the campaign has stopped paying out.
     */
    event BonusReserveShort(uint256 requested, uint256 granted);
    event CampaignEpochBumped(uint64 epoch);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ConfigAlreadyFrozen();
    error IncompleteConfiguration();
    error InvalidSchedule();
    error InvalidVesting();
    error InvalidCaps();
    error InvalidBonusRate();
    error TooManyPaymentTokens();
    error DecimalsMismatch(uint8 expected, uint8 actual);
    error PaymentTokenNotAccepted(address token);
    error SaleNotActive(SaleState state);
    error SaleNotEnded(SaleState state);
    error SaleNotFinalized();
    error SaleNotCancelled();
    error SaleNotSettled();
    error SaleAlreadySettled();
    error InventoryNotFunded(uint256 required, uint256 held);
    error ExceedsSaleAllocation(uint256 remaining, uint256 requested);
    error ExceedsHardCap(uint256 remainingUsdE6, uint256 requestedUsdE6);
    error ExceedsWalletCap(uint256 capUsdE6, uint256 wouldBeUsdE6);
    error BelowMinimumPurchase(uint256 minUsdE6, uint256 providedUsdE6);
    error InsufficientOutput(uint256 minOut, uint256 actualOut);
    error SoftCapNotReached(uint256 softCapUsdE6, uint256 raisedUsdE6);
    error ClaimsNotOpen(uint64 claimStart);
    error NothingToClaim();
    error NothingToRefund();
    error ClaimDeadlineNotPassed(uint64 claimDeadline);
    error UnexpectedAmountReceived(uint256 expected, uint256 received);
    error ProtectedToken(address token);
    error SelfReferral();
    error VoucherExpired(uint64 deadline);
    error InvalidVoucher();

    /**
     * @param ss4_  The `$SS4` token address (§7.5); the presale is always deployed second.
     * @param admin Holds DEFAULT_ADMIN_ROLE and every operational role at deployment.
     *              MUST be handed to the production multisig/timelock before the sale
     *              opens (§22.1, §28).
     * @dev   The EIP-712 domain is versioned "2" so a signature produced for this campaign
     *        can never be replayed against a future v3 sale at a different address.
     */
    constructor(address ss4_, address admin) EIP712("SS4Presale", "2") {
        if (ss4_ == address(0) || admin == address(0)) revert ZeroAddress();
        ss4 = IERC20(ss4_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(SALE_FINALIZER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        // CAMPAIGN_SIGNER_ROLE is deliberately NOT granted here. It belongs to the backend
        // signing key, which does not exist at deploy time and must never default to admin.
    }

    // =====================================================================
    // Configuration — all of it is rejected once the sale is frozen (§7.5)
    // =====================================================================

    modifier whileConfigurable() {
        if (configFrozen) revert ConfigAlreadyFrozen();
        _;
    }

    /// @notice Allowlist a stablecoin, or stop accepting one (§7.3). See v1 NatSpec.
    function setPaymentToken(address token, uint8 expectedDecimals, bool accepted)
        external
        onlyRole(CONFIG_ROLE)
        whileConfigurable
    {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(ss4)) revert ProtectedToken(token);

        uint8 actual = IERC20Metadata(token).decimals();
        if (actual != expectedDecimals) revert DecimalsMismatch(expectedDecimals, actual);

        PaymentToken storage config = paymentTokens[token];
        if (!config.known) {
            if (_paymentTokenList.length >= MAX_PAYMENT_TOKENS) revert TooManyPaymentTokens();
            _paymentTokenList.push(token);
            config.known = true;
        }
        config.decimals = actual;
        config.accepted = accepted;

        emit PaymentTokenConfigured(token, actual, accepted);
    }

    /// @notice Set every economic parameter of the sale in one atomic call (§7.5). See v1 NatSpec.
    function configure(SaleConfig calldata cfg) external onlyRole(CONFIG_ROLE) whileConfigurable {
        if (cfg.saleAllocation == 0 || cfg.priceUsdE6 == 0) revert ZeroAmount();

        if (cfg.saleStart == 0 || cfg.saleStart >= cfg.saleEnd || cfg.claimStart < cfg.saleEnd) {
            revert InvalidSchedule();
        }
        if (cfg.claimDeadline != 0 && cfg.claimDeadline <= cfg.claimStart) revert InvalidSchedule();

        if (cfg.hardCapUsdE6 == 0) revert InvalidCaps();
        if (cfg.softCapUsdE6 > cfg.hardCapUsdE6) revert InvalidCaps();
        if (cfg.maxPurchasePerWalletUsdE6 != 0 && cfg.maxPurchasePerWalletUsdE6 < cfg.minPurchaseUsdE6) {
            revert InvalidCaps();
        }
        if (cfg.minPurchaseUsdE6 > cfg.hardCapUsdE6) revert InvalidCaps();

        if (cfg.tgeUnlockBps > BPS_DENOMINATOR) revert InvalidVesting();
        if (cfg.tgeUnlockBps < BPS_DENOMINATOR && cfg.vestDurationSeconds == 0) revert InvalidVesting();
        if (cfg.tgeUnlockBps == BPS_DENOMINATOR && (cfg.vestCliffSeconds != 0 || cfg.vestDurationSeconds != 0)) {
            revert InvalidVesting();
        }

        saleAllocation = cfg.saleAllocation;
        priceUsdE6 = cfg.priceUsdE6;
        saleStart = cfg.saleStart;
        saleEnd = cfg.saleEnd;
        claimStart = cfg.claimStart;
        claimDeadline = cfg.claimDeadline;
        tgeUnlockBps = cfg.tgeUnlockBps;
        vestCliffSeconds = cfg.vestCliffSeconds;
        vestDurationSeconds = cfg.vestDurationSeconds;
        minPurchaseUsdE6 = cfg.minPurchaseUsdE6;
        maxPurchasePerWalletUsdE6 = cfg.maxPurchasePerWalletUsdE6;
        softCapUsdE6 = cfg.softCapUsdE6;
        hardCapUsdE6 = cfg.hardCapUsdE6;

        emit SaleConfigured(cfg);
    }

    /**
     * @notice Set the campaign's reserve and its three rates, as one bundle (§7.5).
     * @dev    Frozen by the same `freezeConfiguration()` call as the sale terms, and
     *         included in the same `configHash`, because a buyer earning a published bonus
     *         is relying on it exactly as much as on the price.
     *
     *         A zero `bonusAllocation` is a valid, explicit configuration: it runs this
     *         sale with no campaign at all, and the rates are then required to be zero too
     *         so the published terms cannot advertise a bonus that has no reserve behind it.
     */
    function configureCampaign(CampaignConfig calldata cfg) external onlyRole(CONFIG_ROLE) whileConfigurable {
        if (cfg.socialBonusBps > MAX_BONUS_BPS) revert InvalidBonusRate();
        if (cfg.holdBonusBps > MAX_BONUS_BPS) revert InvalidBonusRate();
        if (cfg.referralBonusBps > MAX_BONUS_BPS) revert InvalidBonusRate();

        bool anyRate = cfg.socialBonusBps != 0 || cfg.holdBonusBps != 0 || cfg.referralBonusBps != 0;
        if (cfg.bonusAllocation == 0 && anyRate) revert InvalidBonusRate();
        // A holding bonus with no threshold would pay every wallet on earth; require the
        // pair to be set or cleared together rather than silently treating 0 as "anyone".
        if ((cfg.holdBonusBps == 0) != (cfg.holdRequirementWei == 0)) revert InvalidBonusRate();

        bonusAllocation = cfg.bonusAllocation;
        socialBonusBps = cfg.socialBonusBps;
        holdBonusBps = cfg.holdBonusBps;
        referralBonusBps = cfg.referralBonusBps;
        holdRequirementWei = cfg.holdRequirementWei;

        emit CampaignConfigured(cfg);
    }

    /**
     * @notice One-way freeze of every economic parameter, sale and campaign alike (§7.5).
     * @dev    The funding gate now covers both pools: the contract must already hold the
     *         sale allocation AND the full bonus reserve. A campaign that could run out
     *         because it was never funded is worse than no campaign — it would pay the
     *         earliest buyers and silently stop.
     */
    function freezeConfiguration() external onlyRole(CONFIG_ROLE) whileConfigurable {
        if (saleAllocation == 0 || priceUsdE6 == 0) revert IncompleteConfiguration();
        if (saleStart == 0 || hardCapUsdE6 == 0) revert IncompleteConfiguration();
        if (tgeUnlockBps == 0 && vestDurationSeconds == 0) revert IncompleteConfiguration();

        uint256 acceptedCount;
        uint256 length = _paymentTokenList.length;
        for (uint256 i; i < length; ++i) {
            if (paymentTokens[_paymentTokenList[i]].accepted) ++acceptedCount;
        }
        if (acceptedCount == 0) revert IncompleteConfiguration();

        uint256 required = saleAllocation + bonusAllocation;
        uint256 held = ss4.balanceOf(address(this));
        if (held < required) revert InventoryNotFunded(required, held);

        configFrozen = true;
        configHash = _computeConfigHash();
        emit ConfigurationFrozen(configHash);
    }

    /**
     * @notice Invalidate every campaign voucher signed so far.
     * @dev    Post-freeze on purpose, and admin-only: it is the break-glass response to a
     *         leaked signer key. It can only reduce what the campaign pays, never increase
     *         it, which is why it does not violate the freeze — the published rates and
     *         reserve are untouched.
     */
    function bumpCampaignEpoch() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint64) {
        unchecked {
            campaignEpoch += 1;
        }
        emit CampaignEpochBumped(campaignEpoch);
        return campaignEpoch;
    }

    // =====================================================================
    // Purchasing (§7.4, §7.7)
    // =====================================================================

    /**
     * @notice Buy `$SS4` at the frozen fixed price, with no referrer and no social voucher.
     * @dev    ABI-compatible with v1's `buy`, so an integration written against the v1
     *         sale keeps working. It still earns the holding bonus: that one is read from
     *         the chain rather than presented by the caller, so there is nothing for a
     *         buyer to opt into and no reason to make them.
     */
    function buy(address paymentToken, uint256 paymentAmount, uint256 minSs4Out)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ss4Out)
    {
        return _buy(paymentToken, paymentAmount, minSs4Out, address(0), false);
    }

    /// @notice `buy` crediting a referrer. Reverts on self-referral rather than ignoring it.
    function buyWithReferral(address paymentToken, uint256 paymentAmount, uint256 minSs4Out, address referrer)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ss4Out)
    {
        return _buy(paymentToken, paymentAmount, minSs4Out, referrer, false);
    }

    /**
     * @notice `buy` presenting a backend-signed attestation that the social tasks are done.
     * @param referrer  The referring wallet, or `address(0)` for none.
     * @param deadline  Voucher expiry, in Unix seconds. The backend issues short-lived
     *                  vouchers so a wallet that later unfollows cannot keep earning.
     * @param signature EIP-712 signature over `CampaignVoucher(buyer, deadline, epoch)`
     *                  by a holder of `CAMPAIGN_SIGNER_ROLE`.
     * @dev   An invalid or expired voucher REVERTS rather than quietly filling at the
     *        smaller bonus. A buyer who took the trouble to present one is entitled to
     *        know it was refused before their stablecoins move, not to discover it in an
     *        event log afterwards.
     */
    function buyWithCampaign(
        address paymentToken,
        uint256 paymentAmount,
        uint256 minSs4Out,
        address referrer,
        uint64 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused returns (uint256 ss4Out) {
        _requireValidVoucher(msg.sender, deadline, signature);
        return _buy(paymentToken, paymentAmount, minSs4Out, referrer, true);
    }

    /// @notice `buy` preceded by an ERC-2612 permit. See v1 NatSpec for the try/catch rationale.
    function buyWithPermit(
        address paymentToken,
        uint256 paymentAmount,
        uint256 minSs4Out,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint256 ss4Out) {
        try IERC20Permit(paymentToken).permit(msg.sender, address(this), paymentAmount, deadline, v, r, s) {} catch {}
        return _buy(paymentToken, paymentAmount, minSs4Out, address(0), false);
    }

    /**
     * @dev Split into check / effects / collect rather than written straight through as v1
     *      does. v1's `_buy` took three arguments and already sat near the stack limit;
     *      with the referrer and the voucher flag added, the straight-through form does not
     *      compile at all ("stack too deep" at the transfer). The three frames keep each
     *      one small enough without reaching for `via-ir`, which would change the bytecode
     *      of every other contract in this repository.
     */
    function _buy(
        address paymentToken,
        uint256 paymentAmount,
        uint256 minSs4Out,
        address referrer,
        bool socialVerified
    ) private returns (uint256 ss4Out) {
        uint256 usdE6;
        (usdE6, ss4Out) = _checkAndQuote(paymentToken, paymentAmount, minSs4Out);

        // Effects before the interaction (§25.1).
        tokensSold += ss4Out;
        raisedUsdE6 += usdE6;
        raisedByToken[paymentToken] += paymentAmount;
        purchasedSs4[msg.sender] += ss4Out;
        purchasedUsdE6[msg.sender] += usdE6;
        contributedByToken[msg.sender][paymentToken] += paymentAmount;

        // Campaign effects, also before the interaction. Every one of these is capped by
        // the reserve and none of them can revert the purchase.
        _accrueCampaign(ss4Out, socialVerified);
        _accrueReferral(ss4Out, referrer);

        _collect(paymentToken, paymentAmount);

        emit Purchase(msg.sender, paymentToken, paymentAmount, ss4Out);
    }

    /// @dev Every reason a purchase can be refused, and the quote it is refused against.
    function _checkAndQuote(address paymentToken, uint256 paymentAmount, uint256 minSs4Out)
        private
        view
        returns (uint256 usdE6, uint256 ss4Out)
    {
        SaleState currentState = state();
        if (currentState != SaleState.Active) revert SaleNotActive(currentState);

        PaymentToken memory config = paymentTokens[paymentToken];
        if (!config.accepted) revert PaymentTokenNotAccepted(paymentToken);
        if (paymentAmount == 0) revert ZeroAmount();

        (usdE6, ss4Out) = _quote(paymentAmount, config.decimals);
        if (ss4Out == 0) revert ZeroAmount();
        if (ss4Out < minSs4Out) revert InsufficientOutput(minSs4Out, ss4Out);
        if (usdE6 < minPurchaseUsdE6) revert BelowMinimumPurchase(minPurchaseUsdE6, usdE6);

        uint256 remainingUsdE6 = hardCapUsdE6 - raisedUsdE6;
        if (usdE6 > remainingUsdE6) revert ExceedsHardCap(remainingUsdE6, usdE6);

        uint256 remainingTokens = saleAllocation - tokensSold;
        if (ss4Out > remainingTokens) revert ExceedsSaleAllocation(remainingTokens, ss4Out);

        uint256 walletTotalUsdE6 = purchasedUsdE6[msg.sender] + usdE6;
        if (maxPurchasePerWalletUsdE6 != 0 && walletTotalUsdE6 > maxPurchasePerWalletUsdE6) {
            revert ExceedsWalletCap(maxPurchasePerWalletUsdE6, walletTotalUsdE6);
        }
    }

    /**
     * @dev Takes the stablecoin and asserts the contract actually received it, by measuring
     *      its own balance delta — which rejects fee-on-transfer and rebasing tokens (the
     *      same guard as v1 and StablecoinGamePassCheckout) and works with return-less
     *      tokens like USDT through SafeERC20.
     */
    function _collect(address paymentToken, uint256 paymentAmount) private {
        uint256 balanceBefore = IERC20(paymentToken).balanceOf(address(this));
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);
        uint256 received = IERC20(paymentToken).balanceOf(address(this)) - balanceBefore;
        if (received != paymentAmount) revert UnexpectedAmountReceived(paymentAmount, received);
    }

    /**
     * @dev The buyer's own two bonuses. The holding check reads `msg.sender.balance`, which
     *      at this point in the transaction has already had the gas prepayment deducted —
     *      documented in the contract NatSpec because it is the difference between "hold
     *      1 BOT" and "hold 1 BOT and be able to pay for the transaction".
     */
    function _accrueCampaign(uint256 ss4Out, bool socialVerified) private {
        uint256 social = socialVerified ? _award(msg.sender, ss4Out, socialBonusBps, true) : 0;

        uint256 hold;
        if (holdRequirementWei != 0 && msg.sender.balance >= holdRequirementWei) {
            hold = _award(msg.sender, ss4Out, holdBonusBps, true);
        }

        if (social != 0 || hold != 0) emit CampaignBonusAccrued(msg.sender, social, hold);
    }

    /**
     * @dev Referral attribution. The referrer is bound on the first referred purchase and
     *      every later `referrer` argument from the same wallet is ignored in favour of it,
     *      so a buyer cannot re-attribute earlier purchases by changing links, and a
     *      referrer cannot be displaced by a competitor's link on a repeat buy.
     */
    function _accrueReferral(uint256 ss4Out, address referrer) private {
        address bound = referrerOf[msg.sender];

        if (bound == address(0)) {
            if (referrer == address(0)) return;
            if (referrer == msg.sender) revert SelfReferral();
            referrerOf[msg.sender] = referrer;
            unchecked {
                referralCount[referrer] += 1;
            }
            bound = referrer;
            emit ReferrerBound(msg.sender, referrer);
        } else if (referrer == msg.sender) {
            // Still an error worth surfacing: the caller is presenting their own address.
            revert SelfReferral();
        }

        uint256 amount = _award(bound, ss4Out, referralBonusBps, false);
        if (amount != 0) emit ReferralAccrued(bound, msg.sender, amount);
    }

    /**
     * @dev Credits `base * bps` to `to`, clamped to what is left of the reserve.
     *      Returns what was actually credited. Never reverts: a spent marketing budget
     *      must not be able to stop the sale (see the contract NatSpec).
     */
    function _award(address to, uint256 base, uint16 bps, bool ownBonus) private returns (uint256 granted) {
        if (bps == 0) return 0;

        uint256 requested = Math.mulDiv(base, bps, BPS_DENOMINATOR);
        if (requested == 0) return 0;

        uint256 remaining = bonusAllocation - bonusAwarded;
        granted = requested > remaining ? remaining : requested;
        if (granted == 0) {
            emit BonusReserveShort(requested, 0);
            return 0;
        }

        bonusAwarded += granted;
        if (ownBonus) {
            campaignBonusSs4[to] += granted;
        } else {
            referralBonusSs4[to] += granted;
        }

        if (granted < requested) emit BonusReserveShort(requested, granted);
    }

    /**
     * @dev Verifies a social-task attestation. Bound to this contract and chain by the
     *      EIP-712 domain, to the buyer by `buyer`, to a time window by `deadline`, and to
     *      the current campaign generation by `epoch`.
     */
    function _requireValidVoucher(address buyer, uint64 deadline, bytes calldata signature) private view {
        if (block.timestamp > deadline) revert VoucherExpired(deadline);

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(CAMPAIGN_VOUCHER_TYPEHASH, buyer, deadline, campaignEpoch)));

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidVoucher();
        if (!hasRole(CAMPAIGN_SIGNER_ROLE, recovered)) revert InvalidVoucher();
    }

    // =====================================================================
    // Settlement (§7.1)
    // =====================================================================

    function finalize() external onlyRole(SALE_FINALIZER_ROLE) {
        SaleState currentState = state();
        if (currentState != SaleState.Ended) revert SaleNotEnded(currentState);
        if (raisedUsdE6 < softCapUsdE6) revert SoftCapNotReached(softCapUsdE6, raisedUsdE6);

        finalized = true;

        uint256 length = _paymentTokenList.length;
        address[] memory tokens = new address[](length);
        uint256[] memory totals = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            tokens[i] = _paymentTokenList[i];
            totals[i] = raisedByToken[tokens[i]];
        }
        emit SaleFinalized(tokens, totals, tokensSold);
    }

    function cancelSale(bytes32 reasonHash) external onlyRole(SALE_FINALIZER_ROLE) {
        if (finalized || cancelled) revert SaleAlreadySettled();
        cancelled = true;
        emit SaleCancelled(reasonHash);
    }

    function cancelIfSoftCapMissed() external {
        if (finalized || cancelled) revert SaleAlreadySettled();
        if (softCapUsdE6 == 0) revert InvalidCaps();
        SaleState currentState = state();
        if (currentState != SaleState.Ended) revert SaleNotEnded(currentState);
        if (raisedUsdE6 >= softCapUsdE6) revert SoftCapNotReached(softCapUsdE6, raisedUsdE6);

        cancelled = true;
        emit SaleCancelled(keccak256("SOFT_CAP_MISSED"));
    }

    // =====================================================================
    // Claims and refunds — pull model only (§7.7)
    // =====================================================================

    /// @notice Claim the vested portion of purchased `$SS4`, bonuses included.
    function claim() external nonReentrant returns (uint256 amount) {
        if (!finalized) revert SaleNotFinalized();
        if (block.timestamp < claimStart) revert ClaimsNotOpen(claimStart);

        amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();

        claimedSs4[msg.sender] += amount;
        tokensClaimed += amount;

        ss4.safeTransfer(msg.sender, amount);
        emit Claim(msg.sender, amount);
    }

    /**
     * @notice Refund every stablecoin this wallet paid in, after a cancellation.
     * @dev    The wallet's campaign bonus is zeroed alongside its purchase: a cancelled
     *         sale pays no bonuses. Referral credit earned BY this wallet is deliberately
     *         left alone rather than unwound — `claim()` is gated on `finalized`, and a
     *         cancelled sale can never reach that state, so every entitlement in the
     *         contract is already unreachable. Unwinding it would mean walking the set of
     *         referees, which is exactly the unbounded per-buyer loop §7.7 forbids.
     */
    function refund() external nonReentrant returns (uint256 refundedTokenCount) {
        if (!cancelled) revert SaleNotCancelled();

        purchasedSs4[msg.sender] = 0;
        purchasedUsdE6[msg.sender] = 0;
        campaignBonusSs4[msg.sender] = 0;

        uint256 length = _paymentTokenList.length;
        for (uint256 i; i < length; ++i) {
            address token = _paymentTokenList[i];
            uint256 amount = contributedByToken[msg.sender][token];
            if (amount == 0) continue;

            contributedByToken[msg.sender][token] = 0;
            raisedByToken[token] -= amount;
            unchecked {
                ++refundedTokenCount;
            }

            IERC20(token).safeTransfer(msg.sender, amount);
            emit Refund(msg.sender, token, amount);
        }

        if (refundedTokenCount == 0) revert NothingToRefund();
    }

    // =====================================================================
    // Treasury operations — all gated on successful finalization (§7.7, §25.3)
    // =====================================================================

    function withdrawRaisedFunds(address to) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (!finalized) revert SaleNotFinalized();
        if (to == address(0)) revert ZeroAddress();

        uint256 length = _paymentTokenList.length;
        for (uint256 i; i < length; ++i) {
            address token = _paymentTokenList[i];
            uint256 amount = raisedByToken[token] - withdrawnByToken[token];
            if (amount == 0) continue;

            withdrawnByToken[token] = raisedByToken[token];
            IERC20(token).safeTransfer(to, amount);
            emit RaisedFundsWithdrawn(token, amount, to);
        }
    }

    /**
     * @notice Return `$SS4` that was never sold or awarded, to its originating pool.
     * @dev    Now covers the unspent bonus reserve as well as unsold inventory: both are
     *         "held but owed to nobody", and `_recoverableSs4` counts awarded bonuses as
     *         owed, so recovery still cannot reach a token behind an outstanding claim.
     */
    function recoverUnsoldTokens(address to) external onlyRole(TREASURY_ROLE) nonReentrant returns (uint256 amount) {
        if (!finalized && !cancelled) revert SaleNotSettled();
        if (to == address(0)) revert ZeroAddress();

        amount = _recoverableSs4();
        if (amount == 0) revert ZeroAmount();

        ss4.safeTransfer(to, amount);
        emit UnsoldTokensRecovered(amount, to);
    }

    function sweepUnclaimedTokens(address to) external onlyRole(TREASURY_ROLE) nonReentrant returns (uint256 amount) {
        if (!finalized) revert SaleNotFinalized();
        if (to == address(0)) revert ZeroAddress();
        if (claimDeadline == 0 || block.timestamp < claimDeadline) revert ClaimDeadlineNotPassed(claimDeadline);

        amount = ss4.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        ss4.safeTransfer(to, amount);
        emit UnclaimedTokensSwept(amount, to);
    }

    function recoverUnsupportedToken(address token, address to) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(ss4) || paymentTokens[token].known) revert ProtectedToken(token);

        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
    }

    // =====================================================================
    // Pause — new purchases only (§22.3)
    // =====================================================================

    function pausePurchases() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit PurchasesPaused(msg.sender);
    }

    function unpausePurchases() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit PurchasesUnpaused(msg.sender);
    }

    // =====================================================================
    // Views
    // =====================================================================

    function state() public view returns (SaleState) {
        if (cancelled) return SaleState.Cancelled;
        if (finalized) return SaleState.Finalized;
        if (!configFrozen || block.timestamp < saleStart) return SaleState.Configured;
        if (block.timestamp >= saleEnd || tokensSold >= saleAllocation || raisedUsdE6 >= hardCapUsdE6) {
            return SaleState.Ended;
        }
        return SaleState.Active;
    }

    function previewPurchase(address paymentToken, uint256 paymentAmount)
        external
        view
        returns (uint256 usdE6, uint256 ss4Out)
    {
        PaymentToken memory config = paymentTokens[paymentToken];
        if (!config.known) revert PaymentTokenNotAccepted(paymentToken);
        return _quote(paymentAmount, config.decimals);
    }

    /**
     * @notice What a purchase of `ss4Out` would earn `buyer` in bonuses right now.
     * @dev    The card on the presale page quotes from this rather than recomputing the
     *         rates in TypeScript: a UI that derives the bonus itself will disagree with
     *         the chain the moment the reserve runs low, and it is the disagreement, not
     *         the shortfall, that reads as a bug to a buyer.
     * @param  socialVerified Whether the caller holds a currently valid voucher — the UI
     *                        knows this from the backend, the chain cannot know it here.
     * @return social  `$SS4` from the social-task bonus.
     * @return hold    `$SS4` from the BOT-holding bonus, using `buyer`'s balance right now.
     * @return referral `$SS4` the buyer's bound referrer would earn, 0 if none is bound.
     */
    function quoteBonus(address buyer, uint256 ss4Out, bool socialVerified)
        external
        view
        returns (uint256 social, uint256 hold, uint256 referral)
    {
        uint256 remaining = bonusAllocation - bonusAwarded;

        if (socialVerified) {
            social = Math.mulDiv(ss4Out, socialBonusBps, BPS_DENOMINATOR);
            if (social > remaining) social = remaining;
            remaining -= social;
        }

        if (holdRequirementWei != 0 && buyer.balance >= holdRequirementWei) {
            hold = Math.mulDiv(ss4Out, holdBonusBps, BPS_DENOMINATOR);
            if (hold > remaining) hold = remaining;
            remaining -= hold;
        }

        if (referrerOf[buyer] != address(0)) {
            referral = Math.mulDiv(ss4Out, referralBonusBps, BPS_DENOMINATOR);
            if (referral > remaining) referral = remaining;
        }
    }

    /// @notice `$SS4` left in the campaign reserve.
    function bonusRemaining() external view returns (uint256) {
        return bonusAllocation - bonusAwarded;
    }

    /// @notice Everything this account is owed by the sale: purchase plus both bonus kinds.
    function totalEntitlement(address account) public view returns (uint256) {
        return purchasedSs4[account] + campaignBonusSs4[account] + referralBonusSs4[account];
    }

    /// @notice `$SS4` this account can withdraw right now.
    function claimable(address account) public view returns (uint256) {
        if (!finalized) return 0;
        return vestedAmount(account, uint64(block.timestamp)) - claimedSs4[account];
    }

    /**
     * @notice `$SS4` released to this account by `timestamp`, ignoring what it already took.
     * @dev    Vests the whole entitlement — purchase and bonuses on one schedule. Bonuses
     *         are part of what the sale sold this wallet; releasing them on a different
     *         curve would mean two claim buttons and two sets of arithmetic for a buyer to
     *         reconcile.
     */
    function vestedAmount(address account, uint64 timestamp) public view returns (uint256) {
        uint256 total = totalEntitlement(account);
        if (total == 0 || timestamp < claimStart) return 0;

        uint256 upfront = Math.mulDiv(total, tgeUnlockBps, BPS_DENOMINATOR);
        if (tgeUnlockBps == BPS_DENOMINATOR) return total;

        uint256 remainder = total - upfront;
        uint64 vestStart = claimStart + vestCliffSeconds;
        if (timestamp < vestStart) return upfront;

        uint64 vestEnd = vestStart + vestDurationSeconds;
        if (timestamp >= vestEnd) return total;

        return upfront + Math.mulDiv(remainder, timestamp - vestStart, vestDurationSeconds);
    }

    function refundable(address account, address paymentToken) external view returns (uint256) {
        if (!cancelled) return 0;
        return contributedByToken[account][paymentToken];
    }

    /// @notice `$SS4` still owed to buyers who have not claimed yet, bonuses included.
    function outstandingEntitlement() public view returns (uint256) {
        return (tokensSold + bonusAwarded) - tokensClaimed;
    }

    function recoverableSs4() external view returns (uint256) {
        return _recoverableSs4();
    }

    function paymentTokenList() external view returns (address[] memory) {
        return _paymentTokenList;
    }

    function paymentTokenCount() external view returns (uint256) {
        return _paymentTokenList.length;
    }

    /// @notice The EIP-712 domain separator vouchers are signed under, for the backend.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The digest a voucher for `buyer` expiring at `deadline` must be signed over.
    function campaignVoucherDigest(address buyer, uint64 deadline) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CAMPAIGN_VOUCHER_TYPEHASH, buyer, deadline, campaignEpoch)));
    }

    // =====================================================================
    // Internals
    // =====================================================================

    /**
     * @dev Grouped rather than one flat `abi.encode` for the reason v1 documents: the flat
     *      form needs every field live on the stack at once. The campaign is its own group,
     *      appended after the schedule, so a v1 hash and a v2 hash are never comparable —
     *      which is correct, they are different sales.
     */
    function _computeConfigHash() private view returns (bytes32) {
        bytes32 wiring = keccak256(abi.encode(block.chainid, address(this), address(ss4), _paymentTokenList));
        bytes32 economics = keccak256(
            abi.encode(
                saleAllocation, priceUsdE6, minPurchaseUsdE6, maxPurchasePerWalletUsdE6, softCapUsdE6, hardCapUsdE6
            )
        );
        bytes32 schedule = keccak256(
            abi.encode(
                saleStart, saleEnd, claimStart, claimDeadline, tgeUnlockBps, vestCliffSeconds, vestDurationSeconds
            )
        );
        bytes32 campaign = keccak256(
            abi.encode(bonusAllocation, socialBonusBps, holdBonusBps, referralBonusBps, holdRequirementWei)
        );
        return keccak256(abi.encode(wiring, economics, schedule, campaign));
    }

    function _quote(uint256 paymentAmount, uint8 decimals) private view returns (uint256 usdE6, uint256 ss4Out) {
        usdE6 = Math.mulDiv(paymentAmount, USD_SCALE, 10 ** decimals);
        ss4Out = Math.mulDiv(usdE6, SS4_SCALE, priceUsdE6);
    }

    function _recoverableSs4() private view returns (uint256) {
        uint256 held = ss4.balanceOf(address(this));
        // A cancelled sale owes no `$SS4` at all — claims are gated on finalization.
        if (cancelled) return held;
        uint256 owed = outstandingEntitlement();
        return held > owed ? held - owed : 0;
    }
}
