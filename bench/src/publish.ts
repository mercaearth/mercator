import { appendFileSync } from "fs";
import { execSync } from "child_process";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { getSigner, gasBudget } from "./config.js";
import { getClient } from "./client.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MERCATOR_PATH = join(__dirname, "../../mercator");

interface ObjectChange {
  type?: string;
  packageId?: string;
  objectId?: string;
  objectType?: string;
}

interface PublishResult {
  objectChanges?: ObjectChange[];
}

async function main() {
  const client = getClient();
  const signer = getSigner();
  const sender = signer.toSuiAddress();

  void client;

  console.log(`Publishing mercator package from: ${MERCATOR_PATH}`);
  console.log(`Sender: ${sender}\n`);

  console.log("Building package...");
  execSync(
    `sui move build --path "${MERCATOR_PATH}" --dump-bytecode-as-base64 --build-env testnet 2>/dev/null`,
    { encoding: "utf-8" },
  );

  console.log("Publishing to testnet...");
  const publishOutput = execSync(
    `sui client publish --path "${MERCATOR_PATH}" --gas-budget ${gasBudget} --json --skip-dependency-verification 2>/dev/null`,
    { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 },
  );

  const result = JSON.parse(publishOutput) as PublishResult;
  const changes = result.objectChanges ?? [];

  const packageId = changes.find((change) => change.type === "published")?.packageId;
  const indexId = changes.find(
    (change) => change.type === "created" && change.objectType?.includes("::index::Index"),
  )?.objectId;
  const transferCapId = changes.find(
    (change) =>
      change.type === "created" && change.objectType?.includes("::index::TransferCap"),
  )?.objectId;

  if (!packageId) {
    throw new Error("Package ID not found in publish result");
  }

  console.log("\nPublished!");
  console.log(`PACKAGE_ID=${packageId}`);
  console.log(`INDEX_ID=${indexId ?? "NOT_FOUND"}`);
  console.log(`TRANSFER_CAP_ID=${transferCapId ?? "NOT_FOUND"}`);

  const envPath = join(__dirname, "..", ".env");
  const envBlock = [
    "",
    `PACKAGE_ID=${packageId}`,
    `INDEX_ID=${indexId ?? ""}`,
    `TRANSFER_CAP_ID=${transferCapId ?? ""}`,
    "",
  ].join("\n");

  appendFileSync(envPath, envBlock);
  console.log("\nAppended to .env");
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
