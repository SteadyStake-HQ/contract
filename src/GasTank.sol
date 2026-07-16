// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title GasTank
 * @notice Holds user USDC balances used to pay for DCA execution gas. The backend relayer
 *         executes DCA swaps (pays gas) and calls recordExecution to deduct from the user's
 *         tank and reimburse the relayer. Each network has its own GasTank; gas cost per
 *         execution is set per contract (e.g. Base $0.005, BSC $0.01) and is editable by owner.
 */
contract GasTank is ReentrancyGuard, Ownable {
    IERC20 public immutable usdc;

    /// @notice Relayer/executor address allowed to call recordExecution
    address public executor;

    /// @notice Gas cost per DCA execution in USDC (6 decimals). Editable by owner. E.g. $0.01 = 10_000.
    uint256 public gasCostPerExecutionUsdc6;

    /// @notice User balance in USDC (6 decimals)
    mapping(address => uint256) public balanceOf;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event ExecutionRecorded(address indexed user, uint256 amount, address indexed relayer);
    event ExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);
    event GasCostUpdated(uint256 previousUsdc6, uint256 newUsdc6);

    error InvalidAddress();
    error InsufficientBalance();
    error OnlyExecutor();

    constructor(address _usdc) Ownable(msg.sender) {
        if (_usdc == address(0)) revert InvalidAddress();
        usdc = IERC20(_usdc);
    }

    function setExecutor(address _executor) external onlyOwner {
        if (_executor == address(0)) revert InvalidAddress();
        address previous = executor;
        executor = _executor;
        emit ExecutorUpdated(previous, _executor);
    }

    /// @notice Set gas cost per execution in USDC (6 decimals). E.g. $0.01 = 10_000, $0.005 = 5_000.
    function setGasCostPerExecution(uint256 amountUsdc6) external onlyOwner {
        uint256 previous = gasCostPerExecutionUsdc6;
        gasCostPerExecutionUsdc6 = amountUsdc6;
        emit GasCostUpdated(previous, amountUsdc6);
    }

    /// @notice User deposits USDC into their gas tank (6 decimals).
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) return;
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        balanceOf[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    /// @notice Deposit USDC into the gas tank on behalf of a user. Caller must have approved this contract. Used by vaults to fund user gas in one tx.
    function depositFor(address user, uint256 amount) external nonReentrant {
        if (amount == 0 || user == address(0)) return;
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        balanceOf[user] += amount;
        emit Deposit(user, amount);
    }

    /// @notice User withdraws USDC from their gas tank.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) return;
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        require(usdc.transfer(msg.sender, amount), "Transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Executor (backend relayer) records gas cost for a user and gets reimbursed in USDC.
    /// @param user The user whose DCA was executed.
    /// @param amountUsdc6 Amount to deduct from user's tank and send to msg.sender (USDC 6 decimals).
    function recordExecution(address user, uint256 amountUsdc6) external nonReentrant {
        if (msg.sender != executor) revert OnlyExecutor();
        if (amountUsdc6 == 0) return;
        if (balanceOf[user] < amountUsdc6) revert InsufficientBalance();
        balanceOf[user] -= amountUsdc6;
        require(usdc.transfer(msg.sender, amountUsdc6), "Transfer failed");
        emit ExecutionRecorded(user, amountUsdc6, msg.sender);
    }
}
