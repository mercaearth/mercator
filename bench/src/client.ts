import { SuiJsonRpcClient as CoreClient } from "@mysten/sui/jsonRpc";
import { rpcUrl } from "./config.js";

let clientSingleton: CoreClient | null = null;

export function getClient(): CoreClient {
  if (!clientSingleton) {
    clientSingleton = new CoreClient({ network: "testnet", url: rpcUrl });
  }
  return clientSingleton;
}

export async function withRetry<T>(
  fn: () => Promise<T>,
  maxRetries = 5,
  backoffMs = 1000,
): Promise<T> {
  let lastError: unknown;

  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    try {
      return await fn();
    } catch (err: unknown) {
      lastError = err;
      if (attempt === maxRetries) {
        break;
      }

      const msg = err instanceof Error ? err.message : String(err);
      const isRetryable =
        msg.includes("timeout") ||
        msg.includes("429") ||
        msg.includes("503") ||
        msg.includes("fetch failed");

      if (!isRetryable) {
        throw err;
      }

      const delay = backoffMs * Math.pow(2, attempt);
      console.warn(
        `  Retry ${attempt + 1}/${maxRetries}: ${msg.slice(0, 80)}. Wait ${delay}ms...`,
      );
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }

  throw lastError;
}

export async function waitForTx(
  client: CoreClient,
  digest: string,
  maxRetries = 10,
): Promise<void> {
  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    try {
      await client.waitForTransaction({ digest });
      return;
    } catch {
      if (attempt === maxRetries) {
        throw new Error(`Tx ${digest} not confirmed`);
      }
      await new Promise((resolve) => setTimeout(resolve, 500 * Math.pow(2, attempt)));
    }
  }
}
