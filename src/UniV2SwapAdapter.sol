// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title UniV2SwapAdapter
 * @notice Swap adapter for chains that have a Uniswap-V2-style DEX but no 0x aggregator
 *         (e.g. BOT Chain / BDEX V2). Implements the same ISwapRouter surface DCAVault
 *         expects, so the vault needs no changes.
 * @dev The vault calls `swap(...)` when the relayer passes empty swapData, and
 *      `executeSwapWithData(...)` when it passes non-empty swapData. Both are supported;
 *      swapData is ignored here because routing is decided on-chain from the DEX factory.
 *
 *      Routing: direct [stable -> tokenOut] when that pair exists, otherwise hops through
 *      the wrapped native token [stable -> WNATIVE -> tokenOut].
 *
 *      Slippage: `minAmountOut` is enforced as passed by the caller. The vault currently
 *      passes 0, so protection must come from the relayer sizing trades against pool depth
 *      (there is no aggregator quote to check against on-chain).
 */
contract UniV2SwapAdapter {
    /// @notice Uniswap-V2-style router (BDEX V2 Router02 on BOT Chain)
    address public immutable ROUTER;
    /// @notice Router's pair factory, cached at construction
    address public immutable FACTORY;
    /// @notice Stablecoin the vault holds and sells (6 decimals; USDT on BOT Chain)
    address public immutable USDC;
    /// @notice Wrapped native token used as the intermediate hop (WBOT on BOT Chain)
    address public immutable WNATIVE;

    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    constructor(address _usdc, address _router) {
        require(_usdc != address(0), "Invalid USDC");
        require(_router != address(0), "Invalid router");
        USDC = _usdc;
        ROUTER = _router;
        FACTORY = IUniswapV2Router02(_router).factory();
        WNATIVE = IUniswapV2Router02(_router).WETH();
    }

    /**
     * @notice ISwapRouter entrypoint: sell `amountIn` of the vault stablecoin for `tokenOut`.
     * @param tokenOut Output token
     * @param amountIn Stablecoin amount (6 decimals)
     * @param minAmountOut Minimum acceptable output
     * @param recipient Address that receives `tokenOut`
     */
    function swap(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        return _swap(tokenOut, amountIn, minAmountOut, recipient);
    }

    /**
     * @notice 0x-adapter-compatible entrypoint. `swapData` is ignored; the route is derived
     *         on-chain so the relayer can send "0x" or any placeholder.
     */
    function executeSwapWithData(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata /* swapData */
    ) external returns (uint256 amountOut) {
        return _swap(tokenOut, amountIn, minAmountOut, recipient);
    }

    /// @notice Route this adapter would take for `tokenOut` (for off-chain quoting via the router).
    function getPath(address tokenOut) external view returns (address[] memory) {
        return _buildPath(tokenOut);
    }

    // ============ Internal ============

    function _swap(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) internal returns (uint256 amountOut) {
        require(tokenOut != address(0), "Invalid tokenOut");
        require(recipient != address(0), "Invalid recipient");
        require(amountIn > 0, "Invalid amount");

        _safeTransferFrom(USDC, msg.sender, address(this), amountIn);
        _safeApprove(USDC, ROUTER, amountIn);

        address[] memory path = _buildPath(tokenOut);

        // Measure the recipient's balance rather than trusting the router's return value:
        // fee-on-transfer tokens deliver less than `amounts[last]` reports.
        uint256 balanceBefore = IERC20Minimal(tokenOut).balanceOf(recipient);
        IUniswapV2Router02(ROUTER).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            recipient,
            block.timestamp
        );
        amountOut = IERC20Minimal(tokenOut).balanceOf(recipient) - balanceBefore;

        require(amountOut > 0, "No output");
        require(amountOut >= minAmountOut, "Insufficient output amount");

        emit SwapExecuted(USDC, tokenOut, amountIn, amountOut, recipient);
    }

    /// @dev Direct pair when it exists, otherwise hop through the wrapped native token.
    function _buildPath(address tokenOut) internal view returns (address[] memory path) {
        require(tokenOut != USDC, "tokenOut == USDC");
        if (IUniswapV2Factory(FACTORY).getPair(USDC, tokenOut) != address(0)) {
            path = new address[](2);
            path[0] = USDC;
            path[1] = tokenOut;
            return path;
        }
        path = new address[](3);
        path[0] = USDC;
        path[1] = WNATIVE;
        path[2] = tokenOut;
    }

    // ============ Non-standard ERC20 safety ============
    // Bridged USDT-style tokens do not return a bool, so the plain interface call reverts.

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    function _safeApprove(address token, address spender, uint256 value) internal {
        // Some tokens (USDT) require the allowance to be zeroed before it can be raised.
        (bool okZero, bytes memory dataZero) = token.call(
            abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, 0)
        );
        require(okZero && (dataZero.length == 0 || abi.decode(dataZero, (bool))), "approve reset failed");
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, value)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}
