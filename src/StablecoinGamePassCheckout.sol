// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StablecoinGamePassCheckout
 * @notice One-per-network on-chain register for Echo Arena Game Pass payments.
 *         Blueprint §18.1. Accepts exactly one allowlisted stablecoin, moves the
 *         configured price straight to the treasury, and emits an auditable event
 *         the backend indexer turns into pass time.
 *
 * @dev    The backend — not this contract — is the canonical source of cross-network
 *         pass expiry (§18.1 note). This contract's only jobs are: take the right
 *         amount of the right token, refuse a purchase id twice, and leave a receipt.
 *
 *         The token is chosen by exact address at deploy and is immutable. A token
 *         with the correct symbol but the wrong address is simply a different contract
 *         this one was never pointed at (§6: "select it by exact chain ID and exact
 *         contract address").
 */
contract StablecoinGamePassCheckout is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice May enable/price/disable pass plans.
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    /// @notice May repoint the treasury.
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    /// @notice May pause and unpause new purchases.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @param durationSeconds Pass length this plan grants (backend adds it to expiry).
     * @param price           Exact amount pulled, in the stablecoin's own base units.
     * @param enabled         Only enabled plans can be bought.
     */
    struct PassPlan {
        uint32 durationSeconds;
        uint256 price;
        bool enabled;
    }

    /// @notice The single stablecoin this checkout accepts. Never trusted by symbol.
    IERC20 public immutable stablecoin;

    /// @notice Where payments land. Kept separate from DCA vault / gas tank capital (§24).
    address public treasury;

    /// @notice planId => plan config.
    mapping(uint8 => PassPlan) public plans;

    /// @notice Backend-issued purchase id => spent. Prevents a replayed checkout.
    mapping(bytes32 => bool) public usedPurchaseIds;

    /**
     * @notice The receipt the indexer reads (§18.1). `paymentToken` is indexed even
     *         though it is fixed per contract, so a multi-network indexer can filter
     *         one stream by token without an ABI branch per chain.
     */
    event PassPaid(
        bytes32 indexed purchaseId,
        address indexed buyer,
        address indexed paymentToken,
        uint256 amount,
        uint8 planId,
        uint32 durationSeconds
    );

    event PlanConfigured(uint8 indexed planId, uint32 durationSeconds, uint256 price, bool enabled);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    error ZeroAddress();
    error PurchaseIdUsed(bytes32 purchaseId);
    error PlanDisabled(uint8 planId);
    error UnexpectedAmountReceived(uint256 expected, uint256 received);

    /**
     * @param stablecoin_ Exact allowlisted stablecoin address for this network.
     * @param treasury_    Payment destination.
     * @param admin        Holds DEFAULT_ADMIN_ROLE — must be the project multisig (§24).
     */
    constructor(address stablecoin_, address treasury_, address admin) {
        if (stablecoin_ == address(0) || treasury_ == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        stablecoin = IERC20(stablecoin_);
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(TREASURER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /**
     * @notice Buy a pass. The amount is read from trusted on-chain config, never from
     *         the caller (§7.1: "client must not be allowed to provide its own price").
     *
     * @dev    Payment goes straight to the treasury and the treasury balance delta is
     *         asserted to equal the configured price. That rejects a fee-on-transfer or
     *         rebasing token whose real receipt is less than `price`, and — because it
     *         reads balances rather than a return value — it tolerates the non-standard
     *         return behaviour of tokens like USDT (§18.4).
     *
     *         One consequence worth stating: the treasury can never buy a pass from itself.
     *         A transfer from the treasury to the treasury moves no balance, so the delta is
     *         zero and this reverts with UnexpectedAmountReceived(price, 0). That is correct
     *         — the payment genuinely did not happen — but it means the treasury must be an
     *         address that never plays, which §24 wants anyway for keeping payment capital
     *         apart from the DCA vault and gas tank.
     *
     * @param planId     Which pass plan.
     * @param purchaseId Backend-issued id binding this payment to one intent. Single-use.
     */
    function buyPass(uint8 planId, bytes32 purchaseId) external nonReentrant whenNotPaused {
        if (usedPurchaseIds[purchaseId]) revert PurchaseIdUsed(purchaseId);

        PassPlan memory plan = plans[planId];
        if (!plan.enabled) revert PlanDisabled(planId);

        // Effects before interaction: the id is burned up-front so a reentrant or
        // repeated call in the same block cannot double-spend it.
        usedPurchaseIds[purchaseId] = true;

        uint256 before = stablecoin.balanceOf(treasury);
        stablecoin.safeTransferFrom(msg.sender, treasury, plan.price);
        uint256 received = stablecoin.balanceOf(treasury) - before;
        if (received != plan.price) revert UnexpectedAmountReceived(plan.price, received);

        emit PassPaid(purchaseId, msg.sender, address(stablecoin), plan.price, planId, plan.durationSeconds);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Set or update a pass plan. Disabling a plan blocks new buys of it only.
    function setPlan(uint8 planId, uint32 durationSeconds, uint256 price, bool enabled)
        external
        onlyRole(CONFIG_ROLE)
    {
        plans[planId] = PassPlan({durationSeconds: durationSeconds, price: price, enabled: enabled});
        emit PlanConfigured(planId, durationSeconds, price, enabled);
    }

    /// @notice Repoint payments. Does not affect any pass already sold.
    function setTreasury(address newTreasury) external onlyRole(TREASURER_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Stop new purchases. Never touches passes already sold (they live off-chain).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
