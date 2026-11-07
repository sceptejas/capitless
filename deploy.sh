#!/usr/bin/env bash
# Full Ethereum Sepolia deployment. Source .env before running.
set -euo pipefail

cd "$(dirname "$0")"
export PATH="$PATH:/Users/tejas/.foundry/bin"
RPC_URL="${SEPOLIA_RPC_URL:-${BASE_SEPOLIA_RPC_URL:-}}"
CHAIN_ID=11155111
DEPLOYMENTS_FILE="deployments/${CHAIN_ID}.json"

for name in DEPLOYER_PRIVATE_KEY MAKER_PRIVATE_KEY; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
done
if [[ -z "$RPC_URL" ]]; then
  echo "Set SEPOLIA_RPC_URL to an Ethereum Sepolia RPC endpoint." >&2
  exit 1
fi
if [[ -e "$DEPLOYMENTS_FILE" ]]; then
  echo "$DEPLOYMENTS_FILE already exists; refusing to create a second deployment." >&2
  exit 1
fi
if [[ "$(cast chain-id --rpc-url "$RPC_URL")" != "$CHAIN_ID" ]]; then
  echo "RPC endpoint is not Ethereum Sepolia (chain $CHAIN_ID)." >&2
  exit 1
fi

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
MAKER_ADDRESS="$(cast wallet address --private-key "$MAKER_PRIVATE_KEY")"
if [[ "$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")" == "0" || \
      "$(cast balance "$MAKER_ADDRESS" --rpc-url "$RPC_URL")" == "0" ]]; then
  echo "Both deployer and maker wallets need Sepolia ETH." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --chain "$CHAIN_ID" -vv | tee "$tmp_dir/core.log"
export STRATEGY_POLICY="$(awk '/StrategyPolicy:/ {print $2}' "$tmp_dir/core.log" | tail -1)"
export RFQ_EXECUTOR="$(awk '/RFQExecutor:/ {print $2}' "$tmp_dir/core.log" | tail -1)"
export ADAPTER="$(awk '/UniswapV4Adapter:/ {print $2}' "$tmp_dir/core.log" | tail -1)"

forge script script/DeployHook.s.sol --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --chain "$CHAIN_ID" -vv | tee "$tmp_dir/hook.log"
export HOOK="$(awk '/CapitallessHook deployed at:/ {print $4}' "$tmp_dir/hook.log" | tail -1)"
export POOL_ID="$(awk '/Pool initialised. PoolId:/ {print $4}' "$tmp_dir/hook.log" | tail -1)"

forge script script/DeployCRE.s.sol --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --chain "$CHAIN_ID" -vv | tee "$tmp_dir/cre.log"
export CRE_CONSUMER="$(awk '/CREPolicyConsumer:/ {print $2}' "$tmp_dir/cre.log" | tail -1)"

forge script script/ConfigureStrategy.s.sol --rpc-url "$RPC_URL" --private-key "$MAKER_PRIVATE_KEY" --broadcast --chain "$CHAIN_ID" -vv | tee "$tmp_dir/strategy.log"
export STRATEGY_ID="$(awk '/Strategy ID:/ {print $3}' "$tmp_dir/strategy.log" | tail -1)"

mkdir -p deployments
cat > "$DEPLOYMENTS_FILE" <<EOF
{
  "chainId": $CHAIN_ID,
  "network": "Ethereum Sepolia",
  "StrategyPolicy": "$STRATEGY_POLICY",
  "RFQExecutor": "$RFQ_EXECUTOR",
  "UniswapV4Adapter": "$ADAPTER",
  "CapitallessHook": "$HOOK",
  "CREPolicyConsumer": "$CRE_CONSUMER",
  "PoolId": "$POOL_ID",
  "demoStrategyId": "$STRATEGY_ID"
}
EOF

echo "Deployment complete. Addresses saved to $DEPLOYMENTS_FILE"
