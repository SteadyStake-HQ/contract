// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {SS4Token} from "../../src/token/SS4Token.sol";

contract SS4TokenTest is Test {
    SS4Token internal token;

    address internal community = makeAddr("communityVault");
    address internal team = makeAddr("teamVesting");
    address internal investors = makeAddr("investorInventory");
    address internal treasury = makeAddr("treasuryMultisig");
    address internal liquidity = makeAddr("liquidityMultisig");
    address internal ecosystem = makeAddr("ecosystemVault");

    // Illustrative only — the final supply is §29 deployment blocker #2.
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        token = new SS4Token("SteadyStake", "SS4", SUPPLY, _recipients());
    }

    function _recipients() internal view returns (SS4Token.Allocations memory) {
        return SS4Token.Allocations({
            community: community,
            team: team,
            investors: investors,
            treasury: treasury,
            liquidity: liquidity,
            ecosystem: ecosystem
        });
    }

    // ---------------------------------------------------------------------
    // Metadata and supply (§26.1)
    // ---------------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(token.name(), "SteadyStake");
        assertEq(token.symbol(), "SS4", "no $ in the on-chain symbol");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_Allocations_ExactSplitSummingToSupply() public view {
        assertEq(token.balanceOf(community), (SUPPLY * 3500) / 10000, "35% community");
        assertEq(token.balanceOf(team), (SUPPLY * 1500) / 10000, "15% team");
        assertEq(token.balanceOf(investors), (SUPPLY * 1500) / 10000, "15% investors");
        assertEq(token.balanceOf(treasury), (SUPPLY * 1500) / 10000, "15% treasury");
        assertEq(token.balanceOf(liquidity), (SUPPLY * 1000) / 10000, "10% liquidity");
        assertEq(token.balanceOf(ecosystem), (SUPPLY * 1000) / 10000, "10% ecosystem");

        uint256 sum = token.balanceOf(community) + token.balanceOf(team) + token.balanceOf(investors)
            + token.balanceOf(treasury) + token.balanceOf(liquidity) + token.balanceOf(ecosystem);
        assertEq(sum, token.totalSupply(), "six allocations equal total supply exactly");
    }

    /// §5.2: there must be no post-construction mint path at all.
    function test_NoMintFunctionExists() public view {
        // A mint entrypoint would have to be in the ABI; assert the common selectors are absent.
        bytes4[3] memory forbidden = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("owner()"))
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) = address(token).staticcall(abi.encodeWithSelector(forbidden[i], address(this), 1));
            assertFalse(ok, "no mint or owner entrypoint may exist");
        }
    }

    function test_Transfer_MovesExactAmount_NoTax() public {
        vm.prank(treasury);
        token.transfer(address(0xBEEF), 1_000e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1_000e18, "no transfer tax");
        assertEq(token.totalSupply(), SUPPLY, "supply never changes on transfer");
    }

    /// Any supply must split without creating or destroying a single base unit.
    function testFuzz_Allocations_AlwaysSumToSupply(uint256 supply) public {
        supply = bound(supply, 1, type(uint208).max);
        SS4Token t = new SS4Token("SteadyStake", "SS4", supply, _recipients());

        uint256 sum = t.balanceOf(community) + t.balanceOf(team) + t.balanceOf(investors) + t.balanceOf(treasury)
            + t.balanceOf(liquidity) + t.balanceOf(ecosystem);
        assertEq(sum, supply, "no unit created or lost by rounding");
        assertEq(t.totalSupply(), supply);
    }

    // ---------------------------------------------------------------------
    // Constructor validation (§5.4)
    // ---------------------------------------------------------------------

    function test_Constructor_RejectsZeroRecipient() public {
        SS4Token.Allocations memory bad = _recipients();
        bad.treasury = address(0);
        vm.expectRevert(abi.encodeWithSelector(SS4Token.ZeroAddress.selector, "treasury"));
        new SS4Token("SteadyStake", "SS4", SUPPLY, bad);
    }

    function test_Constructor_RejectsZeroSupply() public {
        vm.expectRevert(SS4Token.ZeroSupply.selector);
        new SS4Token("SteadyStake", "SS4", 0, _recipients());
    }

    /// §5.5: prove the supply fits ERC20Votes' uint208 checkpoints, and test the boundary.
    function test_Constructor_VotesSupplyBoundary() public {
        uint256 max = type(uint208).max;
        SS4Token atLimit = new SS4Token("SteadyStake", "SS4", max, _recipients());
        assertEq(atLimit.totalSupply(), max, "exactly at the limit is allowed");

        vm.expectRevert(abi.encodeWithSelector(SS4Token.SupplyExceedsVotesLimit.selector, max + 1, max));
        new SS4Token("SteadyStake", "SS4", max + 1, _recipients());
    }

    // ---------------------------------------------------------------------
    // Permit (§26.1)
    // ---------------------------------------------------------------------

    function test_Permit_Succeeds_AndNonceCannotReplay() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        vm.prank(treasury);
        token.transfer(owner, 100e18);

        address spender = address(0xCAFE);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, spender, 50e18, token.nonces(owner), deadline);

        token.permit(owner, spender, 50e18, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), 50e18);
        assertEq(token.nonces(owner), 1, "nonce consumed");

        // Replaying the same signature must fail now that the nonce moved.
        vm.expectRevert();
        token.permit(owner, spender, 50e18, deadline, v, r, s);
    }

    function test_Permit_ExpiredDeadline_Reverts() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, address(0xCAFE), 1e18, 0, deadline);

        vm.expectRevert();
        token.permit(owner, address(0xCAFE), 1e18, deadline, v, r, s);
    }

    function test_Permit_WrongSigner_Reverts() public {
        address owner = vm.addr(0xA11CE);
        uint256 attackerKey = 0xBAD;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(attackerKey, owner, address(0xCAFE), 1e18, 0, deadline);

        vm.expectRevert();
        token.permit(owner, address(0xCAFE), 1e18, deadline, v, r, s);
    }

    /// A signature for a different chain id must not verify here (§5.6).
    function test_Permit_ChainIdMismatch_Reverts() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 wrongDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("SteadyStake")),
                keccak256(bytes("1")),
                block.chainid + 1, // different chain
                address(token)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(0xCAFE),
                1e18,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", wrongDomain, structHash)));

        vm.expectRevert();
        token.permit(owner, address(0xCAFE), 1e18, deadline, v, r, s);
    }

    // ---------------------------------------------------------------------
    // Votes (§26.1) — retained only to keep the governance option open
    // ---------------------------------------------------------------------

    function test_Votes_RequireExplicitDelegation() public {
        assertEq(token.getVotes(treasury), 0, "a balance alone carries no voting power");

        vm.prank(treasury);
        token.delegate(treasury);
        assertEq(token.getVotes(treasury), token.balanceOf(treasury), "delegation activates voting power");
    }

    function test_Votes_CheckpointsTrackTransfers() public {
        vm.prank(treasury);
        token.delegate(treasury);
        uint256 before = token.getVotes(treasury);

        vm.prank(treasury);
        token.transfer(address(0xBEEF), 1_000e18);
        assertEq(token.getVotes(treasury), before - 1_000e18, "votes follow the balance");
    }

    function _signPermit(
        uint256 key,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8, bytes32, bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }
}
