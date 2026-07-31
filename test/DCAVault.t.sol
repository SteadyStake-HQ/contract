// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {MockSwapRouter} from "../src/SwapHelper.sol";
import {MockUSDC, MockToken} from "../src/MockTokens.sol";

contract DCAVaultTest is Test {
    DCAVault public vault;
    MockSwapRouter public swapRouter;
    MockUSDC public usdc;
    MockToken public aero;
    
    address public user1;
    address public user2;
    
    uint256 constant INITIAL_USDC = 1000e6; // 1000 USDC
    
    event ScheduleCreated(
        address indexed user,
        uint256 indexed scheduleId,
        address targetToken,
        DCAVault.DCAFrequency frequency,
        uint256 amountPerInterval
    );
    
    function setUp() public {
        // Deploy contracts
        usdc = new MockUSDC();
        swapRouter = new MockSwapRouter(address(usdc));
        vault = new DCAVault(address(swapRouter), address(usdc));
        aero = new MockToken("Aerodrome", "AERO", 18);
        
        // Setup users
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Mint USDC to users
        usdc.mint(user1, INITIAL_USDC);
        usdc.mint(user2, INITIAL_USDC);
        
        // Mint target tokens to swap router (for mock swaps)
        aero.mint(address(swapRouter), 1000e18);
    }
    
    // ========== Creation Tests ==========
    function test_CreateSchedule() public {
        vm.startPrank(user1);
        
        uint256 amountPerInterval = 100e6; // 100 USDC weekly
        uint256 totalAmount = 1000e6; // 1000 USDC total
        
        // Approve vault to spend USDC
        usdc.approve(address(vault), totalAmount);
        
        // Create schedule
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            amountPerInterval,
            totalAmount
        );
        
        assertEq(scheduleId, 0);
        
        // Verify schedule
        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertEq(schedule.targetToken, address(aero));
        assertEq(schedule.amountPerInterval, amountPerInterval);
        assertEq(schedule.totalAmount, totalAmount);
        assertEq(uint256(schedule.frequency), uint256(DCAVault.DCAFrequency.WEEKLY));
        assertEq(schedule.lastExecutionTime, block.timestamp);
        assertTrue(schedule.active);
        assertFalse(vault.isScheduleReady(user1, scheduleId));
        
        // Verify USDC transferred
        assertEq(usdc.balanceOf(address(vault)), totalAmount);
        assertEq(usdc.balanceOf(user1), 0);
        
        vm.stopPrank();
    }
    
    function test_CreateMultipleSchedules() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), INITIAL_USDC * 2);
        
        // Create first schedule
        uint256 id1 = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.DAILY,
            50e6,
            500e6
        );
        
        // Create second schedule
        uint256 id2 = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            500e6
        );
        
        assertEq(id1, 0);
        assertEq(id2, 1);
        
        vm.stopPrank();
    }
    
    function test_CreateSchedule_RevertInvalidToken() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), 500e6);
        
        vm.expectRevert("Invalid target token");
        vault.createSchedule(
            address(0),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            500e6
        );
        
        vm.stopPrank();
    }
    
    function test_CreateSchedule_RevertInvalidAmount() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), 500e6);
        
        vm.expectRevert("Amount must be > 0");
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            0,
            500e6
        );
        
        vm.stopPrank();
    }
    
    function test_CreateSchedule_RevertTotalLessThanInterval() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), 500e6);
        
        vm.expectRevert("Total must be >= interval amount");
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            1000e6,
            500e6
        );
        
        vm.stopPrank();
    }
    
    // ========== Execution Tests ==========
    function test_ExecuteSwap_Ready() public {
        vm.startPrank(user1);
        
        uint256 amountPerInterval = 100e6;
        uint256 totalAmount = 1000e6;
        
        usdc.approve(address(vault), totalAmount);
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.DAILY,
            amountPerInterval,
            totalAmount
        );
        
        vm.stopPrank();
        
        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);
        
        // Check if ready
        assertTrue(vault.isScheduleReady(user1, scheduleId));
        
        // Execute swap
        vm.prank(user1);
        vault.executeSwap(user1, scheduleId, "");
        
        // Verify schedule updated
        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertEq(schedule.executedCount, 1);
        assertEq(schedule.totalAmount, totalAmount - amountPerInterval);
    }
    
    function test_ExecuteSwap_NotReady() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), 1000e6);
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            1000e6
        );
        
        // Try to execute immediately
        vm.expectRevert("Not enough time passed");
        vault.executeSwap(user1, scheduleId, "");
        
        vm.stopPrank();
    }

    function test_DelayedExecutionKeepsOriginalCadence() public {
        vm.startPrank(user1);

        usdc.approve(address(vault), 300e6);
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.ONEMIN,
            100e6,
            300e6
        );
        uint256 createdAt = block.timestamp;

        vm.warp(createdAt + 65 seconds);
        vault.executeSwap(user1, scheduleId, "");

        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertEq(schedule.lastExecutionTime, createdAt + 60 seconds);
        assertFalse(vault.isScheduleReady(user1, scheduleId));

        vm.warp(createdAt + 120 seconds);
        assertTrue(vault.isScheduleReady(user1, scheduleId));

        vm.stopPrank();
    }

    function test_CreateScheduleAndEnrollWaitsForFirstInterval() public {
        vm.startPrank(user1);

        uint256 amountPerInterval = 100e6;
        usdc.approve(address(vault), amountPerInterval);
        uint256 scheduleId = vault.createScheduleAndEnrollWithGas(
            address(aero),
            DCAVault.DCAFrequency.ONEMIN,
            amountPerInterval,
            amountPerInterval,
            0
        );

        assertTrue(vault.enrolledForAutoExecution(user1, scheduleId));
        assertFalse(vault.isScheduleReady(user1, scheduleId));

        vm.warp(block.timestamp + 1 minutes);
        assertTrue(vault.isScheduleReady(user1, scheduleId));

        vm.stopPrank();
    }

    function test_FinalAutoExecution_ReleasesEnrollmentSlot() public {
        vm.startPrank(user1);

        uint256 amountPerInterval = 100e6;
        usdc.approve(address(vault), amountPerInterval);
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.ONEMIN,
            amountPerInterval,
            amountPerInterval
        );
        vault.enrollForAutoExecution(scheduleId);

        assertTrue(vault.enrolledForAutoExecution(user1, scheduleId));
        assertEq(vault.enrolledCount(user1), 1);

        vm.warp(block.timestamp + 1 minutes);
        vault.executeSwap(user1, scheduleId, "");

        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertFalse(schedule.active);
        assertFalse(vault.enrolledForAutoExecution(user1, scheduleId));
        assertEq(vault.enrolledCount(user1), 0);

        vm.stopPrank();
    }
    
    function test_CancelSchedule() public {
        vm.startPrank(user1);
        
        uint256 totalAmount = 1000e6;
        usdc.approve(address(vault), totalAmount);
        
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            totalAmount
        );
        
        // Cancel schedule immediately (100% remaining > 50% threshold)
        // Should charge 3% early exit fee: 1000e6 * 3% = 30e6
        uint256 expectedFee = (totalAmount * 300) / 10000;
        uint256 expectedReturn = totalAmount - expectedFee;
        
        vault.cancelSchedule(scheduleId);
        
        // Verify cancelled
        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertFalse(schedule.active);
        
        // Verify USDC returned minus 3% early exit fee
        assertEq(usdc.balanceOf(user1), expectedReturn);
        
        vm.stopPrank();
    }
    
    // ========== New Features: 1MIN Frequency & Early Cancel Fee ==========
    function test_CreateSchedule_OneMinFrequency() public {
        vm.startPrank(user1);
        
        uint256 amountPerInterval = 100e6; // 100 USDC per minute (for testing)
        uint256 totalAmount = 500e6; // 500 USDC total
        
        usdc.approve(address(vault), totalAmount);
        
        // Create schedule with 1 MIN frequency
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.ONEMIN,
            amountPerInterval,
            totalAmount
        );
        
        // Verify schedule
        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertEq(uint256(schedule.frequency), uint256(DCAVault.DCAFrequency.ONEMIN));
        assertEq(schedule.totalAmount, totalAmount);
        assertTrue(schedule.active);
        
        vm.stopPrank();
    }
    
    function test_CancelSchedule_WithEarlyExitFee() public {
        vm.startPrank(user1);
        
        uint256 totalAmount = 1000e6;
        usdc.approve(address(vault), totalAmount);
        
        // Create schedule
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            totalAmount
        );
        
        // Cancel immediately (no executions) - should pay 3% early exit fee
        // Remaining = 1000e6 (100% > 50%), so should charge 3% = 30e6
        uint256 expectedFee = (totalAmount * 300) / 10000; // 3% = 30e6
        uint256 expectedReturn = totalAmount - expectedFee;
        
        vault.cancelSchedule(scheduleId);
        
        // Verify cancelled
        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        assertFalse(schedule.active);
        
        // Verify USDC returned minus fee
        assertEq(usdc.balanceOf(user1), expectedReturn);
        
        // Note: fees go to vault (totalFeesCollected)
        
        vm.stopPrank();
    }
    
    function test_CancelSchedule_NoFeeAfterHalfExecuted() public {
        vm.startPrank(user1);
        
        uint256 totalAmount = 1000e6;
        uint256 amountPerInterval = 100e6;
        usdc.approve(address(vault), totalAmount);
        
        // Create schedule
        uint256 scheduleId = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.ONEMIN,
            amountPerInterval,
            totalAmount
        );
        
        // Execute swap enough times to use more than 50%
        // Execute 6 times = 600e6 used, 400e6 remaining (40% < 50%)
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 1 minutes + 1);
            vault.executeSwap(user1, scheduleId, "");
        }
        
        // Verify remaining < 50%
        DCAVault.DCASchedule memory schedule = vault.getSchedule(user1, scheduleId);
        uint256 originalTotal = totalAmount;
        uint256 remaining = schedule.totalAmount;
        require(remaining <= (originalTotal * 5000) / 10000, "Test setup error");
        
        // Cancel - should NOT charge early exit fee
        vault.cancelSchedule(scheduleId);
        
        // Verify cancelled
        schedule = vault.getSchedule(user1, scheduleId);
        assertFalse(schedule.active);
        
        // Verify full USDC returned (no fee since > 50% already used)
        assertEq(usdc.balanceOf(user1), remaining);
        
        vm.stopPrank();
    }
    
    function test_GetActiveSchedules() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), INITIAL_USDC);
        
        // Get current schedule count for user1
        uint256 baseCount = vault.getActiveSchedules(user1).length;
        
        uint256 id0 = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.DAILY,
            100e6,
            300e6
        );
        
        uint256 id1 = vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            300e6
        );
        
        // Should have 2 more active schedules than before
        uint256[] memory active = vault.getActiveSchedules(user1);
        assertEq(active.length, baseCount + 2);
        
        // Verify the created schedules are in the active list
        bool foundId0 = false;
        bool foundId1 = false;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == id0) foundId0 = true;
            if (active[i] == id1) foundId1 = true;
        }
        assertTrue(foundId0, "Schedule id0 not in active list");
        assertTrue(foundId1, "Schedule id1 not in active list");
        
        vm.stopPrank();
    }
    
    // ========== Fee Tests ==========
    function test_FeeCollection() public {
        vm.startPrank(user1);
        
        usdc.approve(address(vault), 1000e6);
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.DAILY,
            100e6,
            1000e6
        );
        
        vm.stopPrank();
        
        vm.warp(block.timestamp + 1 days);
        
        vm.prank(user1);
        vault.executeSwap(user1, 0, "");
        
        // Fee should be collected (0.25% of 100 USDC = 0.025 USDC)
        uint256 expectedFee = (100e6 * 25) / 10000; // 0.25e6
        assertEq(vault.totalFeesCollected(), expectedFee);
    }
    
    // ========== Admin Tests ==========
    function test_SetFeePercentage() public {
        vault.setFeePercentage(50); // 0.5%
        assertEq(vault.feePercentage(), 50);
    }
    
    function test_SetFeePercentage_RevertTooHigh() public {
        vm.expectRevert("Fee too high");
        vault.setFeePercentage(600); // > 5%
    }
    
    function test_Pause() public {
        vault.pause();

        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);

        vm.expectRevert();
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            1000e6
        );

        vm.stopPrank();
    }

    /// @dev The cap tracks the stablecoin's decimals rather than a hardcoded 1e6.
    function test_MaxTotalDeposit_TracksStableDecimals() public view {
        assertEq(vault.maxTotalDeposit(), 10_000_000e6, "6-decimal stable caps at 10M tokens");
    }

    /**
     * BNB Chain settles in 18-decimal Binance-Peg USDC. Under the old `10_000_000e6` literal that
     * cap was 1e13 base units — $0.00001 — so an ordinary deposit reverted with "Amount too large".
     */
    function test_CreateSchedule_18DecimalStable() public {
        MockToken stable18 = new MockToken("Binance-Peg USD Coin", "USDC", 18);
        MockSwapRouter router18 = new MockSwapRouter(address(stable18));
        DCAVault vault18 = new DCAVault(address(router18), address(stable18));

        assertEq(vault18.maxTotalDeposit(), 10_000_000e18, "18-decimal stable caps at 10M tokens");

        stable18.mint(user1, 1000e18);
        vm.startPrank(user1);
        stable18.approve(address(vault18), 1000e18);
        // 1000 whole tokens — 1e21 base units, far above the old 1e13 ceiling.
        vault18.createSchedule(address(aero), DCAVault.DCAFrequency.WEEKLY, 100e18, 1000e18);
        vm.stopPrank();

        (, , uint256 amountPerInterval, , uint256 totalAmount, , ) = vault18.schedules(user1, 0);
        assertEq(amountPerInterval, 100e18);
        assertEq(totalAmount, 1000e18);
    }

    function test_CreateSchedule_18DecimalStable_RevertAboveCap() public {
        MockToken stable18 = new MockToken("Binance-Peg USD Coin", "USDC", 18);
        MockSwapRouter router18 = new MockSwapRouter(address(stable18));
        DCAVault vault18 = new DCAVault(address(router18), address(stable18));

        uint256 tooMuch = 10_000_001e18;
        stable18.mint(user1, tooMuch);
        vm.startPrank(user1);
        stable18.approve(address(vault18), tooMuch);
        vm.expectRevert("Amount too large");
        vault18.createSchedule(address(aero), DCAVault.DCAFrequency.WEEKLY, 100e18, tooMuch);
        vm.stopPrank();
    }
}
