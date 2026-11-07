// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712}        from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA}         from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable}       from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20}        from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}     from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRFQExecutor}  from "./interfaces/IRFQExecutor.sol";
import {IStrategyPolicy} from "./interfaces/IStrategyPolicy.sol";
import {IExecutionAdapter} from "./interfaces/IExecutionAdapter.sol";

/// @title RFQExecutor
/// @notice Capital-light RFQ settlement. Maker holds NO tokenOut inventory.
///
/// TOKEN FLOW (all within one transaction):
///   1. Pull quoteAmountIn USDC from Taker.
///   2. Transfer quoteAmountIn USDC to Adapter.
///   3. Adapter executes split route inside PoolManager.unlock():
///      - WETH taken directly to Taker via take(tokenOut, taker, amount).
///      - USDC settled from adapter balance back to PoolManager.
///      - Unused USDC returned to Executor.
///   4. Compute makerProceeds = quoteAmountIn - actualRouteCost.
///   5. Revert if makerProceeds < minMakerProceeds.
///   6. Transfer makerProceeds USDC to Maker.
///
/// The Executor holds zero persistent token balances. All assertions are explicit.
contract RFQExecutor is IRFQExecutor, EIP712, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // EIP-712 type hash
    // Field order matches RFQOrder struct exactly — any change here breaks signatures.
    // Uses block.chainid (not hardcoded) so the domain is chain-specific.
    // -------------------------------------------------------------------------

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "RFQOrder("
        "bytes32 strategyId,"
        "address maker,"
        "address taker,"
        "address tokenIn,"
        "address tokenOut,"
        "uint256 quoteAmountIn,"
        "uint256 exactAmountOut,"
        "uint256 minMakerProceeds,"
        "uint256 expiry,"
        "uint256 nonce,"
        "uint64 policyVersion,"
        "address adapter,"
        "bytes32 routeHash"
        ")"
    );

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IStrategyPolicy public immutable strategyPolicy;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @dev Nonce bitmap: word-bit model (D-7). nonceBitmaps[maker][wordPos] is 256 bits.
    mapping(address maker => mapping(uint256 wordPos => uint256 bitmap)) public nonceBitmaps;

    bool public paused;

    // -------------------------------------------------------------------------
    // Constructor
    // EIP712 is constructed with "CAPITLESS" and "1" but uses block.chainid at runtime.
    // -------------------------------------------------------------------------

    constructor(address _strategyPolicy, address _owner)
        EIP712("CAPITLESS", "1")
        Ownable(_owner)
    {
        require(_strategyPolicy != address(0), "zero policy");
        strategyPolicy = IStrategyPolicy(_strategyPolicy);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // -------------------------------------------------------------------------
    // executeRFQ
    // -------------------------------------------------------------------------

    function executeRFQ(
        RFQOrder calldata order,
        bytes calldata signature,
        bytes calldata routeData
    ) external nonReentrant whenNotPaused {

        // 1. EIP-712 signature — domain uses block.chainid (not hardcoded)
        bytes32 digest = _hashTypedDataV4(_hashOrder(order));
        address signer = digest.recover(signature);
        if (signer == address(0)) revert InvalidSignature();

        // 2. Signer authorised for strategy
        if (!strategyPolicy.isSignerAuthorised(order.strategyId, signer)) {
            revert SignerNotAuthorised(order.strategyId, signer);
        }

        // 3. Strategy active
        IStrategyPolicy.StrategyConfig memory cfg = strategyPolicy.getStrategy(order.strategyId);
        if (!cfg.active) revert StrategyNotActive(order.strategyId);

        // 4. Expiry
        if (block.timestamp > order.expiry) {
            revert OrderExpired(order.expiry, block.timestamp);
        }

        // 5. Taker (address(0) = open order, D-6)
        if (order.taker != address(0) && order.taker != msg.sender) {
            revert InvalidTaker(order.taker, msg.sender);
        }

        // 6. Nonce
        _useNonce(order.maker, order.nonce);

        // 7. Token pair approved
        if (!strategyPolicy.isTokenApproved(order.strategyId, order.tokenIn)) {
            revert TokenNotApproved(order.strategyId, order.tokenIn);
        }
        if (!strategyPolicy.isTokenApproved(order.strategyId, order.tokenOut)) {
            revert TokenNotApproved(order.strategyId, order.tokenOut);
        }

        // 8. Adapter approved
        if (!strategyPolicy.isAdapterApproved(order.strategyId, order.adapter)) {
            revert AdapterNotApproved(order.strategyId, order.adapter);
        }

        // 9. Route hash matches what Maker signed
        bytes32 computedRouteHash = keccak256(routeData);
        if (computedRouteHash != order.routeHash) {
            revert RouteHashMismatch(order.routeHash, computedRouteHash);
        }

        // 10. Policy version must match strategy's current version exactly
        if (order.policyVersion != cfg.policyVersion) {
            revert StalePolicyVersion(order.policyVersion, cfg.policyVersion);
        }

        // 11. Settlement
        _settle(order, routeData);
    }

    // -------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------

    function _settle(RFQOrder calldata order, bytes calldata routeData) internal {
        IERC20 tokenIn = IERC20(order.tokenIn);

        // Snapshot executor tokenIn balance for invariant check
        uint256 executorInBefore = tokenIn.balanceOf(address(this));

        // Step 1: Pull quoteAmountIn USDC from Taker
        tokenIn.safeTransferFrom(msg.sender, address(this), order.quoteAmountIn);

        // Step 2: Transfer full USDC budget to Adapter
        tokenIn.safeTransfer(order.adapter, order.quoteAmountIn);

        // Steps 3a–3c: Adapter executes split route inside unlock():
        //   - WETH taken directly to Taker via take(tokenOut, taker, legAmountOut)
        //   - USDC settled from adapter balance to PoolManager
        //   - Unused USDC returned to this Executor
        IExecutionAdapter.ExecutionResult memory result = IExecutionAdapter(order.adapter).execute(
            IExecutionAdapter.ExecutionRequest({
                strategyId:     order.strategyId,
                tokenIn:        order.tokenIn,
                tokenOut:       order.tokenOut,
                amountInMax:    order.quoteAmountIn,
                exactAmountOut: order.exactAmountOut,
                recipient:      msg.sender,          // Taker receives WETH directly
                routeHash:      order.routeHash,
                routeData:      routeData
            })
        );

        // Verify adapter delivered correct output
        if (result.amountOut < order.exactAmountOut) {
            revert InsufficientOutput(result.amountOut, order.exactAmountOut);
        }

        // Verify actual cost did not exceed budget
        if (result.actualRouteCost > order.quoteAmountIn) {
            revert BudgetExceeded(result.actualRouteCost, order.quoteAmountIn);
        }

        // Step 4: Compute and validate Maker proceeds
        uint256 makerProceeds = order.quoteAmountIn - result.actualRouteCost;
        if (makerProceeds < order.minMakerProceeds) {
            revert InsufficientMakerProceeds(makerProceeds, order.minMakerProceeds);
        }

        // Step 5: Pay Maker (adapter returned surplus USDC to executor in step 2)
        if (makerProceeds > 0) {
            tokenIn.safeTransfer(order.maker, makerProceeds);
        }

        // Invariant: executor tokenIn balance must be unchanged net of this trade
        uint256 executorInAfter = tokenIn.balanceOf(address(this));
        assert(executorInAfter == executorInBefore);

        // Invariant: executor holds zero tokenOut (Maker never touches tokenOut)
        assert(IERC20(order.tokenOut).balanceOf(address(this)) == 0);

        emit RFQExecuted(
            order.strategyId,
            order.maker,
            msg.sender,
            order.quoteAmountIn,
            order.exactAmountOut,
            result.actualRouteCost,
            makerProceeds,
            order.routeHash,
            0 // hookFeeObserved: populated in integration tests from hook event; 0 in basic flow
        );
    }

    // -------------------------------------------------------------------------
    // Nonce management (D-7 bitmap)
    // -------------------------------------------------------------------------

    function _useNonce(address maker, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bit     = 1 << (nonce & 0xff);
        uint256 flipped = nonceBitmaps[maker][wordPos] ^= bit;
        if (flipped & bit == 0) revert NonceAlreadyUsed(maker, nonce);
    }

    function invalidateNonce(uint256 nonce) external {
        uint256 wordPos = nonce >> 8;
        uint256 bit     = 1 << (nonce & 0xff);
        nonceBitmaps[msg.sender][wordPos] |= bit;
        emit NonceInvalidated(msg.sender, nonce);
    }

    function isNonceUsed(address maker, uint256 nonce) external view returns (bool) {
        uint256 wordPos = nonce >> 8;
        uint256 bit     = 1 << (nonce & 0xff);
        return nonceBitmaps[maker][wordPos] & bit != 0;
    }

    // -------------------------------------------------------------------------
    // EIP-712
    // -------------------------------------------------------------------------

    function _hashOrder(RFQOrder calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.strategyId,
            order.maker,
            order.taker,
            order.tokenIn,
            order.tokenOut,
            order.quoteAmountIn,
            order.exactAmountOut,
            order.minMakerProceeds,
            order.expiry,
            order.nonce,
            order.policyVersion,
            order.adapter,
            order.routeHash
        ));
    }

    /// @notice Public helper for off-chain signing and test verification.
    function hashOrder(RFQOrder calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_hashOrder(order));
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function pause() external onlyOwner { paused = true; }
    function unpause() external onlyOwner { paused = false; }
}
