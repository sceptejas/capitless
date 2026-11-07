// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStrategyPolicy} from "../interfaces/IStrategyPolicy.sol";

/// @title CapitallessHook
/// @notice Uniswap v4 hook that overrides the dynamic LP fee on each swap
///         by reading the current policy from StrategyPolicy.
///
/// Permission bits required: BEFORE_SWAP_FLAG (bit 7 = 0x80)
/// Hook address must have bit 7 of uint160(address) set.
/// No other permission flags are used — this hook ONLY intercepts beforeSwap.
///
/// Fee override mechanics (from LPFeeLibrary):
///   - The pool must be initialised with fee = DYNAMIC_FEE_FLAG (0x800000)
///   - The uint24 returned by beforeSwap must have OVERRIDE_FEE_FLAG (0x400000) set
///   - The fee value (lower 22 bits) must be <= MAX_LP_FEE (1_000_000)
///
/// Fallback on invalid policy (D-4): REVERT. A reverted swap is diagnosable;
/// a silently misconfigured fee is not.
contract CapitallessHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotPoolManager(address caller);
    error NotOwner(address caller);
    error HookStrategyNotConfigured(PoolId poolId);
    error HookStrategyInactive(bytes32 strategyId);
    error HookPolicyExpired(bytes32 strategyId, uint64 validUntil);
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PoolStrategyConfigured(PoolId indexed poolId, bytes32 indexed strategyId);
    event PoolStrategyRemoved(PoolId indexed poolId);

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    IStrategyPolicy public immutable strategyPolicy;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public owner;

    /// @notice Maps a PoolId to its controlling strategy.
    ///         Set by the hook owner during pool setup.
    mapping(PoolId => bytes32) public strategyForPool;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(IPoolManager _poolManager, IStrategyPolicy _strategyPolicy) {
        if (address(_poolManager)   == address(0)) revert ZeroAddress();
        if (address(_strategyPolicy) == address(0)) revert ZeroAddress();
        poolManager    = _poolManager;
        strategyPolicy = _strategyPolicy;
        owner          = msg.sender;

        // Validate that this contract's address has the BEFORE_SWAP_FLAG set.
        // This call will revert if the hook address is wrong — caught during deployment.
        Hooks.validateHookPermissions(IHooks(address(this)), Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 false,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               false,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            false,
            beforeSwap:                      true,   // ← only permission we need
            afterSwap:                       false,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        }));
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // IHooks — only beforeSwap is active; all others are no-ops
    // -------------------------------------------------------------------------

    /// @notice Called by PoolManager before every swap on pools using this hook.
    ///         Reads StrategyPolicy and returns a clamped dynamic fee override.
    ///
    /// @return selector     IHooks.beforeSwap.selector
    /// @return delta        ZERO_DELTA — we do not modify token flows
    /// @return feeOverride  OVERRIDE_FEE_FLAG | clampedFee — tells v4 to use our fee
    function beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        bytes calldata /* hookData */
    ) external override onlyPoolManager returns (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) {
        PoolId poolId = key.toId();

        // D-4: revert if no strategy is configured for this pool
        bytes32 strategyId = strategyForPool[poolId];
        if (strategyId == bytes32(0)) revert HookStrategyNotConfigured(poolId);

        IStrategyPolicy.StrategyConfig memory cfg = strategyPolicy.getStrategy(strategyId);

        // D-4: revert if strategy is not active
        if (!cfg.active) revert HookStrategyInactive(strategyId);

        // D-4: revert if policy has expired
        if (cfg.validUntil != 0 && block.timestamp > cfg.validUntil) {
            revert HookPolicyExpired(strategyId, cfg.validUntil);
        }

        // Read currentDynamicFee and clamp to [minDynamicFee, maxDynamicFee]
        uint24 fee = cfg.currentDynamicFee;
        if (fee < cfg.minDynamicFee) fee = cfg.minDynamicFee;
        if (fee > cfg.maxDynamicFee) fee = cfg.maxDynamicFee;

        // Build the fee override value: set OVERRIDE_FEE_FLAG + the clamped fee value
        feeOverride = LPFeeLibrary.OVERRIDE_FEE_FLAG | fee;

        selector = IHooks.beforeSwap.selector;
        delta    = BeforeSwapDeltaLibrary.ZERO_DELTA;
    }

    // -------------------------------------------------------------------------
    // IHooks — no-op stubs for all other hooks
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    { return IHooks.afterInitialize.selector; }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta)
    { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta)
    { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, int128)
    { return (IHooks.afterSwap.selector, 0); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.afterDonate.selector; }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Bind a strategy to a pool. Only callable by owner.
    function configurePool(PoolId poolId, bytes32 stratId) external onlyOwner {
        strategyForPool[poolId] = stratId;
        if (stratId == bytes32(0)) {
            emit PoolStrategyRemoved(poolId);
        } else {
            emit PoolStrategyConfigured(poolId, stratId);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /// @notice Anyone can claim ownership if current owner is the CREATE2 factory.
    function claimOwnership() external {
        if (owner != address(0x4e59b44847b379578588920cA78FbF26c0B4956C)) revert NotOwner(msg.sender);
        owner = msg.sender;
    }
}
