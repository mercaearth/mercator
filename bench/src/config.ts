import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { config as dotenvConfig } from "dotenv";

dotenvConfig();

export const rpcUrl = process.env.SUI_RPC_URL ?? "https://fullnode.testnet.sui.io";
export const gasBudget = 500_000_000;

export function getSigner(): Ed25519Keypair {
  const key = process.env.SUI_PRIVATE_KEY;
  if (!key) {
    throw new Error("SUI_PRIVATE_KEY required in .env");
  }

  if (key.startsWith("suiprivkey")) {
    return Ed25519Keypair.fromSecretKey(key);
  }

  const raw = Buffer.from(key, "base64");
  const secretKey = raw.length === 33 ? raw.subarray(1) : raw.length === 64 ? raw.subarray(0, 32) : raw;
  return Ed25519Keypair.fromSecretKey(new Uint8Array(secretKey) as never);
}

export function getPackageId(): string {
  const id = process.env.PACKAGE_ID;
  if (!id) {
    throw new Error("PACKAGE_ID required in .env. Run `npm run publish` first.");
  }
  return id;
}

export function getIndexId(): string {
  const id = process.env.INDEX_ID;
  if (!id) {
    throw new Error("INDEX_ID required in .env. Run `npm run publish` first.");
  }
  return id;
}

export function getTransferCapId(): string {
  const id = process.env.TRANSFER_CAP_ID;
  if (!id) {
    throw new Error("TRANSFER_CAP_ID required in .env. Run `npm run publish` first.");
  }
  return id;
}
