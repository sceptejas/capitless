# CAPITLESS

Capital-efficient RFQ market-making on Uniswap v4 with Chainlink CRE dynamic fee policy.

Ethereum Sepolia testnet deployment

---

## What it does

A Maker quotes a firm price for WETH/USDC. The Taker accepts and pays exactly the quoted USDC. The Maker earns the spread between the quoted price and the actual Uniswap v4 hedge cost. Chainlink CRE adjusts the LP fee dynamically based on real market volatility.

**Demo flow:**
1. Maker signs an EIP-712 RFQ order: "I will sell 1 WETH for 3,020 USDC"
2. Taker calls `executeRFQ` — pays 3,020 USDC, receives 1 WETH
3. Executor hedges via Uniswap v4 (costs ~3,010 USDC)
4. Maker earns ~10 USDC spread
5. Chainlink CRE workflow fetches ETH volatility and updates the LP fee
6. Next swap on the same pool uses the CRE-updated fee

---

## Architecture

```
Taker
  │ executeRFQ(order, sig, routeData)
  ▼
RFQExecutor ──────── StrategyPolicy
  │ EIP-712 validate       (permissions, fee bounds)
  │ allowance-pull WETH ◄── Maker wallet
  │ deliver WETH ──────────► Taker
  │ transfer USDC ─────────► UniswapV4Adapter
  ▼
UniswapV4Adapter
  │ poolManager.unlock()
  ▼
PoolManager ◄────────── CapitallessHook (beforeSwap fee override)
  │ swap: USDC → WETH
  │ take(WETH) ────────────► Maker wallet (hedge replenishes inventory)
  ▼
RFQExecutor
  │ pay spread ────────────► Maker wallet
  ▼
done

CRE workflow (async):
  CoinGecko → calculate fee → encode PolicyReport
    → CRE CLI simulate → CREPolicyConsumer → StrategyPolicy
```

---

## Contracts (Ethereum Sepolia)

| Contract | Address |
|---|---|
| StrategyPolicy | TBD after deployment |
| RFQExecutor | TBD |
| UniswapV4Adapter | TBD |
| CapitallessHook | TBD |
| CREPolicyConsumer | TBD |

See `deployments/11155111.json` after deployment.

---

## Uniswap v4 Integration

`UniswapV4Adapter` uses the full `IPoolManager.unlock` / `unlockCallback` pattern. All currency deltas are resolved inside a single unlock session using `sync + transfer + settle` for debts and `take` for credits. No capital is held between executions.

`CapitallessHook` is a dynamic-fee hook (permission bit: `BEFORE_SWAP_FLAG`). It reads `StrategyPolicy.currentDynamicFee` on every swap and returns a fee override using `LPFeeLibrary.OVERRIDE_FEE_FLAG`. The fee is updated asynchronously by Chainlink CRE.

Developer feedback: [FEEDBACK.md](./FEEDBACK.md)

---

## Chainlink CRE Integration

`CREPolicyConsumer` implements the official `IReceiver` interface. The KeystoneForwarder (mock for simulation) calls `onReport(metadata, report)` after DON signature verification.

The CRE TypeScript workflow (`cre/workflow/`):
- Fetches ETH/USDC price and volatility from CoinGecko
- Calculates `proposedFee = BASE_FEE + k * volatility`, clamped to `[MIN_FEE, MAX_FEE]`
- ABI-encodes a `PolicyReport` struct matching the Solidity consumer exactly
- Outputs the encoded report for CRE CLI simulation

```bash
cd cre/workflow
npm install
npm run simulate   # dry run, prints encoded report
npm run start      # submit via CRE CLI (requires CONSUMER_ADDRESS env)
```

---

## Setup

### Prerequisites
- Foundry (`forge`, `cast`, `anvil`)
- Node.js ≥ 20

### Install
```bash
git clone <repo>
cd capitless
forge build
```

### Run tests
```bash
forge test -v
# 130 tests, all passing
```

### Local deployment (Anvil)
```bash
anvil --chain-id 84532

export DEPLOYER_PRIVATE_KEY=<key>
export MAKER_PRIVATE_KEY=<key>

forge script script/Deploy.s.sol             --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/DeployCRE.s.sol          --rpc-url http://127.0.0.1:8545 --broadcast \
  --env STRATEGY_POLICY=<addr>
forge script script/ConfigureStrategy.s.sol  --rpc-url http://127.0.0.1:8545 --broadcast \
  --env STRATEGY_POLICY=<addr> ADAPTER=<addr> HOOK=<addr>
```

### Run Maker engine
```bash
cd offchain/maker-engine
npm install
npm run quote:dry   # dry run
npm run quote       # full sign (requires MAKER_PRIVATE_KEY)
```

---

## Test coverage (130 tests)

| Suite | Tests | Description |
|---|---|---|
| StrategyPolicy | 37 | Permissions, signers, fee bounds, CRE restrictions |
| UniswapV4Adapter (unit) | 10 | Executor guard, route hash, PoolKey approval |
| UniswapV4Adapter (multi-hop) | 11 | Two-pool netting, slippage, insufficient output |
| RFQExecutor | 25 | EIP-712, nonces, expiry, taker, settlement |
| CapitallessHook | 17 | Permission bits, fee override, CRE update, D-4 reverts |
| CREPolicyConsumer | 21 | Forwarder auth, replay, staleness, fee bounds |
| Integration | 9 | Full E2E flow, balance reconciliation, demo sequence |

---

## Sponsor tracks

### Uniswap
- `UniswapV4Adapter`: full `unlock` / `unlockCallback` implementation
- `CapitallessHook`: dynamic fee hook using `OVERRIDE_FEE_FLAG`
- Two-pool route support with intermediate delta netting
- Developer feedback: [FEEDBACK.md](./FEEDBACK.md)

### Chainlink
- `CREPolicyConsumer`: implements official `IReceiver` interface
- CRE TypeScript workflow with real market data from CoinGecko
- MockKeystoneForwarder simulation on Ethereum Sepolia

---

## License

MIT
