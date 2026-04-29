import { Transaction } from "@mysten/sui/transactions";
import { getClient, waitForTx, withRetry } from "./client.js";
import { gasBudget, getIndexId, getPackageId, getSigner, getTransferCapId } from "./config.js";
import { extractGas, formatMist, saveResults, summarize, type GasBreakdown, type ScenarioResult } from "./gas.js";

const SCALE = 1_000_000;
const RUNS_PER_SCENARIO = 3;

let globalOffset = Math.floor(Math.random() * 100_000) * 100;
function nextOffset(): number {
  globalOffset += 100;
  return globalOffset;
}

function makeSquare(x: number, y: number, size: number) {
  return {
    xs: [[x * SCALE, (x + size) * SCALE, (x + size) * SCALE, x * SCALE]],
    ys: [[y * SCALE, y * SCALE, (y + size) * SCALE, (y + size) * SCALE]],
  };
}

function makeNgon(cx: number, cy: number, n: number) {
  const minRadius = Math.ceil(SCALE / (2 * Math.sin(Math.PI / n))) + SCALE;
  const xs: number[] = [];
  const ys: number[] = [];
  for (let i = 0; i < n; i++) {
    const angle = (2 * Math.PI * i) / n;
    xs.push(Math.round(cx * SCALE + minRadius * Math.cos(angle)));
    ys.push(Math.round(cy * SCALE + minRadius * Math.sin(angle)));
  }
  return { xs: [xs], ys: [ys] };
}

async function exec(buildTx: (tx: Transaction) => void): Promise<{
  gas: GasBreakdown | null;
  status: "success" | "error";
  error?: string;
  txDigest?: string;
}> {
  const client = getClient();
  const signer = getSigner();
  const tx = new Transaction();
  buildTx(tx);
  tx.setGasBudget(gasBudget);
  tx.setSender(signer.toSuiAddress());

  try {
    const result = await withRetry(() =>
      client.signAndExecuteTransaction({
        transaction: tx,
        signer,
        options: { showEffects: true, showObjectChanges: true },
      }),
    );

    if (result.effects?.status?.status === "failure") {
      const err = result.effects.status.error || "Transaction aborted";
      const gas = result.effects?.gasUsed ? extractGas(result.effects.gasUsed) : null;
      return { gas, status: "error", error: err, txDigest: result.digest };
    }

    await waitForTx(client, result.digest);
    const gas = result.effects?.gasUsed ? extractGas(result.effects.gasUsed) : null;
    return { gas, status: "success", txDigest: result.digest };
  } catch (err: unknown) {
    return { gas: null, status: "error", error: err instanceof Error ? err.message : String(err) };
  }
}

async function scenario(name: string, buildTx: () => (tx: Transaction) => void, runs = RUNS_PER_SCENARIO): Promise<ScenarioResult> {
  const result: ScenarioResult = { name, runs: [] };
  process.stdout.write(`  ${name} (${runs}x)...`);

  for (let i = 0; i < runs; i++) {
    const r = await exec(buildTx());
    result.runs.push(r);
    process.stdout.write(r.status === "success" ? " ✓" : " ✗");
  }

  summarize(result);
  if (result.summary) {
    const s = result.summary;
    console.log(` → compute=${formatMist(s.median.computationCost)} storage=${formatMist(s.median.storageCost)} net=${formatMist(s.median.netCost)}`);
  } else {
    console.log(" → ALL FAILED");
  }
  return result;
}

