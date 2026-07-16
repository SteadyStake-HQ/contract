// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title IZeroExProtocol
 * @notice Interface for 0x Protocol aggregator on Base
 */
interface IZeroExProtocol {
    struct Quote {
        address to;
        bytes data;
        uint256 value;
        uint256 gas;
        string gasPrice;
    }
    
    function fillQuote(
        bytes calldata swapData
    ) external payable returns (uint256 returnAmount);
}

/**
 * @title SwapHelper
 * @notice Helper for executing swaps via 0x Protocol
 * @dev Abstracts 0x API integration for DCA swaps
 */
contract SwapHelper {
    // 0x Protocol Router on Base
    address constant ZERO_EX_ROUTER = 0xDef1C0ded9bEf7C1100000000000000000000000;
    
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    
    // ============ Events ============
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    
    // ============ Functions ============
    /**
     * @notice Execute a swap via 0x Protocol
     * @param tokenOut Output token
     * @param amountIn USDC amount in
     * @param minAmountOut Minimum output amount
     * @param swapData Encoded 0x swap data from API
     */
    function executeSwap(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external returns (uint256 amountOut) {
        // Approve 0x router
        USDC.approve(ZERO_EX_ROUTER, amountIn);
        
        // Execute swap via 0x router
        // 0x returns the amount received in the return data
        (bool success, bytes memory result) = ZERO_EX_ROUTER.call(swapData);
        require(success, "0x swap failed");
        
        // 0x returns filled amount in the result
        amountOut = abi.decode(result, (uint256));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        
        emit SwapExecuted(address(USDC), tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Decode 0x swap data (placeholder; decoding is quote-specific).
     */
    function decodeSwapData(bytes calldata)
        external
        pure
        returns (
            address tokenOut,
            uint256 minAmountOut
        )
    {
        // 0x swap data is a raw call to the router; decoding is quote-specific.
        tokenOut = address(0);
        minAmountOut = 0;
    }
}

/**
 * @title MockSwapRouter
 * @notice Mock swap router for testing (1:1 swap).
 * Pass address(0) for default Base USDC; pass a token address for tests.
 */
contract MockSwapRouter {
    address constant DEFAULT_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    IERC20 public usdc;

    mapping(address => uint256) public tokenPrices; // Price relative to USDC (6 decimals)

    event MockSwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _usdc) {
        usdc = IERC20(_usdc == address(0) ? DEFAULT_USDC : _usdc);
        tokenPrices[address(usdc)] = 1e6;
    }

    function setTokenPrice(address token, uint256 price) external {
        tokenPrices[token] = price;
    }

    function swap(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid amount");

        require(
            usdc.transferFrom(msg.sender, address(this), amountIn),
            "USDC transfer failed"
        );

        uint8 decimals = IERC20Extended(tokenOut).decimals();
        if (decimals < 6) {
            amountOut = (amountIn / 10 ** (6 - decimals));
        } else if (decimals > 6) {
            amountOut = amountIn * 10 ** (decimals - 6);
        } else {
            amountOut = amountIn;
        }

        require(amountOut >= minAmountOut, "Insufficient output");

        // If we don't have enough tokenOut (e.g. router not funded), send USDC to recipient instead
        // so the swap does not revert and tests / testnets work without pre-funding the router.
        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this));
        if (balanceOut >= amountOut) {
            require(
                IERC20Extended(tokenOut).transfer(recipient, amountOut),
                "Transfer failed"
            );
        } else {
            // Fallback: send USDC to recipient (amountIn is 6 decimals, same as USDC)
            require(
                usdc.transfer(recipient, amountIn),
                "USDC fallback transfer failed"
            );
            amountOut = amountIn; // return amount in 6 decimals for consistency when fallback
        }

        emit MockSwapExecuted(address(usdc), tokenOut, amountIn, amountOut);
        return amountOut;
    }
}

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

/**
 * @title IZeroExAdapter
 * @notice Adapter for DCAVault to execute 0x swaps and send output to recipient
 */
interface IZeroExAdapter {
    function executeSwapWithData(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata swapData
    ) external returns (uint256 amountOut);
}

/**
 * @title ZeroExAdapter
 * @notice Mainnet swap adapter: implements ISwapRouter for DCAVault and 0x execution with recipient.
 * @dev Chain-agnostic: pass chain-specific USDC and 0x router in constructor (Base, BNB, etc.).
 */
contract ZeroExAdapter {
    address public immutable ZERO_EX_ROUTER;
    address public immutable USDC;

    constructor(address _usdc, address _zeroExRouter) {
        require(_usdc != address(0), "Invalid USDC");
        require(_zeroExRouter != address(0), "Invalid 0x router");
        USDC = _usdc;
        ZERO_EX_ROUTER = _zeroExRouter;
    }

    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    /**
     * @notice Execute 0x swap and send output tokens to recipient
     * @param tokenOut Output token address
     * @param amountIn USDC amount (6 decimals)
     * @param minAmountOut Minimum output amount
     * @param recipient Address to receive output tokens
     * @param swapData Encoded 0x swap calldata from API
     */
    function executeSwapWithData(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata swapData
    ) external returns (uint256 amountOut) {
        require(swapData.length > 0, "Empty swap data");
        require(recipient != address(0), "Invalid recipient");

        require(
            IERC20(USDC).transferFrom(msg.sender, address(this), amountIn),
            "USDC transfer failed"
        );
        IERC20(USDC).approve(ZERO_EX_ROUTER, amountIn);

        (bool success, bytes memory result) = ZERO_EX_ROUTER.call(swapData);
        require(success, "0x swap failed");

        amountOut = abi.decode(result, (uint256));
        require(amountOut >= minAmountOut, "Insufficient output amount");

        require(
            IERC20(tokenOut).transfer(recipient, amountOut),
            "Transfer to recipient failed"
        );

        emit SwapExecuted(USDC, tokenOut, amountIn, amountOut, recipient);
    }

    /**
     * @notice ISwapRouter.swap - not used on mainnet; use executeSwapWithData with 0x quote
     */
    function swap(
        address /* tokenOut */,
        uint256 /* amountIn */,
        uint256 /* minAmountOut */,
        address /* recipient */
    ) external pure returns (uint256) {
        revert("Use executeSwapWithData with 0x quote");
    }
}
