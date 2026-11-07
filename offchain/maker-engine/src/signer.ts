// signer.ts — EIP-712 sign the RFQOrder using viem
// Domain and type hash must match RFQExecutor exactly.

import { createWalletClient, http, type WalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { CONFIG } from "./config.js";
import type { RFQOrder } from "./rfq.js";

// EIP-712 typed data definition matching RFQExecutor.ORDER_TYPEHASH
const RFQ_ORDER_TYPE = {
  RFQOrder: [
    { name: "strategyId",       type: "bytes32"  },
    { name: "maker",            type: "address"  },
    { name: "taker",            type: "address"  },
    { name: "tokenIn",          type: "address"  },
    { name: "tokenOut",         type: "address"  },
    { name: "quoteAmountIn",    type: "uint256"  },
    { name: "exactAmountOut",   type: "uint256"  },
    { name: "minMakerProceeds", type: "uint256"  },
    { name: "maxSlippageBps",   type: "uint256"  },
    { name: "expiry",           type: "uint256"  },
    { name: "nonce",            type: "uint256"  },
    { name: "adapter",          type: "address"  },
    { name: "routeHash",        type: "bytes32"  },
  ],
} as const;

export interface SignedOrder {
  order:     RFQOrder;
  signature: `0x${string}`;
  signer:    `0x${string}`;
  digest:    `0x${string}`;
}

export async function signOrder(
  order: RFQOrder,
  executorAddress: `0x${string}`
): Promise<SignedOrder> {
  const account = privateKeyToAccount(CONFIG.MAKER_PRIVATE_KEY);

  const domain = {
    name:              CONFIG.EIP712_NAME,
    version:           CONFIG.EIP712_VERSION,
    chainId:           Number(CONFIG.CHAIN_ID),
    verifyingContract: executorAddress,
  };

  // viem signTypedData produces the EIP-712 signature
  const client: WalletClient = createWalletClient({
    account,
    chain:     baseSepolia,
    transport: http(CONFIG.RPC_URL),
  });

  const signature = await client.signTypedData({
    account,
    domain,
    types:       RFQ_ORDER_TYPE,
    primaryType: "RFQOrder",
    message: {
      strategyId:       order.strategyId,
      maker:            order.maker,
      taker:            order.taker,
      tokenIn:          order.tokenIn,
      tokenOut:         order.tokenOut,
      quoteAmountIn:    order.quoteAmountIn,
      exactAmountOut:   order.exactAmountOut,
      minMakerProceeds: order.minMakerProceeds,
      maxSlippageBps:   order.maxSlippageBps,
      expiry:           order.expiry,
      nonce:            order.nonce,
      adapter:          order.adapter,
      routeHash:        order.routeHash,
    },
  });

  // Compute the digest for logging / test verification
  const { hashTypedData } = await import("viem");
  const digest = hashTypedData({
    domain,
    types:       RFQ_ORDER_TYPE,
    primaryType: "RFQOrder",
    message: {
      strategyId:       order.strategyId,
      maker:            order.maker,
      taker:            order.taker,
      tokenIn:          order.tokenIn,
      tokenOut:         order.tokenOut,
      quoteAmountIn:    order.quoteAmountIn,
      exactAmountOut:   order.exactAmountOut,
      minMakerProceeds: order.minMakerProceeds,
      maxSlippageBps:   order.maxSlippageBps,
      expiry:           order.expiry,
      nonce:            order.nonce,
      adapter:          order.adapter,
      routeHash:        order.routeHash,
    },
  });

  return { order, signature, signer: account.address, digest };
}
