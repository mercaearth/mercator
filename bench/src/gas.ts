import { existsSync, mkdirSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = join(__dirname, "..", "results");

export interface GasBreakdown {
  computationCost: string;
  storageCost: string;
  storageRebate: string;
  netCost: string;
}

export function extractGas(gasUsed: {
  computationCost: string;
  storageCost: string;
  storageRebate: string;
}): GasBreakdown {
  const computation = BigInt(gasUsed.computationCost);
  const storage = BigInt(gasUsed.storageCost);
  const rebate = BigInt(gasUsed.storageRebate);
  const net = computation + storage - rebate;
  return {
    computationCost: gasUsed.computationCost,
    storageCost: gasUsed.storageCost,
    storageRebate: gasUsed.storageRebate,
    netCost: net.toString(),
  };
}

/** Raw MIST number — no rounding. Shows actual cost. */
export function rawMist(mist: string): string {
  return BigInt(mist).toLocaleString("en-US");
}

/** Compact display: e.g. "1,000,000" or "9,400,800" */
export function formatMist(mist: string): string {
  return rawMist(mist);
}

export interface ScenarioResult {
  name: string;
  runs: Array<{
    gas: GasBreakdown | null;
    status: "success" | "error";
    error?: string;
    txDigest?: string;
  }>;
  summary?: {
    median: GasBreakdown;
    min: GasBreakdown;
    max: GasBreakdown;
    count: number;
  };
}

/** Compute median/min/max from successful runs */
export function summarize(result: ScenarioResult): void {
  const successful = result.runs.filter(r => r.status === "success" && r.gas);
  if (successful.length === 0) return;

  const nets = successful.map(r => BigInt(r.gas!.netCost));
  const computes = successful.map(r => BigInt(r.gas!.computationCost));
  const storages = successful.map(r => BigInt(r.gas!.storageCost));

  nets.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  computes.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  storages.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

  const mid = Math.floor(nets.length / 2);

  result.summary = {
    count: successful.length,
    median: {
      computationCost: computes[mid].toString(),
      storageCost: storages[mid].toString(),
      storageRebate: "0",
      netCost: nets[mid].toString(),
    },
    min: {
      computationCost: computes[0].toString(),
      storageCost: storages[0].toString(),
      storageRebate: "0",
      netCost: nets[0].toString(),
    },
    max: {
      computationCost: computes[computes.length - 1].toString(),
      storageCost: storages[storages.length - 1].toString(),
      storageRebate: "0",
      netCost: nets[nets.length - 1].toString(),
    },
  };
}

export function saveResults(data: unknown): string {
  if (!existsSync(RESULTS_DIR)) mkdirSync(RESULTS_DIR, { recursive: true });
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const filename = `bench-${ts}.json`;
  const filepath = join(RESULTS_DIR, filename);
  writeFileSync(filepath, JSON.stringify(data, null, 2) + "\n");
  console.log(`\nResults saved to: results/${filename}`);
  return filepath;
}
