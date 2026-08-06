// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IAutoPlanCapacityVerifier
 * @notice The surface a DCA vault needs to consume an NFT Auto Execution capacity
 *         permit during plan enrollment (blueprint §16 / §18.3). Kept as a thin
 *         interface so the vault imports only this, not the full verifier.
 */
interface IAutoPlanCapacityVerifier {
    /**
     * @notice A signed authorization to enroll one Auto Execution Plan above the
     *         wallet's base per-network limit, drawing on its NFT bonus pool (§16.1).
     */
    struct AutoPlanCapacityPermit {
        address wallet;
        uint256 targetChainId;
        bytes32 planIntentId;
        uint8 nftBonus;
        uint8 reservedSlotNumber;
        uint256 nonce;
        uint64 issuedAt;
        uint64 deadline;
    }

    /**
     * @notice Verify and consume a permit. Reverts on any failure so the calling
     *         vault's enrollment reverts atomically with it. Returns true on success
     *         to keep the call site explicit.
     */
    function consumePermit(AutoPlanCapacityPermit calldata permit, bytes calldata signature)
        external
        returns (bool);

    /// @notice Whether a permit nonce has already been consumed on this chain.
    function nonceUsed(uint256 nonce) external view returns (bool);
}
