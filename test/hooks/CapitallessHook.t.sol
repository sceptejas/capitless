// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CapitallessHook} from "../../contracts/hooks/CapitallessHook.sol";
import {IStrategyPolicy} from "../../contracts/interfaces/IStrategyPolicy.sol";
import {StrategyPolicy} from "../../contracts/StrategyPolicy.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract CapitallessHookTest is Test {
    using PoolIdLibrary for PoolKey;

    CapitallessHook internal hook;
    StrategyPolicy  internal policy;

    address internal admin       = makeAddr("admin");
    address internal hookOwner   = makeAddr("hookOwner");
    address internal stranger    = makeAddr("stranger");
    address internal mockPMAddr;

    uint256 internal makerKey = 0xBEEF;
    address internal maker    = vm.addr(makerKey);

    bytes32 internal constant STRATEGY_A = keccak256("STRATEGY_A");

    uint24 internal constant MIN_FEE  = 500;
    uint24 internal constant MAX_FEE  = 10_000;
    uint24 internal constant INIT_FEE = 3_000;

    PoolKey  internal poolKey;
    PoolId   internal poolId;

    // ------------------------------------------------------------------
    // Hook address with BEFORE_SWAP_FLAG (bit 7) set, no other flags
    // BEFORE_SWAP_FLAG = 1 << 7 = 0x80
    // ALL_HOOK_MASK    = 0x3FFF
    // Required: uint160(addr) & 0x3FFF == 0x0080
    // Use: 0x0000000000000000000000000000000000000080
    // ------------------------------------------------------------------
    address internal constant HOOK_ADDR =
        address(uint160(Hooks.BEFORE_SWAP_FLAG));

    function setUp() public {
        // Mock PoolManager — hook only checks msg.sender matches poolManager immutable
        mockPMAddr = makeAddr("poolManager");

        // Policy
        policy = new StrategyPolicy(admin);

        // Deploy hook at the address with correct permission bits
        // deployCodeTo runs the constructor at HOOK_ADDR
        deployCodeTo(
            "contracts/hooks/CapitallessHook.sol:CapitallessHook",
            abi.encode(IPoolManager(mockPMAddr), IStrategyPolicy(address(policy))),
            HOOK_ADDR
        );
        hook = CapitallessHook(HOOK_ADDR);

        // Transfer hook ownership to hookOwner
        // Note: deployCodeTo sets msg.sender to this test contract during constructor
        hook.transferOwnership(hookOwner);

        // Build a demo PoolKey with dynamic fee flag
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x036CbD53842c5426634e7929541eC2318f3dCF7e)),
            currency1: Currency.wrap(address(0x4200000000000000000000000000000000000006)),
            fee:       LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:     IHooks(HOOK_ADDR)
        });
        poolId = poolKey.toId();

        // Create and configure strategy
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 200);

        vm.startPrank(maker);
        policy.setStrategyActive(STRATEGY_A, true);
        vm.stopPrank();

        // Grant CRE role to this test contract so we can simulate CRE updates
        bytes32 creRole = policy.CRE_CONSUMER_ROLE();
        vm.prank(admin);
        policy.grantRole(creRole, address(this));

        // Set initial fee via CRE update
        policy.applyCREPolicyUpdate(
            STRATEGY_A,
            INIT_FEE,
            1,
            uint64(block.timestamp + 7 days)
        );

        // Configure pool → strategy mapping in hook
        vm.prank(hookOwner);
        hook.configurePool(poolId, STRATEGY_A);
    }

    // -------------------------------------------------------------------------
    // 1. Permission bits
    // -------------------------------------------------------------------------

    function test_hookAddress_hasCorrectPermissionBits() public view {
        uint160 addr = uint160(address(hook));
        // BEFORE_SWAP_FLAG must be set
        assertEq(addr & Hooks.BEFORE_SWAP_FLAG, Hooks.BEFORE_SWAP_FLAG, "BEFORE_SWAP_FLAG set");
        // No other permission flags set
        assertEq(addr & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_SWAP_FLAG, "only BEFORE_SWAP_FLAG");
    }

    function test_hookAddress_validateHookPermissions_doesNotRevert() public view {
        // This is implicitly checked in the constructor via validateHookPermissions.
        // Re-verify here explicitly.
        Hooks.validateHookPermissions(IHooks(address(hook)), Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeAddLiquidity: false, afterAddLiquidity: false,
            beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
            beforeSwap: true, afterSwap: false,
            beforeDonate: false, afterDonate: false,
            beforeSwapReturnDelta: false, afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false, afterRemoveLiquidityReturnDelta: false
        }));
    }

    // -------------------------------------------------------------------------
    // 2. beforeSwap — happy path
    // -------------------------------------------------------------------------

    function test_beforeSwap_returnsCorrectSelector() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        vm.prank(mockPMAddr);
        (bytes4 sel,,) = hook.beforeSwap(address(this), poolKey, params, "");

        assertEq(sel, IHooks.beforeSwap.selector, "selector matches");
    }

    function test_beforeSwap_returnsZeroDelta() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(mockPMAddr);
        (, BeforeSwapDelta bsd,) = hook.beforeSwap(address(this), poolKey, params, "");

        assertEq(BeforeSwapDelta.unwrap(bsd), 0, "zero delta");
    }

    function test_beforeSwap_feeOverrideHasOverrideFlag() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(mockPMAddr);
        (,, uint24 fee) = hook.beforeSwap(address(this), poolKey, params, "");

        // OVERRIDE_FEE_FLAG must be set
        assertEq(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG, LPFeeLibrary.OVERRIDE_FEE_FLAG, "override flag set");
    }

    function test_beforeSwap_feeValueMatchesCurrentPolicy() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(mockPMAddr);
        (,, uint24 feeOverride) = hook.beforeSwap(address(this), poolKey, params, "");

        uint24 actualFee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(actualFee, INIT_FEE, "fee matches currentDynamicFee");
    }

    // -------------------------------------------------------------------------
    // 3. CRE update changes the fee applied on the next swap
    // -------------------------------------------------------------------------

    function test_beforeSwap_feeBefore_and_after_CREUpdate() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        // Before update: fee = INIT_FEE (3000)
        vm.prank(mockPMAddr);
        (,, uint24 feeOverride1) = hook.beforeSwap(address(this), poolKey, params, "");
        uint24 fee1 = feeOverride1 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(fee1, INIT_FEE, "fee before CRE update");

        // Simulate CRE policy update (we hold CRE_CONSUMER_ROLE in setUp)
        uint24 newFee = 7_500;
        policy.applyCREPolicyUpdate(
            STRATEGY_A,
            newFee,
            2,
            uint64(block.timestamp + 7 days)
        );

        // After update: fee = newFee (7500)
        vm.prank(mockPMAddr);
        (,, uint24 feeOverride2) = hook.beforeSwap(address(this), poolKey, params, "");
        uint24 fee2 = feeOverride2 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(fee2, newFee, "fee after CRE update");
    }

    // -------------------------------------------------------------------------
    // 4. Fee clamping
    // -------------------------------------------------------------------------

    function test_beforeSwap_feeBelowMinIsClamped() public {
        // Push fee to below min via a direct storage trick — use CRE to set min, then tighten
        // We set currentDynamicFee = MIN_FEE, then tighten min upward
        // setFeeBounds clamps currentDynamicFee automatically
        vm.prank(maker);
        policy.setFeeBounds(STRATEGY_A, 5_000, MAX_FEE); // min bumped to 5000

        // currentDynamicFee (3000) is now below new min — setFeeBounds auto-clamped it to 5000
        // But let's use CRE to set fee to exactly MIN_FEE-1 ... we can't go below min via CRE
        // Instead verify clamping via direct scenario:
        // Reset bounds so min=500, max=10000, then CRE sets fee=500 (min), then tighten min=1000
        vm.prank(maker);
        policy.setFeeBounds(STRATEGY_A, MIN_FEE, MAX_FEE);
        policy.applyCREPolicyUpdate(STRATEGY_A, MIN_FEE, 3, uint64(block.timestamp + 7 days));

        // Now tighten min to 2000 — setFeeBounds clamps currentDynamicFee to 2000
        vm.prank(maker);
        policy.setFeeBounds(STRATEGY_A, 2_000, MAX_FEE);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(mockPMAddr);
        (,, uint24 feeOverride) = hook.beforeSwap(address(this), poolKey, params, "");
        uint24 fee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // Hook clamps on read: fee >= minDynamicFee (2000)
        assertGe(fee, 2_000, "fee clamped to min");
    }

    function test_beforeSwap_feeAboveMaxIsClamped() public {
        // Set fee to max via CRE
        policy.applyCREPolicyUpdate(STRATEGY_A, MAX_FEE, 4, uint64(block.timestamp + 7 days));
        // Now shrink max to 5000
        vm.prank(maker);
        policy.setFeeBounds(STRATEGY_A, MIN_FEE, 5_000); // auto-clamps currentDynamicFee to 5000

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(mockPMAddr);
        (,, uint24 feeOverride) = hook.beforeSwap(address(this), poolKey, params, "");
        uint24 fee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertLe(fee, 5_000, "fee clamped to max");
    }

    // -------------------------------------------------------------------------
    // 5. D-4 revert cases
    // -------------------------------------------------------------------------

    function test_beforeSwap_noStrategyConfiguredReverts() public {
        // Use a different poolKey that has no strategy mapped
        PoolKey memory unknownKey = PoolKey({
            currency0: Currency.wrap(address(0xAAAA)),
            currency1: Currency.wrap(address(0xBBBB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        PoolId unknownId = unknownKey.toId();

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(mockPMAddr);
        vm.expectRevert(
            abi.encodeWithSelector(CapitallessHook.HookStrategyNotConfigured.selector, unknownId)
        );
        hook.beforeSwap(address(this), unknownKey, params, "");
    }

    function test_beforeSwap_inactiveStrategyReverts() public {
        vm.prank(maker);
        policy.setStrategyActive(STRATEGY_A, false);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(mockPMAddr);
        vm.expectRevert(
            abi.encodeWithSelector(CapitallessHook.HookStrategyInactive.selector, STRATEGY_A)
        );
        hook.beforeSwap(address(this), poolKey, params, "");
    }

    function test_beforeSwap_expiredPolicyReverts() public {
        // Set validUntil to a past timestamp
        policy.applyCREPolicyUpdate(STRATEGY_A, 3_000, 5, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 2); // advance past validUntil

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(mockPMAddr);
        vm.expectRevert(); // HookPolicyExpired
        hook.beforeSwap(address(this), poolKey, params, "");
    }

    function test_beforeSwap_onlyPoolManagerCanCall() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(CapitallessHook.NotPoolManager.selector, stranger)
        );
        hook.beforeSwap(address(this), poolKey, params, "");
    }

    // -------------------------------------------------------------------------
    // 6. configurePool access control
    // -------------------------------------------------------------------------

    function test_configurePool_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(CapitallessHook.NotOwner.selector, stranger)
        );
        hook.configurePool(poolId, STRATEGY_A);
    }

    function test_configurePool_ownerSucceeds() public {
        PoolId newPoolId = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        }).toId();

        vm.prank(hookOwner);
        hook.configurePool(newPoolId, STRATEGY_A);
        assertEq(hook.strategyForPool(newPoolId), STRATEGY_A);
    }

    function test_configurePool_removesStrategy() public {
        vm.prank(hookOwner);
        hook.configurePool(poolId, bytes32(0)); // remove
        assertEq(hook.strategyForPool(poolId), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // 7. Hookdata cannot override fee (caller-supplied data ignored)
    // -------------------------------------------------------------------------

    function test_beforeSwap_hookDataDoesNotChangeFee() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        // Pass arbitrary hookData claiming a different fee
        bytes memory maliciousData = abi.encode(uint24(1)); // try to set fee = 1

        vm.prank(mockPMAddr);
        (,, uint24 feeOverride) = hook.beforeSwap(address(this), poolKey, params, maliciousData);
        uint24 actualFee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // Fee must come from policy, not hookData
        assertEq(actualFee, INIT_FEE, "hookData cannot override policy fee");
    }
}
