// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IExecutionAdapter
/// @notice Interface between RFQExecutor and Uniswap v4 venue adapter.
///
/// The new capital-light model (no Maker inventory):
///   - Executor holds USDC (transferred from Taker before calling execute).
///   - Adapter executes EXACT-OUTPUT swaps across one or more legs of the same pair.
///   - WETH is taken directly from PoolManager to `recipient` (the Taker) inside the callback.
///   - Adapter settles the net USDC cost from its own balance back to PoolManager.
///   - actualRouteCost = USDC paid to pools.
///   - Executor pays Maker: makerProceeds = quoteAmountIn - actualRouteCost.
///   - Maker never holds WETH, never approves WETH, never appears in the token flow.
interface IExecutionAdapter {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice A single swap leg: one PoolKey, one exact-output amount.
    ///         The route is a SPLIT — all legs swap the same pair (tokenIn → tokenOut),
    ///         each through a different pool. legAmountOut values must sum to exactAmountOut.
    struct Leg {
        PoolKey poolKey;           // Pool to route through — must be in StrategyPolicy.approvedPoolKeys
        uint256 legAmountOut;      // Exact tokenOut to acquire from this pool (positive = exact-output)
        uint160 sqrtPriceLimitX96; // Price limit for this leg (0 = use safe default)
        bytes   hookData;          // Hook data (passed through, not blindly trusted)
    }

    struct Route {
        Leg[] legs; // MVP: max 2 legs; all legs must use the same tokenIn/tokenOut pair
    }

    struct ExecutionRequest {
        bytes32 strategyId;
        address tokenIn;         // USDC — Executor transferred this to the adapter before execute()
        address tokenOut;        // WETH — delivered directly to recipient via take()
        uint256 amountInMax;     // Total USDC budget transferred to adapter (= quoteAmountIn)
        uint256 exactAmountOut;  // Total WETH to deliver to recipient (sum of all legAmountOut)
        address recipient;       // TAKER — where WETH is delivered via take(); never maker or executor
        bytes32 routeHash;       // keccak256(abi.encode(route)) — verified against order.routeHash
        bytes   routeData;       // abi.encode(Route)
    }

    struct ExecutionResult {
        uint256 actualRouteCost; // Total USDC paid to pools (net USDC delta settled)
        uint256 amountOut;       // Total WETH delivered to recipient (must equal exactAmountOut)
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotExecutor(address caller);
    error RouteHashMismatch(bytes32 expected, bytes32 actual);
    error TooManyLegs(uint256 legs);
    error LegSumMismatch(uint256 legSum, uint256 exactAmountOut);
    error PoolKeyNotApproved(bytes32 poolKeyHash);
    error InsufficientOutput(uint256 actual, uint256 required);
    error BudgetExceeded(uint256 actualRouteCost, uint256 budget);

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Execute the split route.
    ///         Caller (RFQExecutor) must have already transferred `amountInMax` of `tokenIn`
    ///         to this adapter before calling.
    ///         WETH is delivered to `recipient` inside the unlock callback via take().
    ///         Unused USDC budget (amountInMax - actualRouteCost) is returned to executor.
    function execute(ExecutionRequest calldata request) external returns (ExecutionResult memory result);
}
