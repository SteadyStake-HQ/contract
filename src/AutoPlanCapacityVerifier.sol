// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IAutoPlanCapacityVerifier} from "./interfaces/IAutoPlanCapacityVerifier.sol";

/**
 * @title AutoPlanCapacityVerifier
 * @notice Per-DCA-network gate for NFT-bonus Auto Execution Plans (blueprint §16 / §18.3).
 *
 *         The reward NFT is canonical on Base, but plans are created on Base, BOT, Polygon,
 *         BNB, Kava and later chains. A contract on one chain cannot read another chain's
 *         state, so instead the backend capacity service — after locking the account row and
 *         confirming a bonus slot is free (§16.3) — signs a short-lived EIP-712 permit. This
 *         contract verifies that signature on the target chain and burns the nonce, letting the
 *         vault enroll exactly one bonus plan.
 *
 * @dev    Fails closed: anything unexpected reverts, so a bad or missing entitlement can never
 *         produce extra capacity. Existing plans are unaffected — this only gates new enrollments.
 */
contract AutoPlanCapacityVerifier is IAutoPlanCapacityVerifier, EIP712, AccessControl {
    using ECDSA for bytes32;

    /// @notice The dedicated capacity-authorizer key(s). Not the treasury key (§16.2). Rotated by admin/multisig.
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    /// @notice Approved vault contracts — the only callers allowed to consume a permit (§18.3).
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice Max lifetime of a permit: no more than five minutes after issue (§16.2).
    uint64 public constant MAX_PERMIT_TTL = 5 minutes;

    bytes32 private constant _PERMIT_TYPEHASH = keccak256(
        "AutoPlanCapacityPermit(address wallet,uint256 targetChainId,bytes32 planIntentId,uint8 nftBonus,uint8 reservedSlotNumber,uint256 nonce,uint64 issuedAt,uint64 deadline)"
    );

    /// @notice nonce => consumed. Single-use on this chain (§16.2).
    mapping(uint256 => bool) public nonceUsed;

    event PermitConsumed(
        address indexed wallet,
        bytes32 indexed planIntentId,
        uint256 nonce,
        uint8 reservedSlotNumber,
        uint8 nftBonus,
        address signer
    );

    error ZeroAddress();
    error WrongChain(uint256 permitChainId, uint256 blockChainId);
    error PermitExpired(uint64 deadline);
    error TtlTooLong(uint64 issuedAt, uint64 deadline);
    error NonceAlreadyUsed(uint256 nonce);
    error InvalidSigner(address recovered);

    /**
     * @param name    EIP-712 domain app name (must match the backend signer's domain).
     * @param version EIP-712 domain version.
     * @param admin   Holds DEFAULT_ADMIN_ROLE — must be the project multisig; controls signer rotation (§16.2).
     */
    constructor(string memory name, string memory version, address admin) EIP712(name, version) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IAutoPlanCapacityVerifier
    function consumePermit(AutoPlanCapacityPermit calldata permit, bytes calldata signature)
        external
        onlyRole(VAULT_ROLE)
        returns (bool)
    {
        // Chain binding: the permit's EIP-712 domain also carries block.chainid, but check the
        // explicit field too so a mis-signed permit can never be replayed onto the wrong network.
        if (permit.targetChainId != block.chainid) revert WrongChain(permit.targetChainId, block.chainid);

        // Freshness. deadline must be in the future and within MAX_PERMIT_TTL of issue.
        if (permit.deadline < block.timestamp) revert PermitExpired(permit.deadline);
        if (permit.deadline > permit.issuedAt + MAX_PERMIT_TTL || permit.deadline < permit.issuedAt) {
            revert TtlTooLong(permit.issuedAt, permit.deadline);
        }

        // Single-use nonce, burned before any external effect the caller might have.
        if (nonceUsed[permit.nonce]) revert NonceAlreadyUsed(permit.nonce);
        nonceUsed[permit.nonce] = true;

        address signer = _hashPermit(permit).recover(signature);
        if (!hasRole(SIGNER_ROLE, signer)) revert InvalidSigner(signer);

        emit PermitConsumed(
            permit.wallet, permit.planIntentId, permit.nonce, permit.reservedSlotNumber, permit.nftBonus, signer
        );
        return true;
    }

    /// @notice The EIP-712 digest a backend signer must sign for `permit`.
    function hashPermit(AutoPlanCapacityPermit calldata permit) external view returns (bytes32) {
        return _hashPermit(permit);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _hashPermit(AutoPlanCapacityPermit calldata permit) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _PERMIT_TYPEHASH,
                    permit.wallet,
                    permit.targetChainId,
                    permit.planIntentId,
                    permit.nftBonus,
                    permit.reservedSlotNumber,
                    permit.nonce,
                    permit.issuedAt,
                    permit.deadline
                )
            )
        );
    }
}
