// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {SeasonRewardNFT} from "../src/SeasonRewardNFT.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

contract SeasonRewardNFTTest is Test {
    SeasonRewardNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal outsider = makeAddr("outsider");
    address internal rank1 = makeAddr("rank1");
    address internal rank2 = makeAddr("rank2");
    address internal rank3 = makeAddr("rank3");

    uint64 internal constant SEASON = 1;
    bytes4 internal constant ERC5192_ID = 0xb45a3c0e;

    event SeasonAwardMinted(
        uint64 indexed seasonId, uint8 indexed rank, address indexed winner, uint256 tokenId, uint8 bonusSlots
    );

    function setUp() public {
        nft = new SeasonRewardNFT(admin);
    }

    function _register(address w1, address w2, address w3) internal {
        address[3] memory winners = [w1, w2, w3];
        string[3] memory uris = [
            string("ipfs://chronarch"),
            string("ipfs://navigator"),
            string("ipfs://signal")
        ];
        vm.prank(admin);
        nft.registerSeasonResult(SEASON, keccak256("rules"), keccak256("snapshot"), winners, uris);
    }

    function test_Register_OnlyOnce() public {
        _register(rank1, rank2, rank3);
        assertTrue(nft.seasonRegistered(SEASON));

        address[3] memory winners = [rank1, rank2, rank3];
        string[3] memory uris = [string("a"), string("b"), string("c")];
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SeasonRewardNFT.SeasonAlreadyRegistered.selector, SEASON)
        );
        nft.registerSeasonResult(SEASON, keccak256("rules"), keccak256("snapshot"), winners, uris);
    }

    function test_Register_OnlyFinalizerRole() public {
        address[3] memory winners = [rank1, rank2, rank3];
        string[3] memory uris = [string("a"), string("b"), string("c")];
        vm.prank(outsider);
        vm.expectRevert();
        nft.registerSeasonResult(SEASON, keccak256("rules"), keccak256("snapshot"), winners, uris);
    }

    function test_Mint_MapsRankToBonusAndWinner() public {
        _register(rank1, rank2, rank3);

        uint256 t1 = nft.tokenIdFor(SEASON, 1);
        vm.expectEmit(true, true, true, true);
        emit SeasonAwardMinted(SEASON, 1, rank1, t1, 3);
        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 1);

        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 2);
        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 3);

        assertEq(nft.ownerOf(nft.tokenIdFor(SEASON, 1)), rank1);
        assertEq(nft.ownerOf(nft.tokenIdFor(SEASON, 2)), rank2);
        assertEq(nft.ownerOf(nft.tokenIdFor(SEASON, 3)), rank3);
        assertEq(nft.bonusSlots(nft.tokenIdFor(SEASON, 1)), 3);
        assertEq(nft.bonusSlots(nft.tokenIdFor(SEASON, 2)), 2);
        assertEq(nft.bonusSlots(nft.tokenIdFor(SEASON, 3)), 1);
        assertEq(nft.tokenURI(nft.tokenIdFor(SEASON, 1)), "ipfs://chronarch");
    }

    function test_Mint_Duplicate_Reverts() public {
        _register(rank1, rank2, rank3);
        uint256 t1 = nft.tokenIdFor(SEASON, 1);
        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewardNFT.AlreadyMinted.selector, t1));
        nft.mintSeasonAward(SEASON, 1);
    }

    function test_Mint_WithoutRegister_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewardNFT.SeasonNotRegistered.selector, SEASON));
        nft.mintSeasonAward(SEASON, 1);
    }

    function test_Mint_InvalidRank_Reverts() public {
        _register(rank1, rank2, rank3);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewardNFT.InvalidRank.selector, uint8(4)));
        nft.mintSeasonAward(SEASON, 4);
    }

    function test_Mint_ZeroWinner_Reverts() public {
        // Only two eligible players (§14.3): rank 3 has no winner.
        _register(rank1, rank2, address(0));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewardNFT.NoWinnerForRank.selector, SEASON, uint8(3)));
        nft.mintSeasonAward(SEASON, 3);
    }

    function test_Mint_OnlyMinterRole() public {
        _register(rank1, rank2, rank3);
        vm.prank(outsider);
        vm.expectRevert();
        nft.mintSeasonAward(SEASON, 1);
    }

    function test_Soulbound_TransferReverts() public {
        _register(rank1, rank2, rank3);
        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 1);
        uint256 t1 = nft.tokenIdFor(SEASON, 1);

        vm.prank(rank1);
        vm.expectRevert(SeasonRewardNFT.Soulbound.selector);
        nft.transferFrom(rank1, rank2, t1);
    }

    function test_Soulbound_ApproveReverts() public {
        _register(rank1, rank2, rank3);
        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 1);
        uint256 t1 = nft.tokenIdFor(SEASON, 1);

        vm.prank(rank1);
        vm.expectRevert(SeasonRewardNFT.Soulbound.selector);
        nft.approve(rank2, t1);

        vm.prank(rank1);
        vm.expectRevert(SeasonRewardNFT.Soulbound.selector);
        nft.setApprovalForAll(rank2, true);
    }

    function test_Locked_And_Interfaces() public {
        _register(rank1, rank2, rank3);
        vm.prank(admin);
        nft.mintSeasonAward(SEASON, 1);

        assertTrue(nft.locked(nft.tokenIdFor(SEASON, 1)), "token locked");
        assertTrue(nft.supportsInterface(ERC5192_ID), "ERC-5192");
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId), "ERC-721");
    }

    function test_Locked_UnmintedToken_Reverts() public {
        uint256 t1 = nft.tokenIdFor(SEASON, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, t1)
        );
        nft.locked(t1);
    }
}
