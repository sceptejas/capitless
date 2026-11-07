// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IRFQExecutor
/// @notice External interface for the CAPITLESS RFQ Executor.
///
/// Capital-light model: Maker holds NO inventory.
///   - Taker pays quoteAmountIn USDC.
///   - WETH comes from Uniswap v4 pool LPs, delivered directly to Taker via take().
///   - Maker earns makerProceeds = quoteAmountIn - actualRouteCost USDC.
interface IRFQExecutor {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice The full RFQ order signed by the Maker off-chain (EIP-712).
    struct RFQOrder {
        bytes32 strategyId;       // Maker's strategy in StrategyPolicy
        address maker;            // Maker address — receives makerProceeds USDC only
        address taker;            // Specific taker, or address(0) for open (D-6)
        address tokenIn;          // USDC — paid by Taker; Maker proceeds in this token
        address tokenOut;         // WETH — received by Taker; comes from LP liquidity
        uint256 quoteAmountIn;    // Exact USDC Taker pays — no variance, no maximum
        uint256 exactAmountOut;   // Exact WETH delivered to Taker
        uint256 minMakerProceeds; // Minimum USDC spread: reverts if quoteAmountIn - actualRouteCost < this
        uint256 expiry;           // Unix timestamp — revert if block.timestamp > expiry
        uint256 nonce;            // Replay protection (D-7: bitmap model)
        uint64  policyVersion;    // Must equal strategy.policyVersion at execution time
        address adapter;          // Must be approved in StrategyPolicy
        bytes32 routeHash;        // keccak256(abi.encode(Route)) — binds exact PoolKeys + legAmounts
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RFQExecuted(
        bytes32 indexed strategyId,
        address indexed maker,
        address indexed taker,
        uint256 quoteAmountIn,
        uint256 exactAmountOut,
        uint256 actualRouteCost,
        uint256 makerProceeds,
        bytes32 routeHash,
        uint24  hookFeeObserved  // fee applied by the hook on the hooked leg (0 if none)
    );

    event NonceInvalidated(address indexed maker, uint256 nonce);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error InvalidSignature();
    error SignerNotAuthorised(bytes32 strategyId, address signer);
    error StrategyNotActive(bytes32 strategyId);
    error OrderExpired(uint256 expiry, uint256 blockTimestamp);
    error InvalidTaker(address expected, address actual);
    error NonceAlreadyUsed(address maker, uint256 nonce);
    error TokenNotApproved(bytes32 strategyId, address token);
    error AdapterNotApproved(bytes32 strategyId, address adapter);
    error RouteHashMismatch(bytes32 expected, bytes32 actual);
    error InsufficientOutput(uint256 actual, uint256 required);
    error InsufficientMakerProceeds(uint256 actual, uint256 minimum);
    error BudgetExceeded(uint256 actualRouteCost, uint256 quoteAmountIn);
    error StalePolicyVersion(uint64 orderVersion, uint64 strategyVersion);
    error ZeroAddress();
    error Paused();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    function executeRFQ(
        RFQOrder calldata order,
        bytes calldata signature,
        bytes calldata routeData
    ) external;

    function invalidateNonce(uint256 nonce) external;
    function isNonceUsed(address maker, uint256 nonce) external view returns (bool);
    function hashOrder(RFQOrder calldata order) external view returns (bytes32);
    function pause() external;
    function unpause() external;
}