async function main() {
  const pkg = getPackageId();
  const indexId = getIndexId();
  const transferCapId = getTransferCapId();
  const sender = getSigner().toSuiAddress();
  const results: ScenarioResult[] = [];

  console.log(`Package:     ${pkg}`);
  console.log(`Index:       ${indexId}`);
  console.log(`TransferCap: ${transferCapId}`);
  console.log(`Sender:      ${sender}`);
  console.log(`Runs/scenario: ${RUNS_PER_SCENARIO}\n`);

  // ─── 1. Vertex scaling: 4, 8, 16, 32 ───
  console.log("=== Vertex Scaling (SAT complexity) ===\n");
  for (const n of [4, 8, 16, 32, 64]) {
    results.push(await scenario(`register_${n}v`, () => {
      const off = nextOffset();
      const poly = makeNgon(off, 50, n);
      return (tx) => {
        tx.moveCall({
          target: `${pkg}::index::register`,
          arguments: [tx.object(indexId), tx.pure.vector("vector<u64>", poly.xs), tx.pure.vector("vector<u64>", poly.ys)],
        });
      };
    }));
  }

  // ─── 2. Index density: register N regions, measure last ───
  console.log("\n=== Index Density (cost vs index size) ===\n");
  const densityResults: ScenarioResult = { name: "density_series", runs: [] };
  let regionCount = 0;
  for (let i = 0; i < 20; i++) {
    const off = nextOffset();
    const sq = makeSquare(off, 0, 1);
    const r = await exec((tx) => {
      tx.moveCall({
        target: `${pkg}::index::register`,
        arguments: [tx.object(indexId), tx.pure.vector("vector<u64>", sq.xs), tx.pure.vector("vector<u64>", sq.ys)],
      });
    });
    regionCount++;
    if (r.status === "success") {
      densityResults.runs.push(r);
      if ([1, 5, 10, 15, 20].includes(i + 1)) {
        console.log(`  region #${regionCount}: compute=${formatMist(r.gas!.computationCost)} storage=${formatMist(r.gas!.storageCost)} net=${formatMist(r.gas!.netCost)}`);
      }
    } else {
      console.log(`  region #${regionCount}: FAILED — ${r.error?.slice(0, 80)}`);
    }
  }
  summarize(densityResults);
  results.push(densityResults);

  // ─── 3. Read operations ───
  console.log("\n=== Read Operations ===\n");
  results.push(await scenario("count", () => (tx) => {
    tx.moveCall({ target: `${pkg}::index::count`, arguments: [tx.object(indexId)] });
  }));

  // ─── 4. Remove ───
  console.log("\n=== Remove ===\n");
  // Register a region, then remove it
  const removeOff = nextOffset();
  const removeSq = makeSquare(removeOff, 200, 1);
  const regResult = await exec((tx) => {
    tx.moveCall({
      target: `${pkg}::index::register`,
      arguments: [tx.object(indexId), tx.pure.vector("vector<u64>", removeSq.xs), tx.pure.vector("vector<u64>", removeSq.ys)],
    });
  });
  if (regResult.status === "success" && regResult.txDigest) {
    // Get the polygon ID from the Registered event
    const client = getClient();
    const txData = await client.getTransactionBlock({ digest: regResult.txDigest, options: { showEvents: true } });
    const regEvent = txData.events?.find((e: any) => e.type.includes("::index::Registered"));
    const polygonId = (regEvent?.parsedJson as any)?.polygon_id;
    if (polygonId) {
      results.push(await scenario("remove", () => {
        // Register fresh then remove
        return (tx) => {
          const freshOff = nextOffset();
          const sq = makeSquare(freshOff, 200, 1);
          // Can't register+remove in same PTB easily, so just measure remove of existing
          tx.moveCall({
            target: `${pkg}::index::remove`,
            arguments: [tx.object(indexId), tx.pure.id(polygonId)],
          });
        };
      }, 1));
    }
  }

  // ─── 5. Transfer ownership ───
  console.log("\n=== Transfer Ownership ===\n");
  const xferOff = nextOffset();
  const xferSq = makeSquare(xferOff, 300, 1);
  const xferReg = await exec((tx) => {
    tx.moveCall({
      target: `${pkg}::index::register`,
      arguments: [tx.object(indexId), tx.pure.vector("vector<u64>", xferSq.xs), tx.pure.vector("vector<u64>", xferSq.ys)],
    });
  });
  if (xferReg.status === "success" && xferReg.txDigest) {
    const client = getClient();
    const txData = await client.getTransactionBlock({ digest: xferReg.txDigest, options: { showEvents: true } });
    const regEvent = txData.events?.find((e: any) => e.type.includes("::index::Registered"));
    const polygonId = (regEvent?.parsedJson as any)?.polygon_id;
    if (polygonId) {
      results.push(await scenario("transfer_ownership", () => (tx) => {
        tx.moveCall({
          target: `${pkg}::index::transfer_ownership`,
          arguments: [tx.object(indexId), tx.pure.id(polygonId), tx.pure.address(sender)],
        });
      }, 1));

      results.push(await scenario("force_transfer", () => (tx) => {
        tx.moveCall({
          target: `${pkg}::index::force_transfer`,
          arguments: [tx.object(transferCapId), tx.object(indexId), tx.pure.id(polygonId), tx.pure.address(sender)],
        });
      }, 1));
    }
  }

  // ─── Summary table ───
  console.log("\n\n=== RESULTS TABLE (raw MIST, no rounding) ===\n");
  console.log("| Scenario | Runs | Compute (median) | Storage (median) | Net (median) | Net (min) | Net (max) |");
  console.log("|----------|------|------------------|------------------|--------------|-----------|-----------|");
  for (const r of results) {
    if (r.summary) {
      const s = r.summary;
      console.log(`| ${r.name} | ${s.count} | ${formatMist(s.median.computationCost)} | ${formatMist(s.median.storageCost)} | ${formatMist(s.median.netCost)} | ${formatMist(s.min.netCost)} | ${formatMist(s.max.netCost)} |`);
    } else {
      console.log(`| ${r.name} | 0 | — | — | — | — | — |`);
    }
  }

  saveResults({
    timestamp: new Date().toISOString(),
    protocol_version: "testnet",
    packageId: pkg,
    indexId,
    runsPerScenario: RUNS_PER_SCENARIO,
    results,
  });
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
