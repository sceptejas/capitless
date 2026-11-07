// market-data.ts — fetch ETH/USDC reference price from CoinGecko public API

export interface MarketSnapshot {
  ethUsd:     number;   // spot price
  observedAt: number;   // unix seconds
}

export async function fetchMarketSnapshot(): Promise<MarketSnapshot> {
  const resp = await fetch(
    "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
    { signal: AbortSignal.timeout(8_000) }
  );
  if (!resp.ok) throw new Error(`CoinGecko ${resp.status}`);
  const data = await resp.json() as { ethereum?: { usd?: number } };
  const ethUsd = data?.ethereum?.usd;
  if (!ethUsd || ethUsd <= 0) throw new Error("Bad ETH price from CoinGecko");
  return { ethUsd, observedAt: Math.floor(Date.now() / 1000) };
}
