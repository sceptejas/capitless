// rfq.ts — construct the RFQOrder struct

import { CONFIG } from "./config.js";
import type { Quote } from "./pricing.js";
import { keccak256, toHex } from "viem";

export interface RFQOrder {
  strategyId:       `0x${string}`;
  maker:            `0x${string}`;
  taker:            `0x${string}`; // address(0) = open
  tokenIn:          `0x${string}`;
  tokenOut:         `0x${string}`;
  quoteAmountIn:    bigint;
  exactAmountOut:   bigint;
  minMakerProceeds: bigint;
  maxSlippageBps:   bigint;
  expiry:           bigint;
  nonce:            bigint;
  adapter:          `0x${string}`;
  routeHash:        `0x${string}`;
}

export function buildOrder(
  maker: `0x${string}`,
  quote: Quote,
  nonce: bigint,
  routeData: `0x${string}` = CONFIG.DEMO_ROUTE_DATA
): RFQOrder {
  const expiry = BigInt(Math.floor(Date.now() / 1000) + CONFIG.ORDER_EXPIRY_SECS);
  const routeHash = keccak256(routeData);

  return {
    strategyId:       CONFIG.STRATEGY_ID,
    maker,
    taker:            "0x0000000000000000000000000000000000000000", // open order
    tokenIn:          CONFIG.USDC,
    tokenOut:         CONFIG.WETH,
    quoteAmountIn:    quote.quoteAmountIn,
    exactAmountOut:   quote.exactAmountOut,
    minMakerProceeds: quote.minMakerProceeds,
    maxSlippageBps:   CONFIG.MAX_SLIPPAGE_BPS,
    expiry,
    nonce,
    adapter:          CONFIG.ADAPTER,
    routeHash,
  };
}
