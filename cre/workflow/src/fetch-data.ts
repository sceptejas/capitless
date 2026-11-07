/**
 * fetch-data.ts
 * Fetches ETH/USDC spot price and computes a simple volatility proxy.
 *
 * Data source: CoinGecko public API (no API key required for basic endpoints).
 * We fetch the 1-hour OHLC candles and compute the range / mid as a volatility proxy.
 *
 * Content attribution: price data from CoinGecko public API.
 */

export interface MarketData {
  ethPriceUsd: number;    // Current ETH spot price in USD
  volatilityBps: bigint;  // Volatility estimate in basis points (0–10000+)
  observedAt: number;     // Unix timestamp of data observation
}

/**
 * Fetch current ETH price and a simple volatility estimate.
 * Uses CoinGecko's free /simple/price and /coins/ethereum/ohlc endpoints.
 */
export async function fetchMarketData(): Promise<MarketData> {
  const observedAt = Math.floor(Date.now() / 1000);

  // Fetch current ETH spot price
  const priceResp = await fetch(
    "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
    { signal: AbortSignal.timeout(10_000) }
  );

  if (!priceResp.ok) {
    throw new Error(`CoinGecko price fetch failed: ${priceResp.status} ${priceResp.statusText}`);
  }

  const priceData = await priceResp.json() as { ethereum?: { usd?: number } };
  const ethPriceUsd = priceData?.ethereum?.usd;
  if (!ethPriceUsd || ethPriceUsd <= 0) {
    throw new Error("Invalid ETH price received from CoinGecko");
  }

  // Fetch 1-day OHLC (1-hour candles) to estimate intra-day volatility
  // OHLC returns [[timestamp, open, high, low, close], ...]
  const ohlcResp = await fetch(
    "https://api.coingecko.com/api/v3/coins/ethereum/ohlc?vs_currency=usd&days=1",
    { signal: AbortSignal.timeout(10_000) }
  );

  let volatilityBps = 0n;

  if (ohlcResp.ok) {
    const ohlc = await ohlcResp.json() as number[][];
    if (Array.isArray(ohlc) && ohlc.length > 0) {
      // Compute daily high and low across all candles
      const highs = ohlc.map(c => c[2]);
      const lows  = ohlc.map(c => c[3]);
      const dailyHigh = Math.max(...highs);
      const dailyLow  = Math.min(...lows);
      const mid       = (dailyHigh + dailyLow) / 2;

      if (mid > 0) {
        // Volatility = (high - low) / mid, expressed in basis points (1 bps = 0.01%)
        const volatilityDecimal = (dailyHigh - dailyLow) / mid;
        volatilityBps = BigInt(Math.round(volatilityDecimal * 10_000));
      }
    }
  }
  // If OHLC fetch fails, proceed with volatilityBps = 0 (fee will be BASE_FEE)

  console.log(`[fetch-data] ETH/USD: $${ethPriceUsd.toLocaleString()}`);
  console.log(`[fetch-data] Volatility: ${volatilityBps} bps`);
  console.log(`[fetch-data] Observed at: ${new Date(observedAt * 1000).toISOString()}`);

  return { ethPriceUsd, volatilityBps, observedAt };
}
