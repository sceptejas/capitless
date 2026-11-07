/**
 * index.ts
 * CAPITLESS CRE Workflow — main entry point.
 *
 * Orchestrates:
 *   1. Fetch ETH/USDC price and volatility from CoinGecko
 *   2. Calculate bounded dynamic fee using the fee formula
 *   3. Read current policyVersion from onchain StrategyPolicy
 *   4. Encode PolicyReport for CRE delivery
 *   5. Output the encoded report (simulation mode) or submit via CRE CLI
 *
 * Run modes:
 *   npm run simulate   → prints encoded report, does not submit
 *   npm run start      → submits via CRE CLI (requires CONSUMER_ADDRESS env)
 *
 * Environment variables:
 *   SEPOLIA_RPC_URL        Ethereum Sepolia RPC endpoint (defaults to public)
 *   CONSUMER_ADDRESS       Deployed CREPolicyConsumer address
 *   STRATEGY_ID            Strategy ID to update
 */

import { createPublicClient, http, parseAbi } from "viem";
import { sepolia } from "viem/chains";
import { CONFIG } from "./config.js";
import { fetchMarketData } from "./fetch-data.js";
import { calculateFee } from "./calculate-fee.js";
import { encodeReport } from "./encode-report.js";
import { writeFileSync } from "fs";

const SIMULATE = process.argv.includes("--simulate") || !process.env.CONSUMER_ADDRESS;

// ---------------------------------------------------------------------------
// Minimal ABI for reading StrategyPolicy.getStrategy()
// ---------------------------------------------------------------------------
const STRATEGY_POLICY_ABI = [
  {
    name: "getStrategy",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "strategyId", type: "bytes32" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "maker",            type: "address" },
          { name: "active",           type: "bool"    },
          { name: "maxOrderSize",     type: "uint256" },
          { name: "maxSlippageBps",   type: "uint256" },
          { name: "minDynamicFee",    type: "uint24"  },
          { name: "maxDynamicFee",    type: "uint24"  },
          { name: "currentDynamicFee",type: "uint24"  },
          { name: "policyVersion",    type: "uint64"  },
          { name: "validUntil",       type: "uint64"  },
        ],
      },
    ],
  },
] as const;

