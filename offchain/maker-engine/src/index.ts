// index.ts — Maker pricing engine entry point
//
// Pipeline:
//   1. Fetch ETH/USDC market data
//   2. Estimate hedge cost (simulator)
//   3. Compute quote (net edge check)
//   4. Build RFQOrder struct
//   5. EIP-712 sign with Maker key
//   6. Write signed-order.json
//
// Usage:
//   npm run quote           — full run, writes signed-order.json
//   npm run quote:dry-run   — skips signing, prints order only
//
// Env vars:
//   MAKER_PRIVATE_KEY   Maker's private key (hex, with 0x)
//   RFQ_EXECUTOR        Deployed RFQExecutor address
//   ADAPTER             Deployed UniswapV4Adapter address
//   STRATEGY_ID         Strategy ID in StrategyPolicy
//   SEPOLIA_RPC_URL      Ethereum Sepolia RPC endpoint

import { writeFileSync } from "fs";
import { CONFIG } from "./config.js";
import { fetchMarketSnapshot } from "./market-data.js";
import { estimateHedgeCost } from "./simulator.js";
import { computeQuote, NO_QUOTE } from "./pricing.js";
import { buildOrder } from "./rfq.js";
import { signOrder } from "./signer.js";

const DRY_RUN = process.argv.includes("--dry-run");

// Demo: quote 1 WETH out, nonce 0
const EXACT_WETH_OUT  = BigInt(1e18);   // 1 WETH
const DESIRED_SPREAD  = 10_000_000n;    // $10 desired gross spread (6 dec)
const NONCE           = 0n;

async function main() {
  console.log("\n=== CAPITLESS Maker Engine ===");
  console.log(`Mode: ${DRY_RUN ? "DRY RUN (no signing)" : "LIVE"}`);

  // Step 1 — Market data
  console.log("\n[1] Fetching market data...");
  const snap = await fetchMarketSnapshot();
  console.log(`    ETH/USD: $${snap.ethUsd.toLocaleString()} @ ${new Date(snap.observedAt * 1000).toISOString()}`);

  // Step 2 — Hedge estimate
  console.log("\n[2] Estimating hedge cost...");
  const hedge = estimateHedgeCost(snap.ethUsd, EXACT_WETH_OUT, CONFIG.MAX_SLIPPAGE_BPS);
  console.log(`    Hedge cost (USDC): ${Number(hedge.hedgeCostUsdc) / 1e6}`);

  // Step 3 — Pricing
  console.log("\n[3] Computing quote...");
  const quote = computeQuote(hedge, DESIRED_SPREAD);
  if (quote === NO_QUOTE) {
    console.log("    NO_QUOTE — spread below minimum. Exiting.");
    process.exit(0);
  }
  console.log(`    quoteAmountIn:    ${Number(quote.quoteAmountIn)    / 1e6} USDC`);
  console.log(`    exactAmountOut:   ${Number(quote.exactAmountOut)   / 1e18} WETH`);
  console.log(`    minMakerProceeds: ${Number(quote.minMakerProceeds) / 1e6} USDC`);

  // Step 4 — Build order
  console.log("\n[4] Building RFQOrder...");
  const { privateKeyToAccount } = await import("viem/accounts");
  const makerAddress = DRY_RUN
    ? "0x000000000000000000000000000000000000dEaD" as `0x${string}`
    : privateKeyToAccount(CONFIG.MAKER_PRIVATE_KEY).address as `0x${string}`;

  const order = buildOrder(makerAddress, quote, NONCE);
  console.log(`    strategyId:  ${order.strategyId}`);
  console.log(`    expiry:      ${new Date(Number(order.expiry) * 1000).toISOString()}`);
  console.log(`    routeHash:   ${order.routeHash}`);

  if (DRY_RUN) {
    const output = { dryRun: true, order: serializeOrder(order) };
    console.log("\n[DRY RUN] Order (unsigned):\n", JSON.stringify(output, null, 2));
    writeFileSync("signed-order.json", JSON.stringify(output, null, 2));
    console.log("\nWritten to signed-order.json (unsigned)");
    return;
  }

  // Step 5 — Sign
  console.log("\n[5] Signing EIP-712...");
  const executorAddress = CONFIG.RFQ_EXECUTOR === "0x0000000000000000000000000000000000000000"
    ? "0x0000000000000000000000000000000000001234" as `0x${string}` // placeholder for local test
    : CONFIG.RFQ_EXECUTOR;

  const signed = await signOrder(order, executorAddress);
  console.log(`    signer:     ${signed.signer}`);
  console.log(`    digest:     ${signed.digest}`);
  console.log(`    signature:  ${signed.signature.slice(0, 20)}...`);

  // Step 6 — Output
  const output = {
    order:          serializeOrder(signed.order),
    signature:      signed.signature,
    signer:         signed.signer,
    digest:         signed.digest,
    executorAddress,
    routeData:      CONFIG.DEMO_ROUTE_DATA,
    generatedAt:    new Date().toISOString(),
  };

  writeFileSync("signed-order.json", JSON.stringify(output, null, 2));
  console.log("\n[6] Written to signed-order.json");
  console.log("\n=== Maker Engine complete ===\n");
}

// Serialize bigints to strings for JSON
function serializeOrder(order: ReturnType<typeof buildOrder>) {
  return {
    strategyId:       order.strategyId,
    maker:            order.maker,
    taker:            order.taker,
    tokenIn:          order.tokenIn,
    tokenOut:         order.tokenOut,
    quoteAmountIn:    order.quoteAmountIn.toString(),
    exactAmountOut:   order.exactAmountOut.toString(),
    minMakerProceeds: order.minMakerProceeds.toString(),
    maxSlippageBps:   order.maxSlippageBps.toString(),
    expiry:           order.expiry.toString(),
    nonce:            order.nonce.toString(),
    adapter:          order.adapter,
    routeHash:        order.routeHash,
  };
}

main().catch(err => {
  console.error("[maker-engine] Fatal:", err);
  process.exit(1);
});
