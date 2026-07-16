// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
    ReentrancyGuard
} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ISwapRouter {
    function swap(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}

interface IZeroExAdapter {
    function executeSwapWithData(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata swapData
    ) external returns (uint256 amountOut);
}

interface IGasTank {
    function depositFor(address user, uint256 amount) external;
}

/**
 * @title DCAVault
 * @notice Simplified DCA Vault for automated dollar-cost averaging
 * @dev Manages USDC deposits and automated recurring token swaps
 */
contract DCAVault is ERC20, ReentrancyGuard, Ownable, Pausable {
    // ============ Constants ============
    address public constant SONIC_FEEM = 0xDC2B0D2Dd2b7759D97D50db4eabDC36973110830;
    uint256 public constant SONIC_FEEM_PROJECT_ID = 248;
    uint256 public constant FEE_PRECISION = 10000; // 1 = 0.01%
    uint256 public constant MAX_FEE = 500; // 5%
    uint256 public constant EARLY_CANCEL_FEE = 300; // 3% early cancel fee
    uint256 public constant EARLY_CANCEL_THRESHOLD = 5000; // 50% (in basis points)

    // ============ Enums ============
    enum DCAFrequency {
        ONEMIN, // 1 minute (testing only)
        DAILY,
        WEEKLY,
        BIWEEKLY,
        MONTHLY
    }

    // ============ Structures ============
    struct DCASchedule {
        address targetToken;
        DCAFrequency frequency;
        uint256 amountPerInterval; // in USDC 6 decimals
        uint256 lastExecutionTime;
        uint256 totalAmount;
        uint256 executedCount;
        bool active;
    }

    struct SwapDetails {
        address tokenOut;
        uint256 minAmountOut;
        bytes swapData; // Encoded 1inch swap data
    }

    // ============ State Variables ============
    IERC20 public usdc;
    ISwapRouter public swapRouter;
    /// @notice Optional GasTank for createScheduleAndEnrollWithGas (fund user gas in same tx). Set by owner.
    address public gasTank;

    mapping(address => mapping(uint256 => DCASchedule)) public schedules; // user => scheduleId => schedule
    mapping(address => uint256) public scheduleCount;
    mapping(address => uint256[]) public activeSchedules;

    /// @notice Which schedules are enrolled for auto-execution (relayer runs them). One free per user per chain; additional require fee.
    mapping(address => mapping(uint256 => bool)) public enrolledForAutoExecution;
    mapping(address => uint256) public enrolledCount;
    uint256 public additionalAutoPlanFeeUsdc6; // fee in USDC 6 decimals for 2nd+ auto plan per user
    address public autoPlanFeeRecipient;

    uint256 public feePercentage = 25; // 0.25% default fee
    uint256 public totalFeesCollected;

    // ============ Events ============
    event ScheduleCreated(
        address indexed user,
        uint256 indexed scheduleId,
        address targetToken,
        DCAFrequency frequency,
        uint256 amountPerInterval
    );

    event ScheduleExecuted(
        address indexed user,
        uint256 indexed scheduleId,
        address targetToken,
        uint256 usdcAmount,
        uint256 tokenOut,
        uint256 fee
    );

    event ScheduleCancelled(
        address indexed user,
        uint256 indexed scheduleId,
        uint256 returnedAmount,
        uint256 cancelFee
    );

    event FeeCollected(uint256 amount);

    event EarlyCancelFeeCollected(address indexed user, uint256 amount);

    event SwapRouterUpdated(address newRouter);

    event FeePercentageUpdated(uint256 newFee);

    event EnrolledForAutoExecution(address indexed user, uint256 indexed scheduleId);
    event UnenrolledFromAutoExecution(address indexed user, uint256 indexed scheduleId);
    event GasTankUpdated(address indexed previousGasTank, address indexed newGasTank);

    // ============ Modifiers ============
    modifier validSchedule(address user, uint256 scheduleId) {
        require(scheduleId < scheduleCount[user], "Invalid schedule ID");
        require(schedules[user][scheduleId].active, "Schedule not active");
        _;
    }

    // ============ Initialize ============
    constructor(
        address _swapRouter,
        address _usdc
    ) ERC20("SteadyStake Vault", "stiUSDC") Ownable(msg.sender) {
        require(_swapRouter != address(0), "Invalid swap router");
        require(_usdc != address(0), "Invalid USDC address");
        swapRouter = ISwapRouter(_swapRouter);
        usdc = IERC20(_usdc);

        IERC20(_usdc).approve(_swapRouter, type(uint256).max);
    }

    // ============ Internal ============
    function _getIntervalSeconds(
        DCAFrequency frequency
    ) internal pure returns (uint256) {
        if (frequency == DCAFrequency.ONEMIN) return 1 minutes;
        if (frequency == DCAFrequency.DAILY) return 1 days;
        if (frequency == DCAFrequency.WEEKLY) return 7 days;
        if (frequency == DCAFrequency.BIWEEKLY) return 14 days;
        if (frequency == DCAFrequency.MONTHLY) return 30 days;
        revert("Invalid frequency");
    }

    function _calculateFee(uint256 amount) internal view returns (uint256) {
        return (amount * feePercentage) / FEE_PRECISION;
    }

    function _addActiveSchedule(address user) internal {
        activeSchedules[user].push(scheduleCount[user]);
    }

    function _removeActiveSchedule(address user, uint256 scheduleId) internal {
        uint256[] storage active = activeSchedules[user];
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == scheduleId) {
                active[i] = active[active.length - 1];
                active.pop();
                break;
            }
        }
    }

    // ============ External - DCA Functions ============
    /**
     * @notice Create a new DCA schedule
     * @param targetToken Token to swap USDC into
     * @param frequency How often to execute the swap
     * @param amountPerInterval USDC amount per interval (6 decimals)
     * @param totalAmount Total USDC to use for this schedule
     */
    function createSchedule(
        address targetToken,
        DCAFrequency frequency,
        uint256 amountPerInterval,
        uint256 totalAmount
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(targetToken != address(0), "Invalid target token");
        require(amountPerInterval > 0, "Amount must be > 0");
        require(
            totalAmount >= amountPerInterval,
            "Total must be >= interval amount"
        );
        require(totalAmount <= 10_000_000e6, "Amount too large"); // 10M USDC max

        // Transfer USDC from user to vault
        require(
            usdc.transferFrom(msg.sender, address(this), totalAmount),
            "Transfer failed"
        );

        uint256 scheduleId = scheduleCount[msg.sender];

        DCASchedule storage schedule = schedules[msg.sender][scheduleId];
        schedule.targetToken = targetToken;
        schedule.frequency = frequency;
        schedule.amountPerInterval = amountPerInterval;
        schedule.totalAmount = totalAmount;
        // Creation starts the first full DCA interval. Every client can derive
        // the same next execution time as lastExecutionTime + frequency.
        schedule.lastExecutionTime = block.timestamp;
        schedule.active = true;
        schedule.executedCount = 0;

        _addActiveSchedule(msg.sender);
        scheduleCount[msg.sender]++;

        emit ScheduleCreated(
            msg.sender,
            scheduleId,
            targetToken,
            frequency,
            amountPerInterval
        );

        return scheduleId;
    }

    /**
     * @notice Create a DCA schedule, enroll for auto-execution (first plan free), and optionally fund user's gas tank in one tx. Reduces user approvals to one (vault for totalAmount + gasAmountForTank).
     * @param targetToken Token to swap USDC into
     * @param frequency How often to execute the swap
     * @param amountPerInterval USDC amount per interval (6 decimals)
     * @param totalAmount Total USDC to use for this schedule
     * @param gasAmountForTank USDC to deposit to user's gas tank (6 decimals). Use 0 if no gas tank or manual exec. Requires enrolledCount[msg.sender] == 0 (first auto plan only).
     */
    function createScheduleAndEnrollWithGas(
        address targetToken,
        DCAFrequency frequency,
        uint256 amountPerInterval,
        uint256 totalAmount,
        uint256 gasAmountForTank
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(targetToken != address(0), "Invalid target token");
        require(amountPerInterval > 0, "Amount must be > 0");
        require(
            totalAmount >= amountPerInterval,
            "Total must be >= interval amount"
        );
        require(totalAmount <= 10_000_000e6, "Amount too large"); // 10M USDC max
        require(enrolledCount[msg.sender] == 0, "Use createSchedule then enroll for extra plan");

        uint256 pullAmount = totalAmount + gasAmountForTank;
        require(pullAmount > 0, "Amount must be > 0");
        if (gasAmountForTank > 0) require(gasTank != address(0), "GasTank not set");

        // Pull plan + gas from user in one approval
        require(
            usdc.transferFrom(msg.sender, address(this), pullAmount),
            "Transfer failed"
        );

        uint256 scheduleId = scheduleCount[msg.sender];

        DCASchedule storage schedule = schedules[msg.sender][scheduleId];
        schedule.targetToken = targetToken;
        schedule.frequency = frequency;
        schedule.amountPerInterval = amountPerInterval;
        schedule.totalAmount = totalAmount;
        // Creation starts the first full DCA interval, including auto plans.
        schedule.lastExecutionTime = block.timestamp;
        schedule.active = true;
        schedule.executedCount = 0;

        _addActiveSchedule(msg.sender);
        scheduleCount[msg.sender]++;

        // Enroll for auto-execution (first plan free)
        enrolledForAutoExecution[msg.sender][scheduleId] = true;
        enrolledCount[msg.sender]++;

        emit ScheduleCreated(
            msg.sender,
            scheduleId,
            targetToken,
            frequency,
            amountPerInterval
        );
        emit EnrolledForAutoExecution(msg.sender, scheduleId);

        // Fund user's gas tank if requested
        if (gasAmountForTank > 0 && gasTank != address(0)) {
            require(usdc.approve(gasTank, gasAmountForTank), "Approve failed");
            IGasTank(gasTank).depositFor(msg.sender, gasAmountForTank);
        }

        return scheduleId;
    }

    /**
     * @notice Execute a DCA swap for a user
     * @param user Address of the DCA user
     * @param scheduleId ID of the schedule to execute
     * @param swapData Encoded 1inch swap data
     */
    function executeSwap(
        address user,
        uint256 scheduleId,
        bytes calldata swapData
    ) external nonReentrant whenNotPaused validSchedule(user, scheduleId) {
        DCASchedule storage schedule = schedules[user][scheduleId];

        // Check if enough time has passed
        uint256 interval = _getIntervalSeconds(schedule.frequency);
        require(
            block.timestamp >= schedule.lastExecutionTime + interval,
            "Not enough time passed"
        );

        // Check if schedule has funds
        require(schedule.totalAmount > 0, "Schedule depleted");

        // Determine swap amount
        uint256 swapAmount = schedule.amountPerInterval > schedule.totalAmount
            ? schedule.totalAmount
            : schedule.amountPerInterval;

        // Calculate and collect fee
        uint256 fee = _calculateFee(swapAmount);
        uint256 netAmount = swapAmount - fee;

        // Keep executions anchored to the schedule's original cadence. If a
        // relayer confirms a few seconds late, the next due time still stays
        // on the user's selected boundary instead of drifting on every run.
        uint256 elapsedIntervals = (block.timestamp -
            schedule.lastExecutionTime) / interval;
        schedule.totalAmount -= swapAmount;
        schedule.lastExecutionTime += elapsedIntervals * interval;
        schedule.executedCount++;

        if (schedule.totalAmount == 0) {
            schedule.active = false;
            _removeActiveSchedule(user, scheduleId);
            if (enrolledForAutoExecution[user][scheduleId]) {
                enrolledForAutoExecution[user][scheduleId] = false;
                enrolledCount[user]--;
                emit UnenrolledFromAutoExecution(user, scheduleId);
            }
        }

        totalFeesCollected += fee;

        // Execute swap through swap router
        // This would typically be handled by Gelato but can be called directly
        _performSwap(user, schedule.targetToken, netAmount, swapData);

        emit ScheduleExecuted(
            user,
            scheduleId,
            schedule.targetToken,
            netAmount,
            0,
            fee
        );
        emit FeeCollected(fee);
    }

    /**
     * @notice Cancel an active DCA schedule
     * @dev If remaining > 50% of original total, charge 3% early exit fee
     * @dev If remaining <= 50% of original total, no early exit fee
     * @param scheduleId ID of the schedule to cancel
     */
    function cancelSchedule(
        uint256 scheduleId
    ) external nonReentrant validSchedule(msg.sender, scheduleId) {
        DCASchedule storage schedule = schedules[msg.sender][scheduleId];
        uint256 remainingAmount = schedule.totalAmount;
        uint256 originalTotal = schedule.totalAmount +
            (schedule.amountPerInterval * schedule.executedCount);

        // Calculate if early cancellation fee applies
        uint256 cancelFee = 0;
        uint256 returnAmount = remainingAmount;

        // Check if remaining > 50% of original total (early exit)
        if (
            remainingAmount >
            (originalTotal * EARLY_CANCEL_THRESHOLD) / FEE_PRECISION
        ) {
            // Charge 3% early cancellation fee
            cancelFee = (remainingAmount * EARLY_CANCEL_FEE) / FEE_PRECISION;
            returnAmount = remainingAmount - cancelFee;
            totalFeesCollected += cancelFee;
            emit EarlyCancelFeeCollected(msg.sender, cancelFee);
        }

        // Free auto-execution slot if this schedule was enrolled
        if (enrolledForAutoExecution[msg.sender][scheduleId]) {
            enrolledForAutoExecution[msg.sender][scheduleId] = false;
            enrolledCount[msg.sender]--;
            emit UnenrolledFromAutoExecution(msg.sender, scheduleId);
        }

        schedule.active = false;
        schedule.totalAmount = 0;
        _removeActiveSchedule(msg.sender, scheduleId);

        // Return USDC to user (minus early cancel fee if applicable)
        require(usdc.transfer(msg.sender, returnAmount), "Transfer failed");

        emit ScheduleCancelled(msg.sender, scheduleId, returnAmount, cancelFee);
    }

    /**
     * @notice Enroll a schedule for auto-execution. First plan per user is free; additional plans require fee.
     * @param scheduleId ID of the schedule to enroll
     */
    function enrollForAutoExecution(
        uint256 scheduleId
    ) external nonReentrant whenNotPaused {
        require(scheduleId < scheduleCount[msg.sender], "Invalid schedule ID");
        DCASchedule storage schedule = schedules[msg.sender][scheduleId];
        require(schedule.active && schedule.totalAmount > 0, "Schedule not active");
        require(!enrolledForAutoExecution[msg.sender][scheduleId], "Already enrolled");

        if (enrolledCount[msg.sender] == 0) {
            // First auto plan: free
            enrolledForAutoExecution[msg.sender][scheduleId] = true;
            enrolledCount[msg.sender]++;
            emit EnrolledForAutoExecution(msg.sender, scheduleId);
            return;
        }
        // Additional auto plan: require fee
        require(additionalAutoPlanFeeUsdc6 > 0, "Additional auto plan fee not set");
        require(autoPlanFeeRecipient != address(0), "Fee recipient not set");
        require(
            usdc.transferFrom(msg.sender, autoPlanFeeRecipient, additionalAutoPlanFeeUsdc6),
            "Fee transfer failed"
        );
        enrolledForAutoExecution[msg.sender][scheduleId] = true;
        enrolledCount[msg.sender]++;
        emit EnrolledForAutoExecution(msg.sender, scheduleId);
    }

    /**
     * @notice Get schedule IDs enrolled for auto-execution for a user
     */
    function getEnrolledScheduleIds(
        address user
    ) external view returns (uint256[] memory) {
        uint256 n = scheduleCount[user];
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            if (enrolledForAutoExecution[user][i]) count++;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < n; i++) {
            if (enrolledForAutoExecution[user][i]) {
                ids[j] = i;
                j++;
            }
        }
        return ids;
    }

    /**
     * @notice Perform the actual swap: 0x via adapter when swapData provided, else ISwapRouter
     */
    function _performSwap(
        address user,
        address targetToken,
        uint256 amount,
        bytes calldata swapData
    ) internal {
        if (swapData.length > 0) {
            IZeroExAdapter(address(swapRouter)).executeSwapWithData(
                targetToken,
                amount,
                0,
                user,
                swapData
            );
        } else {
            swapRouter.swap(targetToken, amount, 0, user);
        }
    }

    /**
     * @notice Get all active schedules for a user
     */
    function getActiveSchedules(
        address user
    ) external view returns (uint256[] memory) {
        return activeSchedules[user];
    }

    /**
     * @notice Get schedule details
     */
    function getSchedule(
        address user,
        uint256 scheduleId
    ) external view returns (DCASchedule memory) {
        return schedules[user][scheduleId];
    }

    /**
     * @notice Check if a schedule is ready to execute
     */
    function isScheduleReady(
        address user,
        uint256 scheduleId
    ) external view returns (bool) {
        if (scheduleId >= scheduleCount[user]) return false;

        DCASchedule memory schedule = schedules[user][scheduleId];
        if (!schedule.active || schedule.totalAmount == 0) return false;

        uint256 interval = _getIntervalSeconds(schedule.frequency);
        return block.timestamp >= schedule.lastExecutionTime + interval;
    }

    /**
     * @notice Get schedule IDs that are ready to execute (saves backend from calling isScheduleReady per schedule)
     */
    function getReadyScheduleIds(
        address user
    ) external view returns (uint256[] memory) {
        uint256[] storage active = activeSchedules[user];
        uint256 readyCount = 0;
        for (uint256 i = 0; i < active.length; i++) {
            uint256 scheduleId = active[i];
            DCASchedule memory schedule = schedules[user][scheduleId];
            if (!schedule.active || schedule.totalAmount == 0) continue;
            uint256 interval = _getIntervalSeconds(schedule.frequency);
            if (block.timestamp >= schedule.lastExecutionTime + interval) {
                readyCount++;
            }
        }
        uint256[] memory readyIds = new uint256[](readyCount);
        uint256 j = 0;
        for (uint256 i = 0; i < active.length; i++) {
            uint256 scheduleId = active[i];
            DCASchedule memory schedule = schedules[user][scheduleId];
            if (!schedule.active || schedule.totalAmount == 0) continue;
            uint256 interval = _getIntervalSeconds(schedule.frequency);
            if (block.timestamp >= schedule.lastExecutionTime + interval) {
                readyIds[j] = scheduleId;
                j++;
            }
        }
        return readyIds;
    }

    // ============ Admin Functions ============
    function setSwapRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Invalid address");
        swapRouter = ISwapRouter(newRouter);
        emit SwapRouterUpdated(newRouter);
    }

    function setGasTank(address newGasTank) external onlyOwner {
        address previous = gasTank;
        gasTank = newGasTank;
        emit GasTankUpdated(previous, newGasTank);
    }

    function setFeePercentage(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "Fee too high");
        feePercentage = newFee;
        emit FeePercentageUpdated(newFee);
    }

    function setAdditionalAutoPlanFeeUsdc6(uint256 feeUsdc6) external onlyOwner {
        additionalAutoPlanFeeUsdc6 = feeUsdc6;
    }

    function setAutoPlanFeeRecipient(address recipient) external onlyOwner {
        autoPlanFeeRecipient = recipient;
    }

    /// @dev Register this contract on Sonic FeeM after deployment on Sonic.
    function registerMe() external onlyOwner {
        (bool success,) = SONIC_FEEM.call(
            abi.encodeWithSignature(
                "selfRegister(uint256)",
                SONIC_FEEM_PROJECT_ID
            )
        );
        require(success, "FeeM registration failed");
    }

    function withdrawFees() external onlyOwner {
        uint256 amount = totalFeesCollected;
        totalFeesCollected = 0;
        require(usdc.transfer(msg.sender, amount), "Transfer failed");
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ ERC-4626 Implementation ============
    function totalAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
