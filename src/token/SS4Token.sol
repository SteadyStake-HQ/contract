// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "openzeppelin-contracts/contracts/utils/Nonces.sol";

/**
 * @title SS4Token
 * @notice The permanent `$SS4` ecosystem token. Fixed supply, minted once in the
 *         constructor to six allocation recipients. Implements the SS4 Smart-Contract
 *         Implementation Outline §5.
 *
 * @dev    What this contract deliberately does NOT have (§5.2): no mint function, no
 *         privileged burn, no transfer tax, no reflections or rebase, no blacklist, no
 *         max wallet or max transaction, no trading switch, no transfer pause, no proxy,
 *         and no owner. There is no admin surface at all — nothing to renounce, because
 *         nothing was ever granted.
 *
 *         Hard boundary (§4): this token knows nothing about seasons, DCA plans, the
 *         presale, membership, the game, or AI services. A bug or an upgrade anywhere in
 *         those systems must never be able to change token supply or ordinary transfers.
 *         That is why launch timing is controlled by distribution (§5.3) — vesting
 *         contracts, presale claim gating, and when liquidity is added — and never by a
 *         switch inside this contract.
 *
 *         `ERC20Votes` is included only to preserve the option of bounded on-chain
 *         governance later (§5.1). No Governor is part of this launch, and voting power
 *         requires explicit delegation, so balances carry no voting weight by default.
 *         If the team decides direct token voting is definitely unwanted, remove it
 *         BEFORE the audit — it cannot be added later without an upgradeable token,
 *         which §5.2 forbids.
 */
contract SS4Token is ERC20, ERC20Permit, ERC20Votes {
    /// @notice Fixed allocation split in basis points (§3.1). These are confirmed, not TBD.
    uint16 public constant COMMUNITY_BPS = 3_500; // 35% Community Rewards
    uint16 public constant TEAM_BPS = 1_500; // 15% Team
    uint16 public constant INVESTORS_BPS = 1_500; // 15% Investors (presale carves out of this)
    uint16 public constant TREASURY_BPS = 1_500; // 15% Treasury
    uint16 public constant LIQUIDITY_BPS = 1_000; // 10% Liquidity
    uint16 public constant ECOSYSTEM_BPS = 1_000; // 10% Ecosystem / Partnerships

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice The six allocation recipients (§3.3). Every one of these must be a
     *         predeployed, controlled destination — a vesting contract, a labeled
     *         multisig, or a vault — never an unlocked omnibus EOA, and never the
     *         deployer left holding the supply.
     */
    struct Allocations {
        address community;
        address team;
        address investors;
        address treasury;
        address liquidity;
        address ecosystem;
    }

    /// @notice Where each allocation was minted, kept on-chain for public verification.
    Allocations public allocationRecipients;

    /**
     * @notice Emitted once per pool at construction, alongside the ordinary ERC-20
     *         `Transfer` events from the zero address (§5.4), so an indexer can label
     *         each initial mint without decoding constructor calldata.
     */
    event AllocationMinted(string indexed pool, address indexed recipient, uint256 amount, uint16 bps);

    error ZeroAddress(string pool);
    error ZeroSupply();
    error AllocationBpsMismatch(uint256 sum);
    error AllocationSumMismatch(uint256 minted, uint256 totalSupply);
    error SupplyExceedsVotesLimit(uint256 requested, uint256 maximum);

    /**
     * @param name_        Token name. §5.2 recommends "SteadyStake"; final confirmation required.
     * @param symbol_      On-chain symbol. MUST be "SS4" — no `$` in the ERC-20 symbol (§2).
     * @param totalSupply_ The approved fixed total supply in base units (18 decimals).
     *                     A §29 deployment blocker: there is no default and no way to
     *                     change it after construction.
     * @param recipients   The six allocation destinations (§3.3).
     *
     * @dev Rounding: each pool gets `totalSupply * bps / 10000`, rounded down. Any
     *      remainder from integer division is assigned to the Treasury pool, which is the
     *      documented rounding destination in §3.1. The constructor then asserts the six
     *      minted amounts sum to exactly `totalSupply_`, so the §5.6 invariant holds for
     *      any supply — including one that does not divide cleanly.
     */
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, Allocations memory recipients)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (totalSupply_ == 0) revert ZeroSupply();

        // §5.5: ERC20Votes packs supply into uint208 checkpoints. Prove the approved
        // supply fits before minting, rather than discovering it at the first transfer.
        uint256 votesMax = _maxSupply();
        if (totalSupply_ > votesMax) revert SupplyExceedsVotesLimit(totalSupply_, votesMax);

        if (recipients.community == address(0)) revert ZeroAddress("community");
        if (recipients.team == address(0)) revert ZeroAddress("team");
        if (recipients.investors == address(0)) revert ZeroAddress("investors");
        if (recipients.treasury == address(0)) revert ZeroAddress("treasury");
        if (recipients.liquidity == address(0)) revert ZeroAddress("liquidity");
        if (recipients.ecosystem == address(0)) revert ZeroAddress("ecosystem");

        uint256 bpsSum =
            uint256(COMMUNITY_BPS) + TEAM_BPS + INVESTORS_BPS + TREASURY_BPS + LIQUIDITY_BPS + ECOSYSTEM_BPS;
        if (bpsSum != BPS_DENOMINATOR) revert AllocationBpsMismatch(bpsSum);

        allocationRecipients = recipients;

        uint256 community = (totalSupply_ * COMMUNITY_BPS) / BPS_DENOMINATOR;
        uint256 team = (totalSupply_ * TEAM_BPS) / BPS_DENOMINATOR;
        uint256 investors = (totalSupply_ * INVESTORS_BPS) / BPS_DENOMINATOR;
        uint256 liquidity = (totalSupply_ * LIQUIDITY_BPS) / BPS_DENOMINATOR;
        uint256 ecosystem = (totalSupply_ * ECOSYSTEM_BPS) / BPS_DENOMINATOR;
        // Treasury absorbs the rounding remainder (§3.1).
        uint256 treasury = totalSupply_ - community - team - investors - liquidity - ecosystem;

        _mint(recipients.community, community);
        _mint(recipients.team, team);
        _mint(recipients.investors, investors);
        _mint(recipients.treasury, treasury);
        _mint(recipients.liquidity, liquidity);
        _mint(recipients.ecosystem, ecosystem);

        // §5.4 step 4 and the §26.1 test: the six allocations must equal the supply exactly.
        if (totalSupply() != totalSupply_) revert AllocationSumMismatch(totalSupply(), totalSupply_);

        emit AllocationMinted("Community", recipients.community, community, COMMUNITY_BPS);
        emit AllocationMinted("Team", recipients.team, team, TEAM_BPS);
        emit AllocationMinted("Investors", recipients.investors, investors, INVESTORS_BPS);
        emit AllocationMinted("Treasury", recipients.treasury, treasury, TREASURY_BPS);
        emit AllocationMinted("Liquidity", recipients.liquidity, liquidity, LIQUIDITY_BPS);
        emit AllocationMinted("Ecosystem", recipients.ecosystem, ecosystem, ECOSYSTEM_BPS);

        // No mint authority, no owner, and no role survives this constructor (§5.4 step 6).
    }

    // ---------------------------------------------------------------------
    // Required overrides for the pinned OpenZeppelin version (§5.5)
    // ---------------------------------------------------------------------

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
