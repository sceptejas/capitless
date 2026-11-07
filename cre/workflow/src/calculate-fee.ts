/**
 * calculate-fee.ts
 * Fee formula: proposedFee = BASE_FEE + VOLATILITY_MULTIPLIER * volatility
 * Clamped to [MIN_FEE, MAX_FEE].
 *
 * This is a market-making demonstration, not a production risk model.
 * Higher volatility → higher spread → more protection for the Maker.
 */

import { CONFIG } from "./config.js";
import type { MarketData } from "./fetch-data.js";

export interface FeeResult {
  proposedFee: bigint;  // In Uniswap v4 LP fee units (hundredths of a bip)
  rawFee:      bigint;  // Before clamping (for logging)
}

/**
 * Calculate the proposed LP fee given current market data.
 *
 * Formula (illustrative, not production-grade):
 *   proposedFee = BASE_FEE + VOLATILITY_MULTIPLIER * (volatilityBps / 100)
 *
 * Example: volatility = 300 bps (3%)
 *   rawFee = 500 + 100 * (300 / 100) = 500 + 300 = 800 (0.08%)
 *   clamped to [500, 10000]
 */
export function calculateFee(data: MarketData): FeeResult {
  // volatilityBps is in basis points (e.g. 300 = 3%)
  // Scale: each 100 bps of volatility adds VOLATILITY_MULTIPLIER to the fee
  const volatilityContribution = (data.volatilityBps / 100n) * CONFIG.VOLATILITY_MULTIPLIER;
  const rawFee = CONFIG.BASE_FEE + volatilityContribution;

  // Clamp to [MIN_FEE, MAX_FEE]
  let proposedFee = rawFee;
  if (proposedFee < CONFIG.MIN_FEE) proposedFee = CONFIG.MIN_FEE;
  if (proposedFee > CONFIG.MAX_FEE) proposedFee = CONFIG.MAX_FEE;

  console.log(`[calculate-fee] Raw fee: ${rawFee} | Proposed fee (clamped): ${proposedFee}`);
  console.log(`[calculate-fee] Fee in %: ${Number(proposedFee) / 10_000}%`);

  return { proposedFee, rawFee };
}
