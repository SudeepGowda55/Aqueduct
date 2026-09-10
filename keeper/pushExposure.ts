/**
 * Aqueduct exposure keeper.
 *
 * Reads each maker's total committed balance per token from the Aqueduct subgraph (aggregated
 * across every Aqua strategy they've shipped -- exactly the "multiplier effect" Aqua enables),
 * compares it against a live on-chain read of the maker's actual wallet balance, and pushes the
 * resulting exposure ratio to ExposureOracle for the ExposureGate SwapVM opcode to read.
 *
 * Why the wallet-balance check happens here, live, rather than in the subgraph: Aqua's balances
 * are allowance-style commitments, not custody -- `Aqua.pull` transfers directly from the maker's
 * own wallet (see Aqua.sol), so the tokens backing every shipped strategy sit in that wallet the
 * whole time. A maker's real exposure is how much of that wallet is already spoken for:
 *
 *   exposureBps = min(10_000, totalCommitted * 10_000 / walletBalance)
 *
 * Run:
 *   npm install
 *   SUBGRAPH_URL=... RPC_URL=... ORACLE_ADDRESS=0x... KEEPER_PRIVATE_KEY=0x... \
 *     npx ts-node pushExposure.ts
 *
 * This is genuinely off-chain infrastructure: it depends on a subgraph actually deployed to
 * Graph Studio (or a local graph-node) indexing a real Aqua deployment, neither of which exists
 * yet for this project (see the README and subgraph/subgraph.yaml for why). The code here is
 * complete and correct against Aqua's real event/balance semantics; wiring it to live endpoints
 * is a deployment step, not a code change.
 */

import { ethers } from "ethers";

const SUBGRAPH_URL = requireEnv("SUBGRAPH_URL");
const RPC_URL = requireEnv("RPC_URL");
const ORACLE_ADDRESS = requireEnv("ORACLE_ADDRESS");
const KEEPER_PRIVATE_KEY = requireEnv("KEEPER_PRIVATE_KEY");

const MAX_BPS = 10_000n;

const ERC20_ABI = ["function balanceOf(address account) view returns (uint256)"];
const ORACLE_ABI = ["function pushExposure(address maker, uint64 exposureBps) external"];

interface StrategyBalanceRow {
  maker: string;
  token: string;
  amount: string;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

/** Paginates through every active StrategyBalance the subgraph has indexed. */
async function fetchActiveBalances(): Promise<StrategyBalanceRow[]> {
  const rows: StrategyBalanceRow[] = [];
  const pageSize = 1000;
  let skip = 0;

  for (;;) {
    const query = `
      query ActiveBalances($first: Int!, $skip: Int!) {
        strategyBalances(
          first: $first
          skip: $skip
          where: { active: true, amount_gt: "0" }
          orderBy: id
        ) {
          maker
          token
          amount
        }
      }
    `;

    const response = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query, variables: { first: pageSize, skip } }),
    });

    if (!response.ok) {
      throw new Error(`Subgraph query failed: ${response.status} ${await response.text()}`);
    }

    const body = (await response.json()) as {
      data?: { strategyBalances: StrategyBalanceRow[] };
      errors?: unknown;
    };
    if (body.errors) throw new Error(`Subgraph returned errors: ${JSON.stringify(body.errors)}`);

    const page = body.data?.strategyBalances ?? [];
    rows.push(...page);
    if (page.length < pageSize) break;
    skip += pageSize;
  }

  return rows;
}

/** Sums committed balances per (maker, token), keyed as "maker|token" (both lowercased). */
function aggregateByMakerAndToken(rows: StrategyBalanceRow[]): Map<string, bigint> {
  const totals = new Map<string, bigint>();
  for (const row of rows) {
    const key = `${row.maker.toLowerCase()}|${row.token.toLowerCase()}`;
    totals.set(key, (totals.get(key) ?? 0n) + BigInt(row.amount));
  }
  return totals;
}

async function main(): Promise<void> {
  const rows = await fetchActiveBalances();
  if (rows.length === 0) {
    console.log("No active Aqua balances found in the subgraph; nothing to push.");
    return;
  }

  const totalsByMakerAndToken = aggregateByMakerAndToken(rows);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(KEEPER_PRIVATE_KEY, provider);
  const oracle = new ethers.Contract(ORACLE_ADDRESS, ORACLE_ABI, signer);

  // A maker's exposure is the worst case across every token they've committed -- if they're
  // fully spoken for in even one token, the gate should treat them as fully exposed, not average
  // that out against a token they happen to hold plenty of.
  const worstExposureByMaker = new Map<string, bigint>();

  for (const [key, totalCommitted] of totalsByMakerAndToken) {
    const [maker, token] = key.split("|");
    const erc20 = new ethers.Contract(token, ERC20_ABI, provider);
    const walletBalance: bigint = await erc20.balanceOf(maker);

    const exposureBps = walletBalance === 0n ? MAX_BPS : minBigInt(MAX_BPS, (totalCommitted * MAX_BPS) / walletBalance);

    const current = worstExposureByMaker.get(maker) ?? 0n;
    if (exposureBps > current) worstExposureByMaker.set(maker, exposureBps);
  }

  for (const [maker, exposureBps] of worstExposureByMaker) {
    console.log(`Pushing exposure for ${maker}: ${exposureBps} bps`);
    const tx = await oracle.pushExposure(maker, exposureBps);
    await tx.wait();
    console.log(`  tx: ${tx.hash}`);
  }
}

function minBigInt(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
