// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DCAResolver} from "../src/DCAResolver.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {MockSwapRouter} from "../src/SwapHelper.sol";
import {MockUSDC, MockToken} from "../src/MockTokens.sol";

contract DCAResolverTest is Test {
    DCAVault public vault;
    DCAResolver public resolver;
    MockSwapRouter public swapRouter;
    MockUSDC public usdc;
    MockToken public aero;
    
    address public user1;
    
    function setUp() public {
        // Deploy contracts
        usdc = new MockUSDC();
        swapRouter = new MockSwapRouter(address(usdc));
        vault = new DCAVault(address(swapRouter), address(usdc));
        resolver = new DCAResolver(address(vault));
        aero = new MockToken("Aerodrome", "AERO", 18);
        
        user1 = makeAddr("user1");
        usdc.mint(user1, 10000e6);
        aero.mint(address(swapRouter), 10000e18);
    }
    
    function test_Checker_NotReady() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            1000e6
        );
        vm.stopPrank();
        
        (bool canExec, bytes memory execPayload) = resolver.checker(user1, 0);
        
        assertFalse(canExec);
        assertEq(execPayload.length, 0);
    }
    
    function test_Checker_Ready() public {
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
        
        (bool canExec, bytes memory execPayload) = resolver.checker(user1, 0);
        
        assertTrue(canExec);
        assertTrue(execPayload.length > 0);
    }
    
    function test_BatchChecker() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 2000e6);
        
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.DAILY,
            100e6,
            1000e6
        );
        
        vault.createSchedule(
            address(aero),
            DCAVault.DCAFrequency.WEEKLY,
            100e6,
            1000e6
        );
        
        vm.stopPrank();
        
        vm.warp(block.timestamp + 1 days);
        
        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = 0;
        scheduleIds[1] = 1;
        
        (uint256[] memory executables, bytes[] memory execPayloads) = resolver.batchChecker(
            user1,
            scheduleIds
        );
        
        // Only first schedule should be ready
        assertEq(executables.length, 1);
        assertEq(execPayloads.length, 1);
        assertEq(executables[0], 0);
    }
}
