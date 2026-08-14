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

/**
 * @title SS4Presale
 * @notice Fixed-price `$SS4` presale paid in allowlisted USDC/USDT.
 *         Implements the SS4 Smart-Contract Implementation Outline §7.
 *
 * @dev    Scope boundary (§4 "Hard boundary"): this contract sells an ordinary ERC-20.
 *         It knows nothing about seasons, DCA plans, membership, or the game. Buying
 *         here never creates an Autumn Leaf or a DCA season mark (§7.7); a Founding
 *         Harvest cosmetic, if offered, is derived off-chain from `Purchase` events.
 *
 *         Lifecycle (§7.1):
 *
 *             Configured -> Active -> Ended -> Finalized -> Claims open
 *                              \-> Cancelled -> Refunds open
 *
 *         `Finalized` and `Cancelled` are mutually exclusive terminal states, which is
 *         what makes the accounting safe: a buyer's stablecoins are refundable right up
 *         until finalization, and their `$SS4` is claimable only after it. Neither path
 *         can be entered twice.
 *
 *         Money model: every purchase is normalized to a nominal USD amount scaled by
 *         1e6 (`usdE6`). Caps, minimums, and the soft/hard cap are all denominated that
 *         way so one sale can accept a 6-decimal USDC and an 18-decimal Binance-Peg USDC
 *         at the same time (§7.3, §21). "$1" means one nominal unit of an approved
 *         stablecoin; this contract does not assume or guarantee a peg.
 *
 *         All economic parameters are settable only before `freezeConfiguration()` and
 *         are immutable in effect afterwards (§7.5). The sale cannot open until the
 *         configuration is frozen AND the contract holds its full `$SS4` inventory.
 */
