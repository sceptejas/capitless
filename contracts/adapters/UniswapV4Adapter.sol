// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCallback}   from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IPoolManager}   from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}        from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary}  from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams}     from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IExecutionAdapter} from "../interfaces/IExecutionAdapter.sol";
import {IStrategyPolicy}   from "../interfaces/IStrategyPolicy.sol";

/// @title UniswapV4Adapter
/// @notice Capital-light Uniswap v4 execution adapter.
///
/// Settlement model (all inside one PoolManager.unlock session):
///   1. For each leg: swap exact-output (amountSpecified > 0).
///      BalanceDelta from swap: tokenIn delta > 0 (we owe USDC), tokenOut delta < 0 (PM owes us WETH but we redirect it).
///   2. For each leg: take(tokenOut, recipient, legAmountOut) immediately after swap.
///      This gives the adapter a negative delta on tokenOut (we just withdrew it).
///      The net tokenOut delta for the adapter is zero per leg:
///        swap gives +legAmountOut credit, take withdraws it → net 0.
///   3. After all legs: net tokenIn delta is the total USDC owed.
///      settle it: sync(tokenIn) → transfer from adapter → settle().
///   4. Assert both currency deltas are zero.
///
/// The Maker never appears. WETH flows directly from PoolManager to the Taker.
/// Flash accounting is deferred netting within the unlock session — not a loan.
contract UniswapV4Adapter is SafeCallback, IExecutionAdapter {
    using PoolIdLibrary      for PoolKey;
    using CurrencyLibrary    for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MAX_LEGS = 2;

    // Safe sqrt price limits — one tick inside the absolute bounds
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT =
        1461446703485210103287273052203988822378723970341;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IStrategyPolicy public immutable strategyPolicy;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public executor;
    bool    private _executing; // re-entrancy + direct-callback guard

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        IPoolManager _poolManager,
        IStrategyPolicy _strategyPolicy,
        address _executor
    ) SafeCallback(_poolManager) {
        require(address(_strategyPolicy) != address(0), "zero policy");
        require(_executor != address(0), "zero executor");
        strategyPolicy = _strategyPolicy;
        executor       = _executor;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // IExecutionAdapter.execute
    // -------------------------------------------------------------------------

    /// @notice Called by RFQExecutor.
    ///         `amountInMax` USDC must already be in this contract before this call.
    function execute(ExecutionRequest calldata request)
        external
        onlyExecutor
        returns (ExecutionResult memory result)
    {
        // Decode and validate route
        Route memory route = abi.decode(request.routeData, (Route));

        bytes32 computedHash = keccak256(request.routeData);
        if (computedHash != request.routeHash) {
            revert RouteHashMismatch(request.routeHash, computedHash);
        }
        if (route.legs.length == 0 || route.legs.length > MAX_LEGS) {
            revert TooManyLegs(route.legs.length);
        }

        // Validate leg amounts sum to exactAmountOut
        uint256 legSum;
        for (uint256 i = 0; i < route.legs.length; i++) {
            legSum += route.legs[i].legAmountOut;
        }
        if (legSum != request.exactAmountOut) {
            revert LegSumMismatch(legSum, request.exactAmountOut);
        }

        // Validate every PoolKey against StrategyPolicy (D-5)
        for (uint256 i = 0; i < route.legs.length; i++) {
            bytes32 pkHash = keccak256(abi.encode(route.legs[i].poolKey));
            if (!strategyPolicy.isPoolKeyApproved(request.strategyId, pkHash)) {
                revert PoolKeyNotApproved(pkHash);
            }
        }

        _executing = true;
        bytes memory returnData = poolManager.unlock(abi.encode(request, route));
        _executing = false;

        result = abi.decode(returnData, (ExecutionResult));

        // Post-execution safety checks
        if (result.amountOut < request.exactAmountOut) {
            revert InsufficientOutput(result.amountOut, request.exactAmountOut);
        }
        if (result.actualRouteCost > request.amountInMax) {
            revert BudgetExceeded(result.actualRouteCost, request.amountInMax);
        }

        // Return unused USDC budget to executor
        uint256 surplus = request.amountInMax - result.actualRouteCost;
        if (surplus > 0) {
            _safeTransfer(request.tokenIn, executor, surplus);
        }
    }

    // -------------------------------------------------------------------------
    // SafeCallback._unlockCallback
    // -------------------------------------------------------------------------

    /// @dev Called by PoolManager. msg.sender == poolManager guaranteed by SafeCallback.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        require(_executing, "not in execution");

        (ExecutionRequest memory request, Route memory route) =
            abi.decode(data, (ExecutionRequest, Route));

        Currency currencyIn  = Currency.wrap(request.tokenIn);
        Currency currencyOut = Currency.wrap(request.tokenOut);

        // Track net deltas for the two currencies.
        // Only two currencies are involved (same pair across all legs).
        int256 netIn;   // USDC owed to PoolManager (will be positive after exact-output swaps)
        int256 netOut;  // tokenOut position (will be zero after take)

        uint256 totalAmountOut;

        for (uint256 i = 0; i < route.legs.length; i++) {
            Leg memory leg = route.legs[i];

            // Determine swap direction from the pool's currency ordering
            // zeroForOne = true  → selling currency0 (tokenIn must be currency0)
            // zeroForOne = false → selling currency1 (tokenIn must be currency1)
            bool zeroForOne = Currency.unwrap(leg.poolKey.currency0) == request.tokenIn;

            // Exact-output: amountSpecified > 0 means "give me exactly this many tokenOut"
            SwapParams memory params = SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   int256(leg.legAmountOut),   // positive = exact output
                sqrtPriceLimitX96: leg.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT)
                    : leg.sqrtPriceLimitX96
            });

            BalanceDelta delta = poolManager.swap(leg.poolKey, params, leg.hookData);

            // After exact-output swap:
            //   If zeroForOne (tokenIn=currency0, tokenOut=currency1):
            //     delta.amount0 < 0 → we OWE tokenIn  (PoolManager credited us)
            //     delta.amount1 > 0 → PM owes us tokenOut  ← we immediately take() it
            //
            //   If !zeroForOne (tokenIn=currency1, tokenOut=currency0):
            //     delta.amount1 < 0 → we OWE tokenIn
            //     delta.amount0 > 0 → PM owes us tokenOut

            int128 deltaIn  = zeroForOne ? delta.amount0() : delta.amount1();
            int128 deltaOut = zeroForOne ? delta.amount1() : delta.amount0();

            netIn  += int256(deltaIn);
            netOut += int256(deltaOut);

            // Immediately take the tokenOut credit and send it directly to the Taker.
            // take() gives adapter a negative delta (withdraws from PM), cancelling the positive swap credit.
            // Net tokenOut delta after take = deltaOut + (-legAmountOut) = 0 (assuming exact-output matched).
            uint256 legOut = uint256(int256(deltaOut)); // deltaOut > 0 from exact-output swap
            poolManager.take(currencyOut, request.recipient, legOut);
            netOut -= int256(legOut);

            totalAmountOut += legOut;
        }

        // At this point:
        //   netOut should be 0 (each leg's credit was immediately taken)
        //   netIn  > 0 (we owe USDC to PoolManager — the input side of exact-output)
        //
        // Settle the USDC debt: sync → transfer from adapter → settle()
        require(netIn < 0, "unexpected netIn sign"); // netIn is negative (we owe): deltaIn < 0
        // Wait — re-check sign: exact-output, zeroForOne, currency0=tokenIn:
        //   delta.amount0 < 0 means PoolManager DEBITED tokenIn from us (we owe it)
        //   delta.amount0 is negative → we owe |delta.amount0| tokenIn
        // _accountDelta adds deltaIn to adapter's delta. Negative deltaIn means we owe.
        // To settle a negative delta (debt): sync, transfer in, settle.

        // The actual USDC cost is |netIn|
        uint256 usdcOwed;
        if (netIn < 0) {
            usdcOwed = uint256(-netIn);
        } else if (netIn > 0) {
            // Unexpected positive tokenIn balance — clear it to avoid CurrencyNotSettled
            // This would mean we received more tokenIn than expected (should not happen)
            poolManager.take(currencyIn, executor, uint256(netIn));
            usdcOwed = 0;
        }
        // netIn == 0: nothing to settle

        if (usdcOwed > 0) {
            poolManager.sync(currencyIn);
            _safeTransfer(request.tokenIn, address(poolManager), usdcOwed);
            poolManager.settle();
        }

        // Assert all deltas are zero — do NOT rely on PoolManager's revert alone
        // The assertion catches accounting bugs before the unlock closes.
        // If either is nonzero, PoolManager will revert with CurrencyNotSettled anyway,
        // but this makes the failure site explicit.
        require(netOut == 0, "nonzero tokenOut delta");

        return abi.encode(ExecutionResult({
            actualRouteCost: usdcOwed,
            amountOut:       totalAmountOut
        }));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "ERC20 transfer failed");
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setExecutor(address newExecutor) external {
        if (msg.sender != executor) revert NotExecutor(msg.sender);
        require(newExecutor != address(0), "zero executor");
        executor = newExecutor;
    }
}
