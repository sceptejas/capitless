// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console}   from "forge-std/Test.sol";
import {RFQExecutor}     from "../../contracts/RFQExecutor.sol";
import {IRFQExecutor}    from "../../contracts/interfaces/IRFQExecutor.sol";
import {StrategyPolicy}  from "../../contracts/StrategyPolicy.sol";
import {IStrategyPolicy} from "../../contracts/interfaces/IStrategyPolicy.sol";
import {CREPolicyConsumer} from "../../contracts/CREPolicyConsumer.sol";
import {ICREPolicyConsumer} from "../../contracts/interfaces/ICREPolicyConsumer.sol";
import {CapitallessHook} from "../../contracts/hooks/CapitallessHook.sol";
import {IExecutionAdapter} from "../../contracts/interfaces/IExecutionAdapter.sol";
import {IHooks}          from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks}           from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary}    from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey}         from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}        from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams}      from "@uniswap/v4-core/src/types/PoolOperation.sol";

// ---------------------------------------------------------------------------
// Minimal ERC20
// ---------------------------------------------------------------------------
contract Token {
    uint8  public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(uint8 d) { decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a);
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

// ---------------------------------------------------------------------------
// Configurable split adapter — simulates Pool A + Pool B split
// ---------------------------------------------------------------------------
contract SplitMockAdapter is IExecutionAdapter {
    // Route-cost configurations per routeHash
    mapping(bytes32 => uint256) public routeCosts;
    address public executor;

    uint256 public mockAmountOut;

    constructor(address _e) { executor = _e; }

    function configureRoute(bytes32 rh, uint256 cost, uint256 amtOut) external {
        routeCosts[rh]  = cost;
        mockAmountOut   = amtOut;
    }

    function execute(ExecutionRequest calldata req) external returns (ExecutionResult memory) {
        require(msg.sender == executor, "not executor");
        uint256 cost = routeCosts[req.routeHash];
        require(cost > 0, "route not configured");

        // Deliver tokenOut to taker
        Token(req.tokenOut).transfer(req.recipient, mockAmountOut);
        // Return surplus
        uint256 surplus = req.amountInMax - cost;
        if (surplus > 0) Token(req.tokenIn).transfer(executor, surplus);
        return ExecutionResult({ actualRouteCost: cost, amountOut: mockAmountOut });
    }
}

// ---------------------------------------------------------------------------
// Integration test
// ---------------------------------------------------------------------------
contract RFQExecutionFlowTest is Test {
    using PoolIdLibrary for PoolKey;

    RFQExecutor        internal exec;
    StrategyPolicy     internal policy;
    CREPolicyConsumer  internal cre;
    CapitallessHook    internal hook;
    SplitMockAdapter   internal adapter;

    Token internal usdc;
    Token internal weth;

    address internal admin  = makeAddr("admin");
    address internal owner  = makeAddr("owner");
    address internal taker  = makeAddr("taker");
    address internal mockFwd = address(0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5);

    uint256 internal makerKey = 0xBEEFDEAD;
    address internal maker    = vm.addr(makerKey);

    bytes32 internal constant STRATEGY = keccak256("INTEGRATION");
    address internal constant HOOK_ADDR = address(uint160(Hooks.BEFORE_SWAP_FLAG));

    uint256 constant QUOTE_IN   = 3_020e6;
    uint256 constant EXACT_OUT  = 1e18;
    uint256 constant INIT_FEE   = 3_000;

    // Two route configs: single-pool A vs split A+B
    bytes internal routeSingle = "route-single-A";
    bytes internal routeSplit  = "route-split-AB";
    bytes32 internal rhSingle;
    bytes32 internal rhSplit;

    uint256 constant COST_SINGLE = 3_015e6; // Pool A alone
    uint256 constant COST_SPLIT  = 3_010e6; // Split A+B is cheaper

    PoolKey internal poolKeyA;
    PoolId  internal poolIdA;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new Token(6);
        weth = new Token(18);

        policy  = new StrategyPolicy(admin);
        exec    = new RFQExecutor(address(policy), owner);
        adapter = new SplitMockAdapter(address(exec));

        // CRE
        cre = new CREPolicyConsumer(mockFwd, address(policy));
        bytes32 creRole = policy.CRE_CONSUMER_ROLE();
        vm.prank(admin); policy.grantRole(creRole, address(cre));

        // Hook
        deployCodeTo(
            "contracts/hooks/CapitallessHook.sol:CapitallessHook",
            abi.encode(IPoolManager(makeAddr("pm")), IStrategyPolicy(address(policy))),
            HOOK_ADDR
        );
        hook = CapitallessHook(HOOK_ADDR);
        hook.transferOwnership(owner);

        poolKeyA = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        poolIdA = poolKeyA.toId();

        rhSingle = keccak256(routeSingle);
        rhSplit  = keccak256(routeSplit);

        // Strategy
        vm.prank(maker);
        policy.createStrategy(STRATEGY, 500, 10_000, 1e22, 200);
        vm.startPrank(maker);
        policy.setStrategyActive(STRATEGY, true);
        policy.setTokenApproval(STRATEGY, address(usdc), true);
        policy.setTokenApproval(STRATEGY, address(weth), true);
        policy.setAdapterApproval(STRATEGY, address(adapter), true);
        policy.setPoolApproval(STRATEGY, rhSingle, true);
        policy.setPoolApproval(STRATEGY, rhSplit,  true);
        vm.stopPrank();

        // Initial CRE update (version 1)
        bytes32 cr2 = policy.CRE_CONSUMER_ROLE();
        vm.prank(admin); policy.grantRole(cr2, address(this));
        policy.applyCREPolicyUpdate(STRATEGY, uint24(INIT_FEE), 1, uint64(block.timestamp + 7 days));

        vm.prank(owner); hook.configurePool(poolIdA, STRATEGY);

        // Configure adapter routes
        adapter.configureRoute(rhSingle, COST_SINGLE, EXACT_OUT);
        adapter.configureRoute(rhSplit,  COST_SPLIT,  EXACT_OUT);

        // Fund
        usdc.mint(taker, 100_000e6);
        weth.mint(address(adapter), 100e18);
        vm.prank(taker); usdc.approve(address(exec), type(uint256).max);
    }

    function _order(bytes32 rh, uint256 nonce) internal view returns (IRFQExecutor.RFQOrder memory) {
        return IRFQExecutor.RFQOrder({
            strategyId:       STRATEGY,
            maker:            maker,
            taker:            taker,
            tokenIn:          address(usdc),
            tokenOut:         address(weth),
            quoteAmountIn:    QUOTE_IN,
            exactAmountOut:   EXACT_OUT,
            minMakerProceeds: 1e6,
            expiry:           block.timestamp + 1 hours,
            nonce:            nonce,
            policyVersion:    1,
            adapter:          address(adapter),
            routeHash:        rh
        });
    }

    function _sign(IRFQExecutor.RFQOrder memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, exec.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    // -------------------------------------------------------------------------
    // Full E2E: happy path
    // -------------------------------------------------------------------------
    function test_e2e_happyPath() public {
        IRFQExecutor.RFQOrder memory o = _order(rhSingle, 0);
        vm.startPrank(taker);
        exec.executeRFQ(o, _sign(o), routeSingle);
        vm.stopPrank();

        assertEq(weth.balanceOf(taker), EXACT_OUT,                           "taker WETH");
        assertEq(usdc.balanceOf(maker), QUOTE_IN - COST_SINGLE,              "maker spread");
        assertEq(usdc.balanceOf(address(exec)), 0,                           "exec USDC zero");
        assertEq(weth.balanceOf(address(exec)), 0,                           "exec WETH zero");
        assertEq(weth.balanceOf(maker),          0,                           "maker holds no WETH");
        assertEq(weth.allowance(maker, address(exec)), 0,                    "maker WETH allowance zero");
    }

    // -------------------------------------------------------------------------
    // Test 9: Split route costs less than single pool
    // -------------------------------------------------------------------------
    function test_9_splitRouteCheaperThanSinglePool() public {
        // Single pool: spread = QUOTE_IN - COST_SINGLE
        IRFQExecutor.RFQOrder memory oSingle = _order(rhSingle, 0);
        vm.startPrank(taker);
        exec.executeRFQ(oSingle, _sign(oSingle), routeSingle);
        vm.stopPrank();
        uint256 spreadSingle = usdc.balanceOf(maker);

        // Reset maker for next order
        vm.prank(maker); usdc.transfer(address(0xdead), spreadSingle);
        usdc.mint(taker, QUOTE_IN);

        // Split route: spread = QUOTE_IN - COST_SPLIT (larger)
        IRFQExecutor.RFQOrder memory oSplit = _order(rhSplit, 1);
        vm.startPrank(taker);
        exec.executeRFQ(oSplit, _sign(oSplit), routeSplit);
        vm.stopPrank();
        uint256 spreadSplit = usdc.balanceOf(maker);

        assertLt(COST_SPLIT, COST_SINGLE,       "split route costs less");
        assertGt(spreadSplit, spreadSingle,       "split route leaves more spread for maker");
        console.log("Single pool cost (USDC):", COST_SINGLE/1e6);
        console.log("Split pool cost (USDC):", COST_SPLIT/1e6);
    }

    // -------------------------------------------------------------------------
    // Test 10: CRE update changes hook fee, next execution observes it
    // -------------------------------------------------------------------------
    function test_10_creUpdateChangesHookFee() public {
        // Read fee before update
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });
        vm.prank(makeAddr("pm"));
        (,, uint24 fee1) = hook.beforeSwap(address(this), poolKeyA, params, "");
        assertEq(fee1 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, INIT_FEE, "fee before CRE");

        // CRE update
        uint24 newFee = 7_500;
        bytes memory report = abi.encode(ICREPolicyConsumer.PolicyReport({
            schemaVersion: 1,
            strategyId:    STRATEGY,
            proposedFee:   newFee,
            observedAt:    uint64(block.timestamp),
            validUntil:    uint64(block.timestamp + 7 days),
            policyVersion: 2
        }));
        vm.prank(mockFwd); cre.onReport("", report);
        assertEq(policy.getStrategy(STRATEGY).currentDynamicFee, newFee);

        // Execute next order — strategy now at policyVersion 2
        IRFQExecutor.RFQOrder memory o = _order(rhSingle, 0);
        o.policyVersion = 2;
        vm.startPrank(taker);
        exec.executeRFQ(o, _sign(o), routeSingle);
        vm.stopPrank();

        // Hook reads updated fee
        vm.prank(makeAddr("pm"));
        (,, uint24 fee2) = hook.beforeSwap(address(this), poolKeyA, params, "");
        assertEq(fee2 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, newFee, "fee after CRE");
        console.log("Fee changed from", INIT_FEE, "to", newFee);
    }
}
