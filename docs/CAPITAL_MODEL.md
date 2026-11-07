# CAPITLESS — Capital Model

## (a) The Maker needs no inventory

The Maker holds no WETH and grants no WETH allowance to the Executor. The Maker's only on-chain action is receiving USDC as a spread. The Maker's off-chain action is quoting a firm price by signing an EIP-712 RFQOrder.

When an order executes:
- USDC flows from Taker → Executor → Adapter → PoolManager.
- WETH flows from PoolManager (LP liquidity) → Taker, directly inside the unlock callback.
- USDC spread flows from Executor → Maker.

The Maker earns: `makerProceeds = quoteAmountIn - actualRouteCost`

## (b) Output liquidity comes from LPs

WETH delivered to the Taker comes from liquidity providers in the Uniswap v4 pools. The adapter executes exact-output swaps — it asks for a specific amount of WETH and pays the market-determined USDC cost.

On testnet (Base Sepolia): pools are seeded by a separate LP wallet via `SeedPools.s.sol`. The LP wallet is distinct from the Maker and Deployer wallets.

On mainnet: the Executor routes through any existing deep Uniswap v4 USDC/WETH pool permissionlessly. No special LP relationship is required.

## (c) Flash accounting is deferred netting, not a loan

Inside `PoolManager.unlock()`, the Uniswap v4 accounting system tracks signed deltas per currency per address. No tokens are "lent" — the PoolManager simply defers verification of token movement until the unlock session closes.

The adapter accrues:
- A negative USDC delta (it owes USDC to the pools for the swap).
- A negative WETH delta (from `take()` — it withdrew WETH on behalf of the Taker).
- These cancel against the positive WETH delta from the swap itself.

At the end of the callback the adapter settles its net USDC debt via `sync → transfer → settle`. If any delta is nonzero when `unlock` returns, PoolManager reverts with `CurrencyNotSettled`. The adapter also asserts zero deltas explicitly before returning.

Flash accounting enables the entire flow — route execution, output delivery to Taker, and input settlement — to occur atomically in one transaction without pre-funding capital.

## (d) Remaining risks

| Risk | Description |
|---|---|
| Stale quote | The Maker signs a price based on observed market data. If the pool price moves adversely before the transaction is included, `actualRouteCost` increases and `makerProceeds` shrinks. The `minMakerProceeds` floor in the order protects the Maker from catastrophic adverse moves. |
| Failed-tx gas | If the transaction reverts (expired order, stale policyVersion, insufficient proceeds), the Taker and Maker pay gas for nothing. No tokens are lost. |
| State drift between simulation and inclusion | The Maker's pricing engine simulates the route cost at quote time. The actual cost at inclusion may differ due to intervening trades in the pool. The `minMakerProceeds` floor bounds the Maker's downside but does not eliminate cost uncertainty. |
| policyVersion staleness | If the CRE workflow updates the policy between when the Maker signs and when the Taker submits, the `policyVersion` check will revert. The Maker must re-quote with the new version. This is a liveness trade-off for correctness. |
