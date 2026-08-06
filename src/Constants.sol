// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IConstants
 * @notice Global constants for SteadyStake protocol
 */
interface IConstants {
    // Network constants
    function CHAIN_ID() external pure returns (uint256);
    function USDC_ADDRESS() external pure returns (address);
    function ZERO_EX_ROUTER() external pure returns (address);
    function GELATO_OPS() external pure returns (address);
}

/**
 * @title Constants
 * @notice Implementation of protocol constants for Base
 */
library Constants {
    // Chain
    uint256 public constant CHAIN_ID = 8453; // Base mainnet
    uint256 public constant CHAIN_ID_SEPOLIA = 84532; // Base Sepolia

    // Addresses on Base
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant ZERO_EX_ROUTER = 0x0000000000001fF3684f28c67538d4D072C22734; // 0x AllowanceHolder
    address public constant GELATO_OPS = 0x340759c8346A1E6b1d541d5696357A50A3D923F9;

    // Fee constants
    uint256 public constant FEE_PRECISION = 10000; // 1 = 0.01%
    uint256 public constant DEFAULT_FEE = 25; // 0.25%
    uint256 public constant MAX_FEE = 500; // 5%

    // Amount constants
    uint256 public constant MAX_DEPOSIT = 10_000_000e6; // 10M USDC
    uint256 public constant MIN_INTERVAL_AMOUNT = 1e6; // 1 USDC
    
    // Time constants
    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant ONE_WEEK = 7 days;
    uint256 public constant TWO_WEEKS = 14 days;
    uint256 public constant ONE_MONTH = 30 days;

    // Common tokens on Base
    address public constant AERO = 0x940181A94A35Dc584061Deea9b928900AA048AF6;
    address public constant DEGEN = 0x4Ed4e862860bED51a9570b96D89af5e1b0eFeFFa;
    address public constant CBETH = 0x2Ae3F1eC7F1F5012CfEAb0411a822B6f2b7B0020;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant USDC_BRIDGES = 0xD9aAEc86B65d86f6A7B630e5b0aF435D5d1Cd33f;
}

/**
 * @title FrequencyHelpers
 * @notice Utility functions for DCA frequency handling
 */
library FrequencyHelpers {
    enum Frequency {
        DAILY,
        WEEKLY,
        BIWEEKLY,
        MONTHLY
    }

    function toSeconds(Frequency freq) internal pure returns (uint256) {
        if (freq == Frequency.DAILY) return 1 days;
        if (freq == Frequency.WEEKLY) return 7 days;
        if (freq == Frequency.BIWEEKLY) return 14 days;
        if (freq == Frequency.MONTHLY) return 30 days;
        revert("Invalid frequency");
    }

    function toString(Frequency freq) internal pure returns (string memory) {
        if (freq == Frequency.DAILY) return "DAILY";
        if (freq == Frequency.WEEKLY) return "WEEKLY";
        if (freq == Frequency.BIWEEKLY) return "BIWEEKLY";
        if (freq == Frequency.MONTHLY) return "MONTHLY";
        revert("Invalid frequency");
    }
}

/**
 * @title MathHelpers
 * @notice Math utilities for precision calculations
 */
library MathHelpers {
    /**
     * @notice Calculate fee taken from amount
     * @param amount Amount in USDC (6 decimals)
     * @param feePercentage Fee percentage (1 = 0.01%)
     */
    function calculateFee(uint256 amount, uint256 feePercentage) internal pure returns (uint256) {
        return (amount * feePercentage) / Constants.FEE_PRECISION;
    }

    /**
     * @notice Calculate net amount after fee
     */
    function netAmount(uint256 amount, uint256 feePercentage) internal pure returns (uint256) {
        return amount - calculateFee(amount, feePercentage);
    }

    /**
     * @notice Convert USDC amounts to different decimals
     */
    function usdcToDecimals(uint256 amount, uint8 destinationDecimals) internal pure returns (uint256) {
        if (destinationDecimals < 6) {
            return amount / (10 ** (6 - destinationDecimals));
        } else if (destinationDecimals > 6) {
            return amount * (10 ** (destinationDecimals - 6));
        }
        return amount;
    }

    /**
     * @notice Calculate execution count for a schedule
     */
    function calculateExecutionCount(
        uint256 totalAmount,
        uint256 amountPerInterval
    ) internal pure returns (uint256) {
        return totalAmount / amountPerInterval;
    }
}

/**
 * @title Errors
 * @notice Custom error definitions for SteadyStake
 */
interface IErrors {
    error InvalidToken();
    error InvalidAmount();
    error InsufficientBalance();
    error ScheduleNotActive();
    error ScheduleNotReady();
    error ExecutionFailed();
    error FeeTooHigh();
    error Unauthorized();
    error ContractPaused();
}

/**
 * @title Events
 * @notice Event definitions for SteadyStake
 */
interface IEvents {
    event ScheduleCreated(
        address indexed user,
        uint256 indexed scheduleId,
        address targetToken,
        uint8 frequency,
        uint256 amountPerInterval,
        uint256 totalAmount
    );

    event ScheduleExecuted(
        address indexed user,
        uint256 indexed scheduleId,
        address targetToken,
        uint256 usdcAmount,
        uint256 tokenOut,
        uint256 fee
    );

    event ScheduleCancelled(address indexed user, uint256 indexed scheduleId, uint256 refund);

    event FeeCollected(uint256 amount);

    event FeePercentageUpdated(uint256 previousFee, uint256 newFee);

    event SwapRouterUpdated(address previousRouter, address newRouter);

    event VaultPaused(uint256 timestamp);

    event VaultUnpaused(uint256 timestamp);
}
