// simulator.ts
// Estimates how much USDC the v4 hedge will cost to buy 1 WETH.
// In production this would query the actual pool's sqrtPriceX96.
// For the demo/hackathon we use the reference price plus a fee tier estimate.

export interface HedgeEstimate {
  hedgeCostUsdc: bigint;  // USDC needed to buy exactAmountOut WETH (6 dec)
  exactWethOut:  bigint;  // WETH delivered to Taker (18 dec) — always 1 WETH for demo
}

const POOL_FEE_BPS = 30n; // 0.30% pool fee (3000 in v4 units = 30 bps)

/**
 * Estimate hedge cost.
 * hedgeCost = referencePrice * (1 + poolFeeBps/10000) * (1 + slippageBps/10000)
 *
 * In production: read sqrtPriceX96 from PoolManager.getSlot0() and compute
 * the actual swap output for exactAmountOut.
 */
export function estimateHedgeCost(
  ethUsd: number,
  exactWethOut: bigint,
  slippageBps: bigint
): HedgeEstimate {
  // Convert reference price to USDC per WETH (6 decimals)
  const refPriceUsdc = BigInt(Math.round(ethUsd * 1e6));

  // Scale for exactWethOut (which may be fractional in 18-dec units)
  // refPriceUsdc is for 1 WETH (1e18). Scale proportionally.
  const scaledRef = (refPriceUsdc * exactWethOut) / BigInt(1e18);

  // Add pool fee: cost * (10000 + poolFeeBps) / 10000
  const afterPoolFee = (scaledRef * (10_000n + POOL_FEE_BPS)) / 10_000n;

  // Add slippage buffer
  const hedgeCostUsdc = (afterPoolFee * (10_000n + slippageBps)) / 10_000n;

  return { hedgeCostUsdc, exactWethOut };
}
