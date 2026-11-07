# Uniswap v4 Developer Feedback — CAPITLESS

Submitted as part of the ETHGlobal hackathon Uniswap sponsor track requirement.

---

## What we built

CAPITLESS is a capital-efficient RFQ system built on Uniswap v4. A Maker quotes a firm price for WETH/USDC, earns the spread between the quoted price and the v4 hedge cost, and uses Chainlink CRE to dynamically adjust the LP fee based on market volatility.

---

## v4 features used

### `IPoolManager.unlock` + flash accounting

We use the full unlock pattern. The `UniswapV4Adapter` calls `poolManager.unlock(data)`, receives the `unlockCallback`, executes the swap, and settles/takes all currency deltas inside the session. The adapter holds zero persistent token balances — everything nets in a single transaction.

This is the core of the demo. Flash accounting is what makes the atomic hedge possible without the adapter needing pre-funded capital.

### Dynamic fee hook (`beforeSwap`)

`CapitallessHook` is a dynamic-fee hook that intercepts `beforeSwap` and returns a fee override sourced from `StrategyPolicy`. The fee is updated asynchronously by Chainlink CRE based on real market volatility. Deploying to an address with the correct permission bits (via CREATE2 mining) was the trickiest integration step.

### Multi-pool routes (2-hop)

The adapter supports up to 2-hop routes, accumulating per-currency deltas across both hops. Intermediate currencies net to zero inside the unlock session — no intermediate settlement required.

---

## What worked well

- The unlock/callback pattern is clean once you understand that `settle` and `take` are the only ways to close deltas.
- `LPFeeLibrary.OVERRIDE_FEE_FLAG` is clearly documented and the fee override mechanism worked exactly as specified.
- `PoolIdLibrary.toId()` producing the same hash as `keccak256(abi.encode(poolKey))` made the StrategyPolicy pool allowlist straightforward to implement.
- forge-std's `deployCodeTo` made hook address mining in tests simple.

---

## What was confusing or missing

1. **No BaseHook in v4-periphery.** We expected a base contract similar to older hackathon examples, but `SafeCallback` is the closest thing and it only covers the unlock callback, not hooks. We implemented `IHooks` directly with no-op stubs for all unused hooks. A minimal `BaseHook` with no-op defaults would reduce boilerplate significantly.

2. **`beforeSwap` return type changed.** The `(bytes4, BeforeSwapDelta, uint24)` return tuple is not obvious from the interface without reading `Hooks.sol` and `LPFeeLibrary` carefully. The comment in `IHooks.sol` is helpful but the connection between `DYNAMIC_FEE_FLAG` in the pool initialisation and `OVERRIDE_FEE_FLAG` in the hook return value needs to be documented more prominently.

3. **Hook address mining is a significant deployment hurdle.** Finding a CREATE2 salt that satisfies `uint160(addr) & ALL_HOOK_MASK == desiredFlags` requires looping. The periphery's `HookMiner` utility exists but is not discoverable without reading example repos. A deployed factory that does this atomically would help.

4. **`Currency` sorting requirement is easy to violate.** `currency0 < currency1` must hold in `PoolKey` or `initialize` reverts. The error message (`CurrenciesOutOfOrderOrEqual`) is clear but the constraint should be visible in the `PoolKey` struct documentation.

5. **`settle()` vs `settleFor()` vs the `sync` prerequisite.** The pattern of `sync → transfer → settle` for ERC20 settlement is not documented in one place. We pieced it together from the `PoolManager` source. A single example showing the full ERC20 settlement pattern would save time.

---

## Suggestions

- Add a `BaseHook.sol` to v4-periphery with no-op implementations of all hooks and a `getHookPermissions()` pattern.
- Document the ERC20 settlement pattern (`sync → transfer → settle`) in the v4 README or a dedicated guide.
- Provide a reference integration test that shows a real multi-currency swap with delta resolution, similar to what Uniswap uses internally.

---

## Overall

The v4 architecture is a significant improvement over v3 for this use case. Flash accounting makes atomic hedge-then-settle patterns possible that were previously multi-transaction. The hook system is powerful and the permission-bit model is elegant once understood. The main friction is documentation gaps around the less common patterns.

This feedback reflects real development experience building CAPITLESS during the hackathon.
