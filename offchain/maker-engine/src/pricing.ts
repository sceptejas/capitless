// pricing.ts
// Applies the net edge formula and decides whether to issue a quote.
// Returns NO_QUOTE if the spread is below the minimum threshold.

import { CONFIG } from "./config.js";
import type { HedgeEstimate } from "./simulator.js";

export const NO_QUOTE = Symbol("NO_QUOTE");

export interface Quote {
  quoteAmountIn:    bigint;  // Exact USDC Taker pays
  exactAmountOut:   bigint;  // Exact WETH Taker receives
  minMakerProceeds: bigint;  // Minimum USDC spread for Maker
  estimatedHedge:   bigint;  // Expected hedge cost (informational)
}

/**
 * Net edge formula:
 *   quoteAmountIn    = hedgeCost + desiredSpread
 *   minMakerProceeds = desiredSpread * SAFETY_FACTOR (80% of desired, floor protection)
 *
 * If desiredSpread < MIN_NET_EDGE_USDC → return NO_QUOTE.
 */
export function computeQuote(
  hedge: HedgeEstimate,
  desiredSpreadUsdc: bigint
): Quote | typeof NO_QUOTE {
  if (desiredSpreadUsdc < CONFIG.MIN_NET_EDGE_USDC) {
    console.log(`[pricing] Spread ${desiredSpreadUsdc} < min ${CONFIG.MIN_NET_EDGE_USDC} → NO_QUOTE`);
    return NO_QUOTE;
  }

  const quoteAmountIn    = hedge.hedgeCostUsdc + desiredSpreadUsdc;
  const minMakerProceeds = (desiredSpreadUsdc * 80n) / 100n; // 80% floor

  return {
    quoteAmountIn,
    exactAmountOut:   hedge.exactWethOut,
    minMakerProceeds,
    estimatedHedge:   hedge.hedgeCostUsdc,
  };
}
