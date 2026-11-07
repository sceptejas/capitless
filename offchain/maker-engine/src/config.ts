// config.ts — all constants in one place, matches DEPLOYMENT_PARAMS.md

export const CONFIG = {
  CHAIN_ID:    11155111n,
  RPC_URL:     process.env.SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com",

  // Tokens (Ethereum Sepolia)
  USDC:        "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as `0x${string}`,
  WETH:        "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14" as `0x${string}`,
  USDC_DEC:    6,
  WETH_DEC:    18,

  // Deployed contracts — filled after Phase 8
  RFQ_EXECUTOR: (process.env.RFQ_EXECUTOR  ?? "0x7adA31A6e2E56c3E1Bec4cB9902b9227b3b92B16") as `0x${string}`,
  ADAPTER:      (process.env.ADAPTER       ?? "0x4f1E183DDBb988Dc43A119E172D528Dafc4E96C4") as `0x${string}`,
  STRATEGY_ID:  (process.env.STRATEGY_ID   ?? "0x90742d7d905464117a9f5753ba0f0f183110254868ea9f89ef0c045e2a57d866") as `0x${string}`,

  // EIP-712 domain — must match RFQExecutor constructor args exactly
  EIP712_NAME:    "CAPITLESS",
  EIP712_VERSION: "1",

  // Maker key — NEVER commit a real key; use env var
  MAKER_PRIVATE_KEY: (process.env.MAKER_PRIVATE_KEY ?? "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef") as `0x${string}`,

  // Pricing params
  MIN_NET_EDGE_USDC: 5_000_000n,  // $5 minimum spread before quoting (6 dec)
  ORDER_EXPIRY_SECS: 300,         // 5 minutes
  MAX_SLIPPAGE_BPS:  50n,         // 0.5% max hedge slippage

  // routeHash placeholder — replaced by real route in Phase 8/9
  // For now: keccak256("demo-route") so the engine output validates in tests
  DEMO_ROUTE_DATA:   "0x64656d6f2d726f757465" as `0x${string}`, // hex("demo-route")
} as const;
