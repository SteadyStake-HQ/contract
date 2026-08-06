// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StablecoinGamePassCheckout} from "../src/StablecoinGamePassCheckout.sol";
import {MockUSDC, MockUSDT, MockFeeToken} from "../src/MockTokens.sol";

contract StablecoinGamePassCheckoutTest is Test {
    StablecoinGamePassCheckout internal checkout;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal buyer = makeAddr("buyer");
    address internal outsider = makeAddr("outsider");

    // Week Pass beta defaults (§5.1): 7 days, 3.99 USDC (6 decimals).
    uint8 internal constant PLAN_WEEK = 2;
    uint32 internal constant WEEK_SECONDS = 7 days;
    uint256 internal constant WEEK_PRICE = 3_990_000;

    event PassPaid(
        bytes32 indexed purchaseId,
        address indexed buyer,
        address indexed paymentToken,
        uint256 amount,
        uint8 planId,
        uint32 durationSeconds
    );

    function setUp() public {
        usdc = new MockUSDC();
        checkout = new StablecoinGamePassCheckout(address(usdc), treasury, admin);

        vm.prank(admin);
        checkout.setPlan(PLAN_WEEK, WEEK_SECONDS, WEEK_PRICE, true);

        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(checkout), type(uint256).max);
    }

    function test_BuyPass_MovesExactPriceToTreasury_AndEmits() public {
        bytes32 purchaseId = keccak256("intent-1");

        vm.expectEmit(true, true, true, true);
        emit PassPaid(purchaseId, buyer, address(usdc), WEEK_PRICE, PLAN_WEEK, WEEK_SECONDS);

        vm.prank(buyer);
        checkout.buyPass(PLAN_WEEK, purchaseId);

        assertEq(usdc.balanceOf(treasury), WEEK_PRICE, "treasury received exact price");
        assertEq(usdc.balanceOf(buyer), 100e6 - WEEK_PRICE, "buyer debited exact price");
        assertTrue(checkout.usedPurchaseIds(purchaseId), "purchase id burned");
    }

    function test_BuyPass_ReusedPurchaseId_Reverts() public {
        bytes32 purchaseId = keccak256("intent-dup");
        vm.prank(buyer);
        checkout.buyPass(PLAN_WEEK, purchaseId);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(StablecoinGamePassCheckout.PurchaseIdUsed.selector, purchaseId)
        );
        checkout.buyPass(PLAN_WEEK, purchaseId);
    }

    function test_BuyPass_DisabledPlan_Reverts() public {
        uint8 ghostPlan = 9;
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(StablecoinGamePassCheckout.PlanDisabled.selector, ghostPlan)
        );
        checkout.buyPass(ghostPlan, keccak256("intent-ghost"));
    }

    function test_BuyPass_WhenPaused_Reverts() public {
        vm.prank(admin);
        checkout.pause();

        vm.prank(buyer);
        vm.expectRevert();
        checkout.buyPass(PLAN_WEEK, keccak256("intent-paused"));
    }

    /// USDT returns nothing from transferFrom; SafeERC20 must still make it work (§18.4).
    function test_BuyPass_WithReturnlessUSDT_Works() public {
        MockUSDT usdt = new MockUSDT();
        StablecoinGamePassCheckout usdtCheckout =
            new StablecoinGamePassCheckout(address(usdt), treasury, admin);
        vm.prank(admin);
        usdtCheckout.setPlan(PLAN_WEEK, WEEK_SECONDS, WEEK_PRICE, true);

        usdt.mint(buyer, 100e6);
        vm.prank(buyer);
        usdt.approve(address(usdtCheckout), WEEK_PRICE);

        vm.prank(buyer);
        usdtCheckout.buyPass(PLAN_WEEK, keccak256("usdt-intent"));

        assertEq(usdt.balanceOf(treasury), WEEK_PRICE, "treasury received USDT");
    }

    /// A fee-on-transfer token delivers less than `price`; the delta check must reject it (§18.4).
    function test_BuyPass_WithFeeOnTransferToken_Reverts() public {
        MockFeeToken fee = new MockFeeToken(100); // 1% fee
        StablecoinGamePassCheckout feeCheckout =
            new StablecoinGamePassCheckout(address(fee), treasury, admin);
        vm.prank(admin);
        feeCheckout.setPlan(PLAN_WEEK, WEEK_SECONDS, WEEK_PRICE, true);

        fee.mint(buyer, 100e6);
        vm.prank(buyer);
        fee.approve(address(feeCheckout), type(uint256).max);

        uint256 received = WEEK_PRICE - (WEEK_PRICE * 100) / 10000;
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                StablecoinGamePassCheckout.UnexpectedAmountReceived.selector, WEEK_PRICE, received
            )
        );
        feeCheckout.buyPass(PLAN_WEEK, keccak256("fee-intent"));
    }

    function test_SetPlan_OnlyConfigRole() public {
        vm.prank(outsider);
        vm.expectRevert();
        checkout.setPlan(1, 1 days, 990_000, true);
    }

    function test_SetTreasury_OnlyTreasurerRole_AndRepoints() public {
        vm.prank(outsider);
        vm.expectRevert();
        checkout.setTreasury(outsider);

        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        checkout.setTreasury(newTreasury);
        assertEq(checkout.treasury(), newTreasury);
    }

    /// Distinct purchase ids each buy exactly once; the treasury total is n * price.
    function testFuzz_DistinctPurchaseIds_EachBuyOnce(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        usdc.mint(buyer, 100e6);

        vm.prank(buyer);
        checkout.buyPass(PLAN_WEEK, a);
        vm.prank(buyer);
        checkout.buyPass(PLAN_WEEK, b);

        assertEq(usdc.balanceOf(treasury), WEEK_PRICE * 2);
        assertTrue(checkout.usedPurchaseIds(a));
        assertTrue(checkout.usedPurchaseIds(b));
    }
}
