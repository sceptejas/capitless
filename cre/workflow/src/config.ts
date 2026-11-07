/**
 * config.ts
 * Static configuration for the CRE workflow.
 * All addresses match DEPLOYMENT_PARAMS.md.
 */

export const CONFIG = {
  // Ethereum Sepolia chain ID
  CHAIN_ID: 11155111n,

  // Chainlink CRE chain identifier (used in workflow YAML)
  CRE_CHAIN_ID: "ethereum-testnet-sepolia",

  // MockKeystoneForwarder on Ethereum Sepolia (simulation mode)
  MOCK_FORWARDER: "0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5" as const,

  // Production KeystoneForwarder on Ethereum Sepolia (do not use during hackathon)
  PROD_FORWARDER: "0xF8344CFd5c43616a4366C34E3EEE75af79a74482" as const,

  // CREPolicyConsumer deployed address (filled after Phase 8 deployment)
  CONSUMER_ADDRESS: (process.env.CONSUMER_ADDRESS ?? "0xEf063eB2c000E33A2A6061c5dc648304Bd5c450c") as `0x${string}`,

  // RPC endpoint for Ethereum Sepolia
  RPC_URL: process.env.SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com",

  // Demo strategy ID — must match the strategy created in ConfigureStrategy.s.sol
  STRATEGY_ID: (process.env.STRATEGY_ID ?? "0x90742d7d905464117a9f5753ba0f0f183110254868ea9f89ef0c045e2a57d866") as `0x${string}`,

  // Fee formula parameters
  // proposedFee = BASE_FEE + VOLATILITY_MULTIPLIER * volatility
  // clamped to [MIN_FEE, MAX_FEE]
  BASE_FEE:              500n,  // 0.05% in hundredths of a bip
  VOLATILITY_MULTIPLIER: 100n,  // fee increment per 1% of volatility
  MIN_FEE:               500n,
  MAX_FEE:            10_000n,

  // Maximum acceptable age of observed market data (seconds)
  MAX_DATA_AGE_SECONDS: 3600,

  // How long the policy update should be valid onchain (seconds)
  VALID_DURATION_SECONDS: 86_400, // 1 day

  // PolicyReport schemaVersion — must match CREPolicyConsumer.SCHEMA_VERSION
  SCHEMA_VERSION: 1n,
} as const;
