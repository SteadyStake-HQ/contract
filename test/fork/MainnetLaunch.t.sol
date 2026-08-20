// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {SS4PresaleV3} from "../../src/sale/SS4PresaleV3.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Fork test against the LIVE BOT Chain mainnet sale (677).
 *
 * @dev Proves a real buyer can complete a purchase on the deployed, frozen contract — both the
 *      plain path and the campaign path — and that each published limit actually bites, all
 *      without spending anything on chain.
 *
 *      This is deliberately a fork test rather than a unit test against a fresh deployment: the
 *      question it answers is not "does SS4PresaleV3 work" (the unit suite covers that) but "is
 *      the thing we just froze at 0x1EfE…BD13 actually sellable, with the real USDT, at the real
 *      terms". Only the live state can answer that.
 *
 *      Run: forge test --match-path "test/fork/MainnetLaunch.t.sol"
 */
contract MainnetLaunchTest is Test {
    SS4PresaleV3 constant PRESALE = SS4PresaleV3(0x1EfEA1a3A4FA3fdedfAd4005dDB94eDF7B36BD13);
    IERC20 constant SS4 = IERC20(0xf21f791937263F22c1860DfbcB975deCfCDe5D1f);
    IERC20 constant USDT = IERC20(0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C);

    /// @dev The mainnet campaign signer. Its key is used here only to reproduce a backend voucher.
    uint256 constant SIGNER_PK = 0xc1823008a88042da85fb26d317c3fd9c684467ac90372d97a1523fd0f409e3e5;

    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork("https://rpc.botchain.ai");
    }

    function test_saleIsActiveAndFrozenOnPublishedTerms() public view {
        assertEq(uint8(PRESALE.state()), 1, "sale must be Active");
        assertTrue(PRESALE.configFrozen(), "config must be frozen");
        assertFalse(PRESALE.paused(), "must not be paused");
        assertEq(PRESALE.priceUsdE6(), 4000, "price must be $0.004");
        assertEq(PRESALE.softCapUsdE6(), 16_000e6, "soft cap must be $16,000");
        assertEq(PRESALE.hardCapUsdE6(), 200_000e6, "hard cap must be $200,000");
        assertEq(PRESALE.minPurchaseUsdE6(), 4e6, "minimum must be $4");
        assertEq(PRESALE.maxPurchasePerWalletUsdE6(), 4444e6, "wallet cap must be $4,444");
        assertEq(PRESALE.maxCampaignBoostBps(), 550, "campaign ceiling must be +5.50%");
        assertEq(SS4.balanceOf(address(PRESALE)), 57_500_000e18, "sale + bonus pools must be funded");
    }

    function test_plainBuySucceeds() public {
        uint256 pay = 100e6; // $100
        deal(address(USDT), buyer, pay);

        vm.startPrank(buyer);
        USDT.approve(address(PRESALE), pay);
        PRESALE.buy(address(USDT), pay, 0);
        vm.stopPrank();

        // $100 / $0.004 = 25,000 SS4
        assertEq(PRESALE.purchasedSs4(buyer), 25_000e18, "should be credited 25,000 SS4");
        assertEq(PRESALE.contributedUsdE6(buyer), pay, "contribution recorded");
        console2.log("plain buy    -> SS4 credited:", PRESALE.purchasedSs4(buyer));
    }

    function test_campaignBuyAppliesTheFullBoost() public {
        uint256 pay = 100e6;
        deal(address(USDT), buyer, pay);

        uint16 boostBps = PRESALE.maxCampaignBoostBps(); // 550
        uint64 deadline = uint64(block.timestamp + 600);
        uint64 nonce = 1;

        // Reproduces exactly what the backend signs: the contract's own digest, signed by the key
        // that holds CAMPAIGN_SIGNER_ROLE.
        bytes32 digest = PRESALE.campaignVoucherDigest(buyer, boostBps, deadline, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);

        vm.startPrank(buyer);
        USDT.approve(address(PRESALE), pay);
        PRESALE.buyWithCampaign(
            address(USDT), pay, 0, boostBps, deadline, nonce, abi.encodePacked(r, s, v), address(0)
        );
        vm.stopPrank();

        // 25,000 base + 5.50% = 26,375 SS4
        uint256 got = PRESALE.purchasedSs4(buyer);
        assertEq(got, 26_375e18, "should be 25,000 + 5.50% boost");
        console2.log("campaign buy -> SS4 credited:", got);
        console2.log("boost paid from reserve:     ", got - 25_000e18);
    }

    function test_belowMinimumReverts() public {
        uint256 pay = 3e6; // $3, under the $4 floor
        deal(address(USDT), buyer, pay);
        vm.startPrank(buyer);
        USDT.approve(address(PRESALE), pay);
        vm.expectRevert();
        PRESALE.buy(address(USDT), pay, 0);
        vm.stopPrank();
    }

    function test_overWalletCapReverts() public {
        uint256 pay = 5000e6; // over the $4,444 wallet cap
        deal(address(USDT), buyer, pay);
        vm.startPrank(buyer);
        USDT.approve(address(PRESALE), pay);
        vm.expectRevert();
        PRESALE.buy(address(USDT), pay, 0);
        vm.stopPrank();
    }

    /// @dev A voucher above the frozen ceiling is a forged/broken attestation, and v3 reverts on it
    ///      rather than clamping — so the backend must never attest more than 550.
    function test_voucherOverCeilingReverts() public {
        uint256 pay = 100e6;
        deal(address(USDT), buyer, pay);

        uint16 tooMuch = PRESALE.maxCampaignBoostBps() + 1; // 551 > frozen 550
        uint64 deadline = uint64(block.timestamp + 600);
        bytes32 digest = PRESALE.campaignVoucherDigest(buyer, tooMuch, deadline, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);

        vm.startPrank(buyer);
        USDT.approve(address(PRESALE), pay);
        vm.expectRevert();
        PRESALE.buyWithCampaign(
            address(USDT), pay, 0, tooMuch, deadline, 1, abi.encodePacked(r, s, v), address(0)
        );
        vm.stopPrank();
    }

    /// @dev Single-use per (buyer, nonce): replaying a spent voucher must not pay a second boost.
    function test_voucherCannotBeReplayed() public {
        uint256 pay = 100e6;
        deal(address(USDT), buyer, pay * 2);

        uint16 boostBps = 550;
        uint64 deadline = uint64(block.timestamp + 600);
        uint64 nonce = 7;
        bytes32 digest = PRESALE.campaignVoucherDigest(buyer, boostBps, deadline, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(buyer);
        USDT.approve(address(PRESALE), pay * 2);
        PRESALE.buyWithCampaign(address(USDT), pay, 0, boostBps, deadline, nonce, sig, address(0));
        vm.expectRevert();
        PRESALE.buyWithCampaign(address(USDT), pay, 0, boostBps, deadline, nonce, sig, address(0));
        vm.stopPrank();
    }
}
