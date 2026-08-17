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
 * @title SS4PresaleV3
 * @notice `SS4PresaleV2` with the Early Supporter Campaign's *variable* Presale Boost in place of
 *         v2's three fixed bonus rates. Implements the SS4 Smart-Contract Implementation Outline §7
 *         with the Early Supporter Campaign extension.
 *
 * @dev    WHY A THIRD SALE CONTRACT. The Early Supporter Campaign pays a boost that depends on which
 *         of twenty-one missions a wallet completed — anywhere from 0 to the published 5.50% maximum,
 *         in 0.05% steps. v2 cannot express that. Its voucher deliberately carries no amount, so the
 *         only rate it can pay is the single `socialBonusBps` frozen into its config; and its config
 *         IS frozen (`configFrozen == true` on the live deployment), so there is no call that could
 *         widen it. A per-wallet rate therefore has to travel *in* the attestation, which is a
 *         different voucher type, a different digest, and a different sale.
 *
 *         Everything v2 inherited from v1 is preserved verbatim here in turn: lifecycle,
 *         USD-normalized accounting, pull-only claims and refunds, the settlement gates on treasury
 *         operations. Read the v1 NatSpec for those. This file documents only what v3 changes.
 *
 *         ---------------------------------------------------------------------------------------
 *         ONE BOOST, NOT THREE BONUSES.
 *
 *         v2 split the campaign across three mechanisms: a signed social attestation (2%), a
 *         trustless native-balance read (3%), and a referral payout to the referrer (10% of the
 *         referee's purchase). v3 collapses all of it into a single `boostBps` carried by the
 *         voucher, because the campaign it now serves is scored off-chain across three sections:
 *
 *           Join the Community   up to +1.10%   (X, Telegram, engagement, verified referral)
 *           Record On-Chain      up to +2.60%   (BOT/USDT holdings, DCA plans and executions)
 *           Game Activity        up to +1.80%   (Echo Arena sessions, Game Pass purchase)
 *                                ------------
 *           Campaign maximum          +5.50%
 *
 *         Most of those are facts no EVM can read — a follow, a Telegram join, an Echo Arena session,
 *         a Game Pass bought on a different chain. Splitting the boost into "the part the chain can
 *         verify" and "the part the backend attests" would put two numbers on the page that have to
 *         sum to the cap, with neither side able to check the other's half; the contract would be
 *         unable to enforce the published 5.50% at all. So the backend scores every mission from
 *         authoritative records (its own Supabase tables, BOT Chain RPC reads, the Echo Arena run
 *         ledger) and attests the total, and this contract enforces the one invariant that matters
 *         economically: **no wallet is ever granted more than the published maximum.**
 *
 *         WHAT THAT COSTS, STATED PLAINLY. v2's holding bonus needed no trust at all; v3's
 *         equivalent mission is attested. A stolen signer key can therefore grant up to
 *         `maxCampaignBoostBps` to a wallet that earned nothing, where in v2 it could grant 2%. Four
 *         things bound that, and they are the reason this shape is defensible:
 *
 *           1. `maxCampaignBoostBps` is frozen into `configHash` alongside the price. The key cannot
 *              exceed the campaign the sale published, however it is abused.
 *           2. `bonusAllocation` is a funded, frozen reserve. Awards clamp to what is left of it, so
 *              the total exposure is bounded before the sale opens and cannot reach sale inventory.
 *           3. Every voucher is single-use, bound to one `(buyer, nonce)` pair. A voucher cannot be
 *              replayed across purchases, so a leak grants what the backend signed and nothing more.
 *           4. `bumpCampaignEpoch()` invalidates every outstanding voucher in one admin call. It
 *              survives the freeze precisely because it can only ever take boosts away.
 *
 *         REFERRALS ARE ATTRIBUTION ONLY. `referrerOf` / `referralCount` / `ReferrerBound` are kept,
 *         but v2's referral *payout* is gone: the campaign now rewards a verified referral as a
 *         +0.20% mission on the referrer's own boost, and paying 10% of the referee's purchase on top
 *         would reward the same referral twice under two different rules. What stays is the tamper-
 *         proof record — bound on a wallet's first referred purchase, ignored forever after — which
 *         is what lets the backend qualify a referral against the chain rather than its own logs.
 *
 *         The top-3 buyer prizes remain off-chain against the public `Purchase` record, as in v2.
 */
contract SS4PresaleV3 is AccessControl, Pausable, ReentrancyGuard, EIP712 {
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
     * @notice Signs campaign vouchers attesting the boost a wallet has earned.
     * @dev    A hot backend key, held deliberately apart from every other role: it is the one key in
     *         this system that lives on an internet-facing server, and the most it can do is award up
     *         to the published maximum out of a capped reserve. See the contract NatSpec for the four
     *         bounds on that, and rotate with `grantRole`/`revokeRole` + `bumpCampaignEpoch()`.
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
     * @dev Ceiling on the configurable campaign maximum, checked at configuration time.
     *      2_000 bps (20%) is far above the 550 this campaign publishes; it exists so a fat-fingered
     *      `configureCampaign()` cannot set a ceiling that would drain the reserve on the first
     *      purchase, and so a reviewer can bound the contract's behaviour without trusting the
     *      deployment inputs. Same value and same purpose as v2's `MAX_BONUS_BPS`.
     */
    uint16 private constant MAX_BOOST_CEILING_BPS = 2_000;

    /**
     * @dev EIP-712 type hash for the boost attestation.
     *
     *      Field order is the signing order and must match the backend's typed-data definition
     *      exactly. `boostBps` is what makes this voucher a v3 voucher: a v2 signature covers
     *      (buyer, deadline, epoch) only and cannot be replayed here, because a different type hash
     *      produces a different digest even under an identical domain.
     */
    bytes32 private constant CAMPAIGN_VOUCHER_TYPEHASH =
        keccak256("CampaignVoucher(address buyer,uint16 boostBps,uint64 deadline,uint64 nonce,uint64 epoch)");

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
     * @notice The economic configuration of the sale itself. Field-for-field identical to v1 and v2,
     *         so a deployment script, an indexer or an audit checklist written against
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
     * @dev    Two fields where v2 had five, because there is now one rate rather than three. Kept as
     *         a separate struct from `SaleConfig` for v2's reasons: the sale's own terms stay
     *         byte-identical to v1's so the three can be diffed, and `configure()` already sits close
     *         enough to the stack limit that its config hash is computed in groups.
     *
     * @param bonusAllocation      `$SS4` reserved for every boost this campaign pays. Funded into
     *                             this contract on top of `saleAllocation` before the freeze, and
     *                             recoverable if unspent after settlement.
     * @param maxCampaignBoostBps  The published campaign maximum, and a hard per-purchase ceiling on
     *                             what any voucher can be honoured for. 550 = 5.50%. This is the
     *                             number a buyer is relying on when they read "Maximum Presale Boost"
     *                             on the campaign page, which is why it is frozen into `configHash`
     *                             rather than left settable.
     */
    struct CampaignConfig {
        uint256 bonusAllocation;
        uint16 maxCampaignBoostBps;
    }

    /**
     * @notice A backend attestation of the Presale Boost one wallet has earned.
     *
     * @dev    Passed as a calldata struct rather than as loose arguments so `buyWithCampaign` stays
     *         at five parameters. v2's `_buy` already needed splitting into three frames to compile
     *         without `via-ir`; flattening the voucher into the signature would push the entry point
     *         itself over the stack limit.
     *
     * @param boostBps  Basis points of the purchased `$SS4` to award. Rejected above
     *                  `maxCampaignBoostBps` — see `_consumeVoucher`.
     * @param deadline  Voucher expiry, Unix seconds. The backend issues short-lived vouchers so a
     *                  wallet that unfollows, lets a pass lapse, or spends its BOT cannot keep
     *                  buying at a boost it no longer earns.
     * @param nonce     Single-use identifier scoped to `buyer`. The backend allocates it when it
     *                  issues the voucher, and this contract refuses a second purchase against it.
     * @param signature EIP-712 signature over `CampaignVoucher` by a `CAMPAIGN_SIGNER_ROLE` holder.
     */
    struct CampaignVoucher {
        uint16 boostBps;
        uint64 deadline;
        uint64 nonce;
        bytes signature;
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

    /// @notice `$SS4` reserved for campaign boosts (§ Early Supporter Campaign extension).
    uint256 public bonusAllocation;
    /// @notice The published campaign maximum, in bps. 550 = 5.50%. Frozen.
    uint16 public maxCampaignBoostBps;

    bool public configFrozen;
    bytes32 public configHash;

    /**
     * @notice Bumped to invalidate every campaign voucher issued so far.
     * @dev    The one campaign lever that survives the freeze, and it can only ever take boosts
     *         away, never grant them: it is the response to a leaked signer key. Economic terms stay
     *         immutable — the published maximum is frozen, this only controls whether outstanding
     *         vouchers still verify.
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

    /// @notice `$SS4` awarded from `bonusAllocation` so far, across every boost.
    uint256 public bonusAwarded;
    /// @notice Campaign boost `$SS4` earned by this wallet across its own purchases.
    mapping(address => uint256) public campaignBonusSs4;
    /**
     * @notice Vouchers already spent, as `buyer => nonce => used`.
     * @dev    Keyed by buyer as well as nonce so two wallets can never collide on one another's
     *         nonce space, and so the backend can allocate nonces per wallet without a global
     *         counter it would have to keep consistent across processes.
     */
    mapping(address => mapping(uint64 => bool)) public voucherUsed;
    /// @notice Who referred this wallet. Bound on the first referred purchase, then fixed.
    mapping(address => address) public referrerOf;
    /// @notice How many distinct wallets this address has referred, for the campaign dashboard.
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

    /**
     * @notice A campaign boost credited to a buyer on one purchase.
     * @dev    `boostBps` and `nonce` are both logged so the backend's own record of what it attested
     *         can be reconciled against what the chain honoured, per mission, per purchase — the
     *         audit question the campaign spec asks of every reward ("what percentage was awarded?
     *         was it already applied?").
     */
    event CampaignBoostAccrued(address indexed buyer, uint16 boostBps, uint64 nonce, uint256 ss4Amount);
    /// @notice A wallet's referrer, recorded once and never changed afterwards. Attribution only.
    event ReferrerBound(address indexed buyer, address indexed referrer);
    /**
     * @notice The bonus reserve could not cover a full award; `granted` was paid instead.
     * @dev    Emitted rather than reverted on purpose — a sale must never fail because a marketing
     *         budget is spent. A monitor watching for this knows the campaign has stopped paying out.
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
    error InvalidBoostConfig();
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
    /// @notice The voucher attested more than the campaign published. Never honoured, never clamped.
    error BoostAboveCampaignMaximum(uint16 maxBps, uint16 presentedBps);
    /// @notice This `(buyer, nonce)` voucher has already been spent on an earlier purchase.
    error VoucherAlreadyUsed(uint64 nonce);

    /**
     * @param ss4_  The `$SS4` token address (§7.5); the presale is always deployed second.
     * @param admin Holds DEFAULT_ADMIN_ROLE and every operational role at deployment.
     *              MUST be handed to the production multisig/timelock before the sale opens
     *              (§22.1, §28).
     * @dev   The EIP-712 domain is versioned "3", so a voucher signed for this campaign can never be
     *        replayed against the v2 sale and a v2 voucher can never be presented here.
     */
    constructor(address ss4_, address admin) EIP712("SS4Presale", "3") {
        if (ss4_ == address(0) || admin == address(0)) revert ZeroAddress();
        ss4 = IERC20(ss4_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(SALE_FINALIZER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        // CAMPAIGN_SIGNER_ROLE is deliberately NOT granted here. It belongs to the backend signing
        // key, which does not exist at deploy time and must never default to admin.
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
     * @notice Set the campaign's reserve and its published maximum, as one bundle (§7.5).
     * @dev    Frozen by the same `freezeConfiguration()` call as the sale terms, and included in the
     *         same `configHash`, because a buyer earning a published boost is relying on the ceiling
     *         exactly as much as on the price.
     *
     *         A zero `bonusAllocation` is a valid, explicit configuration: it runs this sale with no
     *         campaign at all, and the maximum is then required to be zero too so the published terms
     *         cannot advertise a boost that has no reserve behind it. The converse is equally
     *         refused: a funded reserve with a zero ceiling would lock `$SS4` in a campaign that can
     *         never award a single token, which is a funding mistake, not a configuration.
     */
    function configureCampaign(CampaignConfig calldata cfg) external onlyRole(CONFIG_ROLE) whileConfigurable {
        if (cfg.maxCampaignBoostBps > MAX_BOOST_CEILING_BPS) revert InvalidBoostConfig();
        if ((cfg.bonusAllocation == 0) != (cfg.maxCampaignBoostBps == 0)) revert InvalidBoostConfig();

        bonusAllocation = cfg.bonusAllocation;
        maxCampaignBoostBps = cfg.maxCampaignBoostBps;

        emit CampaignConfigured(cfg);
    }

    /**
     * @notice One-way freeze of every economic parameter, sale and campaign alike (§7.5).
     * @dev    The funding gate covers both pools: the contract must already hold the sale allocation
     *         AND the full bonus reserve. A campaign that could run out because it was never funded
     *         is worse than no campaign — it would pay the earliest buyers and silently stop.
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
     * @dev    Post-freeze on purpose, and admin-only: it is the break-glass response to a leaked
     *         signer key. It can only reduce what the campaign pays, never increase it, which is why
     *         it does not violate the freeze — the published maximum and the reserve are untouched.
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
     * @notice Buy `$SS4` at the frozen fixed price, with no referrer and no campaign boost.
     * @dev    ABI-compatible with v1 and v2's `buy`, so an integration written against either keeps
     *         working. Unlike v2 it earns nothing from the campaign: v2's holding bonus was read from
     *         the chain and so applied to a plain buy, whereas every v3 mission is scored off-chain
     *         and has to arrive in a voucher. A buyer who has earned a boost and calls this instead
     *         simply buys at the base rate — which is why the presale page requests a voucher before
     *         every purchase rather than only when the wallet asks for one.
     */
    function buy(address paymentToken, uint256 paymentAmount, uint256 minSs4Out)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ss4Out)
    {
        return _buy(paymentToken, paymentAmount, minSs4Out, address(0), 0, 0);
    }

    /// @notice `buy` recording a referrer. Reverts on self-referral rather than ignoring it.
    function buyWithReferral(address paymentToken, uint256 paymentAmount, uint256 minSs4Out, address referrer)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ss4Out)
    {
        return _buy(paymentToken, paymentAmount, minSs4Out, referrer, 0, 0);
    }

    /**
     * @notice `buy` presenting a backend-signed attestation of the campaign boost this wallet earned.
     * @param referrer The referring wallet, or `address(0)` for none. Attribution only — a referral
     *                 is rewarded through the referrer's own boost, not out of this purchase.
     * @param voucher  The signed attestation. See `CampaignVoucher`.
     * @dev   An invalid, expired, over-cap or already-spent voucher REVERTS rather than quietly
     *        filling at the base rate. A buyer who took the trouble to present one is entitled to
     *        know it was refused before their stablecoins move, not to discover it in an event log
     *        afterwards. The one thing that does not revert is a reserve that has run dry: the award
     *        clamps and the purchase completes.
     */
    function buyWithCampaign(
        address paymentToken,
        uint256 paymentAmount,
        uint256 minSs4Out,
        address referrer,
        CampaignVoucher calldata voucher
    ) external nonReentrant whenNotPaused returns (uint256 ss4Out) {
        _consumeVoucher(msg.sender, voucher);
        return _buy(paymentToken, paymentAmount, minSs4Out, referrer, voucher.boostBps, voucher.nonce);
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
        return _buy(paymentToken, paymentAmount, minSs4Out, address(0), 0, 0);
    }

    /**
     * @dev Split into check / effects / collect rather than written straight through as v1 does, for
     *      the reason v2 documents: with the referrer and the boost added, the straight-through form
     *      does not compile ("stack too deep" at the transfer). The three frames keep each one small
     *      enough without reaching for `via-ir`, which would change the bytecode of every other
     *      contract in this repository.
     */
    function _buy(
        address paymentToken,
        uint256 paymentAmount,
        uint256 minSs4Out,
        address referrer,
        uint16 boostBps,
        uint64 nonce
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

        // Campaign effects, also before the interaction. The award is capped by the reserve and
        // cannot revert the purchase; binding a referrer writes a record and pays nothing.
        _accrueBoost(ss4Out, boostBps, nonce);
        _bindReferrer(referrer);

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
     * @dev Takes the stablecoin and asserts the contract actually received it, by measuring its own
     *      balance delta — which rejects fee-on-transfer and rebasing tokens (the same guard as v1,
     *      v2 and StablecoinGamePassCheckout) and works with return-less tokens like USDT through
     *      SafeERC20.
     */
    function _collect(address paymentToken, uint256 paymentAmount) private {
        uint256 balanceBefore = IERC20(paymentToken).balanceOf(address(this));
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);
        uint256 received = IERC20(paymentToken).balanceOf(address(this)) - balanceBefore;
        if (received != paymentAmount) revert UnexpectedAmountReceived(paymentAmount, received);
    }

    /// @dev The buyer's campaign boost, clamped to the reserve. Never reverts.
    function _accrueBoost(uint256 ss4Out, uint16 boostBps, uint64 nonce) private {
        if (boostBps == 0) return;

        uint256 granted = _award(msg.sender, ss4Out, boostBps);
        if (granted != 0) emit CampaignBoostAccrued(msg.sender, boostBps, nonce, granted);
    }

    /**
     * @dev Referral attribution, and nothing else. The referrer is bound on the first referred
     *      purchase and every later `referrer` argument from the same wallet is ignored in favour of
     *      it, so a buyer cannot re-attribute earlier purchases by changing links, and a referrer
     *      cannot be displaced by a competitor's link on a repeat buy.
     *
     *      No payout happens here — see the contract NatSpec. The backend reads `ReferrerBound` and
     *      `Purchase` to qualify a referral, then pays it as a +0.20% mission on the *referrer's*
     *      next voucher.
     */
    function _bindReferrer(address referrer) private {
        if (referrerOf[msg.sender] != address(0)) {
            // Still an error worth surfacing: the caller is presenting their own address.
            if (referrer == msg.sender) revert SelfReferral();
            return;
        }
        if (referrer == address(0)) return;
        if (referrer == msg.sender) revert SelfReferral();

        referrerOf[msg.sender] = referrer;
        unchecked {
            referralCount[referrer] += 1;
        }
        emit ReferrerBound(msg.sender, referrer);
    }

    /**
     * @dev Credits `base * bps` to `to`, clamped to what is left of the reserve. Returns what was
     *      actually credited. Never reverts: a spent marketing budget must not be able to stop the
     *      sale (see the contract NatSpec).
     */
    function _award(address to, uint256 base, uint16 bps) private returns (uint256 granted) {
        uint256 requested = Math.mulDiv(base, bps, BPS_DENOMINATOR);
        if (requested == 0) return 0;

        uint256 remaining = bonusAllocation - bonusAwarded;
        granted = requested > remaining ? remaining : requested;
        if (granted == 0) {
            emit BonusReserveShort(requested, 0);
            return 0;
        }

        bonusAwarded += granted;
        campaignBonusSs4[to] += granted;

        if (granted < requested) emit BonusReserveShort(requested, granted);
    }

    /**
     * @dev Verifies a boost attestation and burns its nonce.
     *
     *      Bound to this contract and chain by the EIP-712 domain, to the buyer by `buyer`, to a
     *      rate by `boostBps`, to a time window by `deadline`, to one purchase by `nonce`, and to the
     *      current campaign generation by `epoch`.
     *
     *      The cap is checked here rather than clamped in `_award` on purpose. A voucher above the
     *      published maximum is not a large boost, it is a broken or forged attestation, and filling
     *      it silently at 5.50% would hide exactly the incident this contract exists to bound.
     */
    function _consumeVoucher(address buyer, CampaignVoucher calldata voucher) private {
        if (block.timestamp > voucher.deadline) revert VoucherExpired(voucher.deadline);
        if (voucher.boostBps > maxCampaignBoostBps) {
            revert BoostAboveCampaignMaximum(maxCampaignBoostBps, voucher.boostBps);
        }
        if (voucherUsed[buyer][voucher.nonce]) revert VoucherAlreadyUsed(voucher.nonce);

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CAMPAIGN_VOUCHER_TYPEHASH, buyer, voucher.boostBps, voucher.deadline, voucher.nonce, campaignEpoch
                )
            )
        );

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, voucher.signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidVoucher();
        if (!hasRole(CAMPAIGN_SIGNER_ROLE, recovered)) revert InvalidVoucher();

        // Burned even when `boostBps` is 0, so a nonce means one purchase either way and the
        // backend's ledger of issued vouchers reconciles against the chain without special cases.
        voucherUsed[buyer][voucher.nonce] = true;
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

    /// @notice Claim the vested portion of purchased `$SS4`, campaign boost included.
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
     * @dev    The wallet's campaign boost is zeroed alongside its purchase: a cancelled sale pays no
     *         boosts. Simpler than v2's equivalent, which also had to leave referral credit standing
     *         because unwinding it would have meant walking the set of referees — v3 has no referral
     *         payout to unwind.
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
     * @dev    Covers the unspent campaign reserve as well as unsold inventory: both are "held but
     *         owed to nobody", and `_recoverableSs4` counts awarded boosts as owed, so recovery
     *         cannot reach a token behind an outstanding claim.
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
     * @notice The `$SS4` a purchase of `ss4Out` would actually award at `boostBps`, right now.
     * @dev    The campaign card quotes from this rather than recomputing the rate in TypeScript: a UI
     *         that derives the award itself will disagree with the chain the moment the reserve runs
     *         low, and it is the disagreement, not the shortfall, that reads as a bug to a buyer.
     *
     *         `boostBps` above the published maximum returns 0 rather than the capped amount, because
     *         that is what the purchase would do — `buyWithCampaign` reverts on it.
     */
    function quoteBoost(uint256 ss4Out, uint16 boostBps) external view returns (uint256 award) {
        if (boostBps == 0 || boostBps > maxCampaignBoostBps) return 0;
        award = Math.mulDiv(ss4Out, boostBps, BPS_DENOMINATOR);
        uint256 remaining = bonusAllocation - bonusAwarded;
        if (award > remaining) award = remaining;
    }

    /// @notice `$SS4` left in the campaign reserve.
    function bonusRemaining() external view returns (uint256) {
        return bonusAllocation - bonusAwarded;
    }

    /// @notice Everything this account is owed by the sale: its purchases plus its campaign boosts.
    function totalEntitlement(address account) public view returns (uint256) {
        return purchasedSs4[account] + campaignBonusSs4[account];
    }

    /// @notice `$SS4` this account can withdraw right now.
    function claimable(address account) public view returns (uint256) {
        if (!finalized) return 0;
        return vestedAmount(account, uint64(block.timestamp)) - claimedSs4[account];
    }

    /**
     * @notice `$SS4` released to this account by `timestamp`, ignoring what it already took.
     * @dev    Vests the whole entitlement — purchase and boost on one schedule. A boost is part of
     *         what the sale sold this wallet; releasing it on a different curve would mean two claim
     *         buttons and two sets of arithmetic for a buyer to reconcile.
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

    /// @notice `$SS4` still owed to buyers who have not claimed yet, boosts included.
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

    /**
     * @notice The digest a voucher for `buyer` must be signed over.
     * @dev    Exposed so the backend can assert its own typed-data encoding against the contract's
     *         before it signs anything, and so an operator can reproduce a disputed voucher by hand.
     */
    function campaignVoucherDigest(address buyer, uint16 boostBps, uint64 deadline, uint64 nonce)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(CAMPAIGN_VOUCHER_TYPEHASH, buyer, boostBps, deadline, nonce, campaignEpoch))
        );
    }

    // =====================================================================
    // Internals
    // =====================================================================

    /**
     * @dev Grouped rather than one flat `abi.encode` for the reason v1 documents: the flat form needs
     *      every field live on the stack at once. The campaign is its own group, appended after the
     *      schedule, so a v2 hash and a v3 hash are never comparable — which is correct, they are
     *      different sales with different campaigns.
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
        bytes32 campaign = keccak256(abi.encode(bonusAllocation, maxCampaignBoostBps));
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
