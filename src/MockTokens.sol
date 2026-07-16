// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testing on Base Sepolia
 */
contract MockUSDC is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;
    
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    
    constructor() ERC20("USD Coin", "USDC") Ownable(msg.sender) {}
    
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    /**
     * @notice Mint tokens (test only)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }
    
    /**
     * @notice Burn tokens
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }
    
    /**
     * @notice Burn tokens from an account
     */
    function burnFrom(address account, uint256 amount) external {
        uint256 currentAllowance = allowance(account, msg.sender);
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        
        _approve(account, msg.sender, currentAllowance - amount);
        _burn(account, amount);
    }
}

/**
 * @title MockToken
 * @notice Generic mock ERC20 token
 */
contract MockToken is ERC20, Ownable {
    uint8 public immutable dec;
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) Ownable(msg.sender) {
        dec = decimals_;
    }
    
    function decimals() public view override returns (uint8) {
        return dec;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/**
 * @title MockAERO
 * @notice Mock AERO token (Aerodrome)
 */
contract MockAERO is MockToken {
    constructor() MockToken("Aerodrome", "AERO", 18) {}
}

/**
 * @title MockDEGEN
 * @notice Mock DEGEN token
 */
contract MockDEGEN is MockToken {
    constructor() MockToken("Degen", "DEGEN", 18) {}
}

/**
 * @title MockCBETH
 * @notice Mock cbETH token (Coinbase Wrapped Staked ETH)
 */
contract MockCBETH is MockToken {
    constructor() MockToken("Coinbase Wrapped Staked ETH", "cbETH", 18) {}
}
