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
 * @title MockUSDT
 * @notice USDT-style token whose transfer/approve/transferFrom return NOTHING, the way
 *         the real Tether contract does. Used to prove the checkout works through
 *         SafeERC20 against a non-standard token (blueprint §18.4).
 */
contract MockUSDT {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    // Deliberately no return value.
    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "USDT: allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "USDT: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/**
 * @title MockFeeToken
 * @notice ERC20 that skims a fee on every wallet-to-wallet transfer, so the receiver gets
 *         less than the amount sent. Used to prove the checkout's treasury balance-delta
 *         check rejects fee-on-transfer tokens (blueprint §18.4).
 */
contract MockFeeToken is ERC20 {
    uint256 public immutable feeBps; // 1 = 0.01%
    address public constant FEE_SINK = address(0xFEE);
    bool private _inFee;

    constructor(uint256 feeBps_) ERC20("Fee Token", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!_inFee && from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10000;
            _inFee = true;
            super._update(from, FEE_SINK, fee);
            super._update(from, to, value - fee);
            _inFee = false;
        } else {
            super._update(from, to, value);
        }
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
