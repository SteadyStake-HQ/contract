// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {AutoPlanCapacityVerifier} from "../src/AutoPlanCapacityVerifier.sol";
import {IAutoPlanCapacityVerifier} from "../src/interfaces/IAutoPlanCapacityVerifier.sol";

contract AutoPlanCapacityVerifierTest is Test {
    AutoPlanCapacityVerifier internal verifier;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("vault");
    address internal wallet = makeAddr("wallet");
    address internal outsider = makeAddr("outsider");

    uint256 internal signerPk = 0xA11CE;
    address internal signer;
    uint256 internal roguePk = 0xB0B;

    event PermitConsumed(
        address indexed wallet,
        bytes32 indexed planIntentId,
        uint256 nonce,
        uint8 reservedSlotNumber,
        uint8 nftBonus,
        address signer
    );

    function setUp() public {
        signer = vm.addr(signerPk);
        verifier = new AutoPlanCapacityVerifier("Echo Arena Capacity", "1", admin);

        vm.startPrank(admin);
        verifier.grantRole(verifier.SIGNER_ROLE(), signer);
        verifier.grantRole(verifier.VAULT_ROLE(), vault);
        vm.stopPrank();
    }

    function _basePermit() internal view returns (IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory) {
        return IAutoPlanCapacityVerifier.AutoPlanCapacityPermit({
            wallet: wallet,
            targetChainId: block.chainid,
            planIntentId: keccak256("plan-1"),
            nftBonus: 3,
            reservedSlotNumber: 1,
            nonce: 42,
            issuedAt: uint64(block.timestamp),
            deadline: uint64(block.timestamp) + 5 minutes
        });
    }

    function _sign(uint256 pk, IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = verifier.hashPermit(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_ConsumePermit_Valid_Succeeds_And_BurnsNonce() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        bytes memory sig = _sign(signerPk, permit);

        vm.expectEmit(true, true, false, true);
        emit PermitConsumed(wallet, permit.planIntentId, permit.nonce, 1, 3, signer);

        vm.prank(vault);
        bool ok = verifier.consumePermit(permit, sig);

        assertTrue(ok);
        assertTrue(verifier.nonceUsed(permit.nonce));
    }

    function test_ConsumePermit_Replay_Reverts() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        bytes memory sig = _sign(signerPk, permit);

        vm.prank(vault);
        verifier.consumePermit(permit, sig);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(AutoPlanCapacityVerifier.NonceAlreadyUsed.selector, permit.nonce)
        );
        verifier.consumePermit(permit, sig);
    }

    function test_ConsumePermit_Expired_Reverts() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        bytes memory sig = _sign(signerPk, permit);

        vm.warp(uint256(permit.deadline) + 1);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(AutoPlanCapacityVerifier.PermitExpired.selector, permit.deadline)
        );
        verifier.consumePermit(permit, sig);
    }

    function test_ConsumePermit_TtlTooLong_Reverts() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        permit.deadline = permit.issuedAt + 5 minutes + 1;
        bytes memory sig = _sign(signerPk, permit);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoPlanCapacityVerifier.TtlTooLong.selector, permit.issuedAt, permit.deadline
            )
        );
        verifier.consumePermit(permit, sig);
    }

    function test_ConsumePermit_WrongChain_Reverts() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        permit.targetChainId = block.chainid + 1;
        bytes memory sig = _sign(signerPk, permit);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoPlanCapacityVerifier.WrongChain.selector, permit.targetChainId, block.chainid
            )
        );
        verifier.consumePermit(permit, sig);
    }

    function test_ConsumePermit_BadSigner_Reverts() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        bytes memory sig = _sign(roguePk, permit); // not granted SIGNER_ROLE

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(AutoPlanCapacityVerifier.InvalidSigner.selector, vm.addr(roguePk))
        );
        verifier.consumePermit(permit, sig);
    }

    function test_ConsumePermit_NonVaultCaller_Reverts() public {
        IAutoPlanCapacityVerifier.AutoPlanCapacityPermit memory permit = _basePermit();
        bytes memory sig = _sign(signerPk, permit);

        vm.prank(outsider);
        vm.expectRevert();
        verifier.consumePermit(permit, sig);
    }
}
