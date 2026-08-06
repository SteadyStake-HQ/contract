// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ERC721URIStorage} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title SeasonRewardNFT
 * @notice Echo Arena season reward cards (blueprint §18.2). One collection on Base.
 *         Rank 1/2/3 finishers receive a soulbound card worth +3/+2/+1 Auto Execution
 *         Plan slots. The card's slot value is fixed by the contract, never by metadata
 *         (§13.2: "the smart contract is the authority").
 *
 * @dev    Soulbound via ERC-5192: every token is permanently locked. Transfers and
 *         approvals revert; only mint (and burn, for a future migration) move a token.
 *
 *         Two-step award, matching §14: a FINALIZER commits the frozen season result
 *         once, then a MINTER mints each rank's deterministic token to the registered
 *         winner. A recipient can only ever be one of the three registered addresses —
 *         the dashboard cannot inject an arbitrary wallet (§14.3 / §22).
 */
contract SeasonRewardNFT is ERC721URIStorage, AccessControl, Pausable {
    /// @notice May register a season's frozen result.
    bytes32 public constant FINALIZER_ROLE = keccak256("FINALIZER_ROLE");
    /// @notice May mint the registered winners' cards.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice May pause new registrations and mints.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice ERC-5192 interface id (`locked(uint256)`).
    bytes4 private constant _ERC5192_ID = 0xb45a3c0e;

    /// @notice ERC-5192: emitted once at mint since every token is permanently locked.
    event Locked(uint256 tokenId);

    struct SeasonResult {
        bytes32 rulesHash;
        bytes32 snapshotHash;
        address[3] winners; // index 0..2 => rank 1..3
        bool registered;
    }

    /// @notice seasonId => committed result.
    mapping(uint64 => SeasonResult) private _seasons;
    /// @notice tokenId => pinned metadata URI, set at registration.
    mapping(uint64 => mapping(uint8 => string)) private _rankURI;
    /// @notice tokenId => Auto Execution Plan slot bonus (4 - rank).
    mapping(uint256 => uint8) public bonusSlots;

    event SeasonResultRegistered(
        uint64 indexed seasonId, bytes32 rulesHash, bytes32 snapshotHash, address[3] winners
    );
    event SeasonAwardMinted(
        uint64 indexed seasonId, uint8 indexed rank, address indexed winner, uint256 tokenId, uint8 bonusSlots
    );

    error ZeroAddress();
    error SeasonAlreadyRegistered(uint64 seasonId);
    error SeasonNotRegistered(uint64 seasonId);
    error InvalidRank(uint8 rank);
    error NoWinnerForRank(uint64 seasonId, uint8 rank);
    error AlreadyMinted(uint256 tokenId);
    error MissingMetadata(uint64 seasonId, uint8 rank);
    error Soulbound();

    /**
     * @param admin Holds DEFAULT_ADMIN_ROLE — must be the project multisig (§18.2/§24).
     */
    constructor(address admin) ERC721("Echo Arena Season Reward", "ECHOWIN") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FINALIZER_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /**
     * @notice Deterministic token id for a season/rank. Unique across all seasons,
     *         so a season/rank can be minted exactly once.
     */
    function tokenIdFor(uint64 seasonId, uint8 rank) public pure returns (uint256) {
        return (uint256(seasonId) << 8) | uint256(rank);
    }

    /**
     * @notice Commit a season's frozen top-three result, once (§14.2). Also pins the
     *         three cards' metadata URIs so mint is a pure lookup afterwards.
     *
     * @dev    A winner address may be zero when fewer than three players were eligible
     *         (§14.3); that rank simply cannot be minted.
     *
     * @param winners   [rank1, rank2, rank3] wallet addresses from the frozen snapshot.
     * @param tokenURIs Pinned metadata URI per rank, same order.
     */
    function registerSeasonResult(
        uint64 seasonId,
        bytes32 rulesHash,
        bytes32 snapshotHash,
        address[3] calldata winners,
        string[3] calldata tokenURIs
    ) external onlyRole(FINALIZER_ROLE) whenNotPaused {
        if (_seasons[seasonId].registered) revert SeasonAlreadyRegistered(seasonId);

        _seasons[seasonId] =
            SeasonResult({rulesHash: rulesHash, snapshotHash: snapshotHash, winners: winners, registered: true});
        for (uint8 i = 0; i < 3; i++) {
            _rankURI[seasonId][i + 1] = tokenURIs[i];
        }

        emit SeasonResultRegistered(seasonId, rulesHash, snapshotHash, winners);
    }

    /**
     * @notice Mint one rank's card to its registered winner (§14.3). Idempotent by the
     *         deterministic token id: a second attempt reverts.
     */
    function mintSeasonAward(uint64 seasonId, uint8 rank) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (rank < 1 || rank > 3) revert InvalidRank(rank);

        SeasonResult storage season = _seasons[seasonId];
        if (!season.registered) revert SeasonNotRegistered(seasonId);

        address winner = season.winners[rank - 1];
        if (winner == address(0)) revert NoWinnerForRank(seasonId, rank);

        uint256 tokenId = tokenIdFor(seasonId, rank);
        if (_ownerOf(tokenId) != address(0)) revert AlreadyMinted(tokenId);

        string memory uri = _rankURI[seasonId][rank];
        if (bytes(uri).length == 0) revert MissingMetadata(seasonId, rank);

        uint8 slots = 4 - rank; // rank 1 => 3, rank 2 => 2, rank 3 => 1
        bonusSlots[tokenId] = slots;

        _mint(winner, tokenId);
        _setTokenURI(tokenId, uri);

        emit Locked(tokenId); // ERC-5192
        emit SeasonAwardMinted(seasonId, rank, winner, tokenId, slots);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice ERC-5192: every minted token is permanently locked.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function seasonWinners(uint64 seasonId) external view returns (address[3] memory) {
        return _seasons[seasonId].winners;
    }

    function seasonRegistered(uint64 seasonId) external view returns (bool) {
        return _seasons[seasonId].registered;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Pause new registrations/mints. Ownership already granted is untouched (§18.2).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Soulbound enforcement (ERC-5192)
    // ---------------------------------------------------------------------

    /// @dev Blocks owner-to-owner transfers; permits mint (from == 0) and burn (to == 0).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return interfaceId == _ERC5192_ID || super.supportsInterface(interfaceId);
    }
}