async function main() {
  console.log("\n=== CAPITLESS CRE Workflow ===");
  console.log(`Mode: ${SIMULATE ? "SIMULATE (no submission)" : "LIVE"}`);
  console.log(`Chain: Ethereum Sepolia (${CONFIG.CHAIN_ID})`);
  console.log(`Strategy: ${CONFIG.STRATEGY_ID}\n`);

  // ---------------------------------------------------------------------------
  // Step 1: Fetch market data
  // ---------------------------------------------------------------------------
  console.log("--- Step 1: Fetch market data ---");
  const marketData = await fetchMarketData();

  // Validate freshness
  const dataAge = Math.floor(Date.now() / 1000) - marketData.observedAt;
  if (dataAge > CONFIG.MAX_DATA_AGE_SECONDS) {
    throw new Error(`Market data is too stale: ${dataAge}s > ${CONFIG.MAX_DATA_AGE_SECONDS}s`);
  }

  // ---------------------------------------------------------------------------
  // Step 2: Calculate fee
  // ---------------------------------------------------------------------------
  console.log("\n--- Step 2: Calculate fee ---");
  const { proposedFee } = calculateFee(marketData);

  // Validate bounds before encoding
  if (proposedFee < CONFIG.MIN_FEE || proposedFee > CONFIG.MAX_FEE) {
    throw new Error(`Proposed fee ${proposedFee} is outside [${CONFIG.MIN_FEE}, ${CONFIG.MAX_FEE}]`);
  }

  // ---------------------------------------------------------------------------
  // Step 3: Read current policyVersion from onchain
  // ---------------------------------------------------------------------------
  console.log("\n--- Step 3: Read current policyVersion ---");
  const client = createPublicClient({
    chain: sepolia,
    transport: http(CONFIG.RPC_URL),
  });

  let nextPolicyVersion = 1n;

  // Try to read from onchain — if consumer or policy not deployed yet, use version 1
  if (CONFIG.CONSUMER_ADDRESS !== "0x0000000000000000000000000000000000000000") {
    try {
      // Read StrategyPolicy address from consumer
      const consumerAbi = parseAbi([
        "function strategyPolicy() view returns (address)"
      ]);
      const policyAddress = await client.readContract({
        address: CONFIG.CONSUMER_ADDRESS,
        abi: consumerAbi,
        functionName: "strategyPolicy",
      });

      // Read current policyVersion
      const strategy = await client.readContract({
        address: policyAddress,
        abi: STRATEGY_POLICY_ABI,
        functionName: "getStrategy",
        args: [CONFIG.STRATEGY_ID as `0x${string}`],
      });

      nextPolicyVersion = (strategy as { policyVersion: bigint }).policyVersion + 1n;
      console.log(`[index] Current policyVersion: ${nextPolicyVersion - 1n} → next: ${nextPolicyVersion}`);
    } catch (err) {
      console.warn(`[index] Could not read onchain policyVersion (using 1): ${err}`);
      nextPolicyVersion = 1n;
    }
  } else {
    console.log("[index] CONSUMER_ADDRESS not set — using policyVersion = 1");
  }

  // ---------------------------------------------------------------------------
  // Step 4: Encode report
  // ---------------------------------------------------------------------------
  console.log("\n--- Step 4: Encode PolicyReport ---");
  const now       = BigInt(Math.floor(Date.now() / 1000));
  const validUntil = now + BigInt(CONFIG.VALID_DURATION_SECONDS);

  const { encoded, reportData } = encodeReport({
    strategyId:    CONFIG.STRATEGY_ID as `0x${string}`,
    proposedFee,
    observedAt:    BigInt(marketData.observedAt),
    validUntil,
    policyVersion: nextPolicyVersion,
  });

  // ---------------------------------------------------------------------------
  // Step 5: Output or submit
  // ---------------------------------------------------------------------------
  console.log("\n--- Step 5: Output report ---");

  const output = {
    mode:            SIMULATE ? "simulation" : "live",
    chainId:         Number(CONFIG.CHAIN_ID),
    consumerAddress: CONFIG.CONSUMER_ADDRESS,
    strategyId:      CONFIG.STRATEGY_ID,
    reportData: {
      schemaVersion:  reportData.schemaVersion.toString(),
      proposedFee:    reportData.proposedFee.toString(),
      observedAt:     reportData.observedAt.toString(),
      validUntil:     reportData.validUntil.toString(),
      policyVersion:  reportData.policyVersion.toString(),
    },
    encodedReport: encoded,
    ethPriceUsd:   marketData.ethPriceUsd,
    volatilityBps: marketData.volatilityBps.toString(),
  };

  // Write output to file for CRE CLI or inspection
  const outputPath = "cre-report.json";
  writeFileSync(outputPath, JSON.stringify(output, null, 2));
  console.log(`\n[index] Report written to ${outputPath}`);

  if (SIMULATE) {
    console.log("\n[index] SIMULATION MODE — encoded report ready for CRE CLI:");
    console.log(`\n  cre workflow simulate --report ${encoded}\n`);
    console.log("To submit to CRE CLI simulation:");
    console.log("  1. Deploy CREPolicyConsumer (Phase 8)");
    console.log("  2. Set CONSUMER_ADDRESS env var");
    console.log("  3. Run: npm run start\n");
  } else {
    // In production this would call the CRE SDK writeReport()
    // For hackathon: CRE CLI simulation is used, output the report for manual submission
    console.log("\n[index] LIVE MODE — submit encoded report via CRE CLI:");
    console.log(`  cre workflow simulate --consumer ${CONFIG.CONSUMER_ADDRESS} --report ${encoded}\n`);
  }

  console.log("=== Workflow complete ===\n");
  return output;
}

main().catch(err => {
  console.error("[index] Fatal error:", err);
  process.exit(1);
});