contract SS4Presale is AccessControl, Pausable, ReentrancyGuard {
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

    /**
     * @param accepted  Whether new purchases may use this token. Turning it off never
     *                  blocks refunds of money already taken in it.
     * @param decimals  Read from the token itself at configuration time and pinned here,
     *                  so a later proxy upgrade cannot silently move the decimal point.
     * @param known     Whether this token has ever been configured (its slot in the list exists).
     */
    struct PaymentToken {
        bool accepted;
        uint8 decimals;
        bool known;
    }

    /**
     * @notice The complete economic configuration of the sale, set as one bundle and
     *         frozen as one bundle (§7.5). Every field is a §29 deployment blocker.
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

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------

    /// @notice The `$SS4` token being sold. Set once at deployment (§7.5).
    IERC20 public immutable ss4;

    // ---------------------------------------------------------------------
    // Frozen-at-freeze configuration (§7.5)
    // ---------------------------------------------------------------------

    /// @notice `$SS4` base units reserved for this sale. Must be prefunded before opening.
    uint256 public saleAllocation;
    /// @notice Price of 1e18 `$SS4` in nominal USD, scaled by 1e6. 25_000 == $0.025.
    uint256 public priceUsdE6;

    uint64 public saleStart;
    uint64 public saleEnd; // exclusive (§7.2)
    uint64 public claimStart;
    /// @notice After this, unclaimed `$SS4` may be swept per the published rule. 0 = no deadline.
    uint64 public claimDeadline;

    /// @notice Portion released at `claimStart`, in bps. 10_000 = full unlock, no vesting.
    uint16 public tgeUnlockBps;
    /// @notice Delay after `claimStart` before the vesting remainder starts accruing.
    uint64 public vestCliffSeconds;
    /// @notice Linear accrual window for the remainder, starting at the cliff.
    uint64 public vestDurationSeconds;

    uint256 public minPurchaseUsdE6;
    /// @notice Per-wallet lifetime cap. 0 = uncapped.
    uint256 public maxPurchasePerWalletUsdE6;
    /// @notice Sale stops accepting money above this. Must be nonzero.
    uint256 public hardCapUsdE6;
    /// @notice Below this at `saleEnd` the sale can only be cancelled, never finalized. 0 = none.
    uint256 public softCapUsdE6;

    /// @notice When true no economic parameter can change again (§7.5).
    bool public configFrozen;
    /// @notice Hash of the frozen economic configuration, emitted for public verification.
    bytes32 public configHash;

    // ---------------------------------------------------------------------
    // Payment tokens
    // ---------------------------------------------------------------------

    mapping(address => PaymentToken) public paymentTokens;
    /// @dev Append-only: a token that stops being accepted must stay here for refunds.
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
    /// @dev buyer => payment token => refundable amount in that token's own base units.
    mapping(address => mapping(address => uint256)) public contributedByToken;

    bool public finalized;
    bool public cancelled;
    /// @notice Proceeds already moved out after finalization, per token.
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
    event UnclaimedTokensSwept(uint256 amount, address indexed recipient);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ConfigAlreadyFrozen();
    error ConfigNotFrozen();
    error IncompleteConfiguration();
    error InvalidSchedule();
    error InvalidVesting();
    error InvalidCaps();
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

    /**
     * @param ss4_  The `$SS4` token address. Known only after the token is deployed (§7.5),
     *              so the presale is always deployed second (§30 step 5).
     * @param admin Holds DEFAULT_ADMIN_ROLE and every operational role at deployment.
     *              MUST be handed to the production multisig/timelock before the sale
     *              opens; a deployer EOA is not an acceptable final admin (§22.1, §28).
     */
    constructor(address ss4_, address admin) {
        if (ss4_ == address(0) || admin == address(0)) revert ZeroAddress();
        ss4 = IERC20(ss4_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(SALE_FINALIZER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
    }

    // =====================================================================
    // Configuration — all of it is rejected once the sale is frozen (§7.5)
    // =====================================================================

    modifier whileConfigurable() {
        if (configFrozen) revert ConfigAlreadyFrozen();
        _;
    }

    /**
     * @notice Allowlist a stablecoin, or stop accepting one (§7.3).
     * @dev    `expectedDecimals` is asserted against the token's own `decimals()`. The
     *         caller must state what it believes the token is, so a mis-pasted address
     *         with a different decimal scale fails at configuration time instead of
     *         mispricing every purchase. The value is then pinned in storage and used
     *         for all math, so a later upgrade of a proxied stablecoin cannot move it.
     *
     *         Arbitrary ERC-20s must never be added here: the price formula treats any
     *         accepted token as worth one nominal dollar per whole unit.
     */
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

    /**
     * @notice Set every economic parameter of the sale in one atomic call (§7.5).
     *
     * @dev    Deliberately one function rather than a family of setters: the sale terms
     *         are published, audited, and frozen as a single bundle, so they should also
     *         be settable as one — a half-applied configuration is never a valid state,
     *         and one call means one thing for a reviewer to compare against the approved
     *         deployment inputs. It may be called repeatedly until the freeze; each call
     *         replaces the whole bundle.
     *
     *         Schedule: `saleEnd` is exclusive. To include all of 30 August 2026 UTC,
     *         pass 2026-08-31T00:00:00Z (§7.2). There is no local-timezone interpretation
     *         anywhere in this contract; the deployment script supplies Unix seconds.
     *         A zero `claimDeadline` disables the unclaimed-token sweep entirely.
     *
     *         Vesting: implements "`tgeUnlockBps` at `claimStart`, then the remainder
     *         accruing linearly from `claimStart + cliff` over `vestDuration`". The
     *         remainder starts from zero at the cliff, so there is no catch-up lump at
     *         the cliff — the exact hazard §6.1 flags for the team schedule.
     *         `tgeUnlockBps == 10_000` means a plain full unlock with no vesting.
     */
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
        // A partial TGE unlock with no vesting window would strand the remainder forever.
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
     * @notice One-way freeze of every economic parameter (§7.5).
     * @dev    This is the deployment gate demanded by §28.7: it rejects any TBD
     *         placeholder left at zero — no price, no allocation, no schedule, no hard
     *         cap, no accepted stablecoin. It also requires the full `$SS4` inventory to
     *         already be sitting in this contract (§7.7 "must be fully funded ... before
     *         purchases open"), which is why funding is checked here rather than trusted
     *         on the day of the sale.
     *
     *         The emitted `configHash` lets anyone verify the live sale against the
     *         published terms without reading ten getters.
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

        uint256 held = ss4.balanceOf(address(this));
        if (held < saleAllocation) revert InventoryNotFunded(saleAllocation, held);

        configFrozen = true;
        configHash = _computeConfigHash();
        emit ConfigurationFrozen(configHash);
    }

    // =====================================================================
    // Purchasing (§7.4, §7.7)
    // =====================================================================

    /**
     * @notice Buy `$SS4` with an allowlisted stablecoin at the frozen fixed price.
     *
     * @dev    Pricing, for a payment token with `d` decimals (§7.4):
     *
     *             paymentUsdE6 = paymentAmount * 1e6 / 10^d
     *             ss4Out       = paymentUsdE6 * 1e18 / priceUsdE6
     *
     *         Both steps use `Math.mulDiv`, so the intermediate product is computed at
     *         512-bit width and cannot overflow, and both round DOWN — the sale never
     *         hands out a token it was not paid for. A purchase that rounds to zero
     *         `$SS4` is rejected rather than silently taking the money.
     *
     *         Rounding note, documented per §25.1: for an 18-decimal stablecoin the
     *         first step floors to whole micro-dollars, so up to 1e12 wei (under
     *         $0.000001) of a payment can be credited as USD 0. The buyer still
     *         transfers the full `paymentAmount`. This is sub-dust and deliberate —
     *         the alternative, crediting fractional micro-dollars, would make the
     *         per-wallet and hard-cap accounting disagree with the emitted USD totals.
     *
     *         The contract asserts it actually received `paymentAmount` by measuring its
     *         own balance delta, which rejects fee-on-transfer or rebasing tokens (the
     *         same guard as StablecoinGamePassCheckout) and works with return-less
     *         tokens like USDT through SafeERC20.
     *
     * @param paymentToken  Allowlisted USDC/USDT address for this chain.
     * @param paymentAmount Amount in the payment token's own base units.
     * @param minSs4Out     User-side protection (§7.6). Even at a fixed price this makes
     *                      a decimals or configuration error fail safely instead of
     *                      filling at a wrong rate.
     */
    function buy(address paymentToken, uint256 paymentAmount, uint256 minSs4Out)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ss4Out)
    {
        return _buy(paymentToken, paymentAmount, minSs4Out);
    }

    /**
     * @notice `buy` preceded by an ERC-2612 permit, for stablecoins that support it.
     * @dev    The permit is attempted in `try/catch` and a failure is ignored: if the
     *         same permit was already front-run onto the token, the allowance it grants
     *         exists anyway and the purchase should still succeed. If no allowance
     *         results, `safeTransferFrom` reverts a moment later regardless — so
     *         swallowing the error here can never let an unfunded purchase through.
     *         Real USDT on most chains has no ERC-2612 permit; use `buy` there.
     */
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
        return _buy(paymentToken, paymentAmount, minSs4Out);
    }

    function _buy(address paymentToken, uint256 paymentAmount, uint256 minSs4Out) private returns (uint256 ss4Out) {
        SaleState currentState = state();
        if (currentState != SaleState.Active) revert SaleNotActive(currentState);

        PaymentToken memory config = paymentTokens[paymentToken];
        if (!config.accepted) revert PaymentTokenNotAccepted(paymentToken);
        if (paymentAmount == 0) revert ZeroAmount();

        uint256 usdE6;
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

        // Effects before the interaction (§25.1).
        tokensSold += ss4Out;
        raisedUsdE6 += usdE6;
        raisedByToken[paymentToken] += paymentAmount;
        purchasedSs4[msg.sender] += ss4Out;
        purchasedUsdE6[msg.sender] = walletTotalUsdE6;
        contributedByToken[msg.sender][paymentToken] += paymentAmount;

        uint256 balanceBefore = IERC20(paymentToken).balanceOf(address(this));
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);
        uint256 received = IERC20(paymentToken).balanceOf(address(this)) - balanceBefore;
        if (received != paymentAmount) revert UnexpectedAmountReceived(paymentAmount, received);

        emit Purchase(msg.sender, paymentToken, paymentAmount, ss4Out);
    }

    // =====================================================================
    // Settlement (§7.1)
    // =====================================================================

    /**
     * @notice Close the sale successfully and open claims at `claimStart`.
     * @dev    Only from `Ended` — after `saleEnd`, an exact sellout, or the hard cap being
     *         reached, so a sale that fills early can be settled without waiting — and only if
     *         the soft cap was reached. Finalization is what makes buyer money
     *         non-refundable and treasury-withdrawable, so it is deliberately one-way
     *         and mutually exclusive with cancellation.
     */
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

    /**
     * @notice Cancel the sale and open refunds for every buyer.
     * @dev    Available at any point before finalization. Cancelling never touches a
     *         buyer's recorded contribution — it only unlocks the refund path (§22.3:
     *         a pause must not stop refunds, and a cancel must not erase purchases).
     */
    function cancelSale(bytes32 reasonHash) external onlyRole(SALE_FINALIZER_ROLE) {
        if (finalized || cancelled) revert SaleAlreadySettled();
        cancelled = true;
        emit SaleCancelled(reasonHash);
    }

    /**
     * @notice Permissionless cancellation once the sale has ended below its soft cap.
     * @dev    Without this, a soft-capped sale that missed its target could be left
     *         un-cancelled forever with buyer funds stuck in an un-refundable limbo,
     *         because `finalize()` would revert and only an admin could call
     *         `cancelSale`. Anyone may trigger the outcome the published rules already
     *         require. Requires a nonzero soft cap and a sale that is genuinely over.
     */
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

    /**
     * @notice Claim the vested portion of purchased `$SS4`.
     * @dev    Pull payment, `nonReentrant`, checks-effects-interactions. Claims are
     *         unaffected by `pause()`, which only stops new purchases (§22.3).
     */
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
     * @dev    The loop is over the payment-token allowlist, which is hard-bounded at
     *         `MAX_PAYMENT_TOKENS` — never over buyers (§7.7 "never loop through
     *         buyers"). The wallet's `$SS4` entitlement is zeroed in the same
     *         transaction; claims are unreachable in a cancelled sale anyway, and this
     *         keeps `tokensSold` reconcilable against outstanding entitlements.
     */
    function refund() external nonReentrant returns (uint256 refundedTokenCount) {
        if (!cancelled) revert SaleNotCancelled();

        purchasedSs4[msg.sender] = 0;
        purchasedUsdE6[msg.sender] = 0;

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

    /// @notice Move settled proceeds to a labeled treasury. Impossible before finalization.
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
     * @notice Return `$SS4` that was never sold to its originating pool (§7.5, §7.7).
     * @dev    Only the genuinely unsold remainder: the balance minus every token still
     *         owed to a buyer. Recovery can never reach inventory owed on an
     *         outstanding claim (§25.3).
     *
     *         Available after either terminal state. After a cancellation the whole
     *         balance is recoverable, because `claim()` requires finalization and so no
     *         buyer can ever have a `$SS4` entitlement against a cancelled sale — their
     *         money comes back through `refund()` in stablecoins instead. Without this,
     *         a cancelled sale would leave the entire presale allocation permanently
     *         stranded in the contract.
     */
    function recoverUnsoldTokens(address to) external onlyRole(TREASURY_ROLE) nonReentrant returns (uint256 amount) {
        if (!finalized && !cancelled) revert SaleNotSettled();
        if (to == address(0)) revert ZeroAddress();

        amount = _recoverableSs4();
        if (amount == 0) revert ZeroAmount();

        ss4.safeTransfer(to, amount);
        emit UnsoldTokensRecovered(amount, to);
    }

    /**
     * @notice Sweep `$SS4` left unclaimed after the published claim deadline.
     * @dev    Disabled unless a nonzero `claimDeadline` was configured before the freeze,
     *         so this can never become a surprise for buyers who were told there was no
     *         deadline. Buyers' entitlements are not individually zeroed; after this
     *         point the contract simply no longer holds their tokens, which is what the
     *         published deadline rule means. Because of that, the deadline value is a
     *         disclosure item, not a routine operational lever.
     */
    function sweepUnclaimedTokens(address to) external onlyRole(TREASURY_ROLE) nonReentrant returns (uint256 amount) {
        if (!finalized) revert SaleNotFinalized();
        if (to == address(0)) revert ZeroAddress();
        if (claimDeadline == 0 || block.timestamp < claimDeadline) revert ClaimDeadlineNotPassed(claimDeadline);

        amount = ss4.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        ss4.safeTransfer(to, amount);
        emit UnclaimedTokensSwept(amount, to);
    }

    /**
     * @notice Recover a token sent here by mistake (§25.3).
     * @dev    Hard-refuses `$SS4` and every configured payment token — including one that
     *         is no longer accepted, because refunds may still be owed in it. Those have
     *         their own settlement-gated paths. This function exists only for a token
     *         this sale was never meant to touch.
     */
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

    /// @notice Current lifecycle state (§7.1). `Active` additionally requires the freeze.
    function state() public view returns (SaleState) {
        if (cancelled) return SaleState.Cancelled;
        if (finalized) return SaleState.Finalized;
        if (!configFrozen || block.timestamp < saleStart) return SaleState.Configured;
        if (block.timestamp >= saleEnd || tokensSold >= saleAllocation || raisedUsdE6 >= hardCapUsdE6) {
            return SaleState.Ended;
        }
        return SaleState.Active;
    }

    /// @notice Quote a purchase without executing it (§7.6). Reverts for an unknown token.
    function previewPurchase(address paymentToken, uint256 paymentAmount)
        external
        view
        returns (uint256 usdE6, uint256 ss4Out)
    {
        PaymentToken memory config = paymentTokens[paymentToken];
        if (!config.known) revert PaymentTokenNotAccepted(paymentToken);
        return _quote(paymentAmount, config.decimals);
    }

    /// @notice `$SS4` this account can withdraw right now.
    function claimable(address account) public view returns (uint256) {
        if (!finalized) return 0;
        return vestedAmount(account, uint64(block.timestamp)) - claimedSs4[account];
    }

    /**
     * @notice `$SS4` released to this account by `timestamp`, ignoring what it already took.
     * @dev    tgeUnlockBps at claimStart, then the remainder linearly from
     *         `claimStart + vestCliffSeconds` over `vestDurationSeconds`. Rounds down;
     *         the final instant pays the exact remainder so rounding never strands dust.
     */
    function vestedAmount(address account, uint64 timestamp) public view returns (uint256) {
        uint256 total = purchasedSs4[account];
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

    /// @notice Stablecoin amount this account can reclaim in `paymentToken` after a cancellation.
    function refundable(address account, address paymentToken) external view returns (uint256) {
        if (!cancelled) return 0;
        return contributedByToken[account][paymentToken];
    }

    /// @notice `$SS4` still owed to buyers who have not claimed yet.
    function outstandingEntitlement() public view returns (uint256) {
        return tokensSold - tokensClaimed;
    }

    /// @notice Unsold `$SS4` a treasury withdrawal may take, after honoring every claim.
    function recoverableSs4() external view returns (uint256) {
        return _recoverableSs4();
    }

    /// @notice The configured payment-token allowlist, including entries no longer accepted.
    function paymentTokenList() external view returns (address[] memory) {
        return _paymentTokenList;
    }

    function paymentTokenCount() external view returns (uint256) {
        return _paymentTokenList.length;
    }

    // =====================================================================
    // Internals
    // =====================================================================

    /**
     * @dev Hashes the frozen terms in three groups — wiring, economics, schedule — rather
     *      than one flat `abi.encode`. The flat form needs every field live on the stack
     *      at once and does not compile without via-IR; the grouped form is equivalent for
     *      verification purposes and keeps this contract buildable under the repository's
     *      existing compiler settings. The chain ID and this contract's own address are
     *      included so a hash from one deployment can never be presented as another's.
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
        return keccak256(abi.encode(wiring, economics, schedule));
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
