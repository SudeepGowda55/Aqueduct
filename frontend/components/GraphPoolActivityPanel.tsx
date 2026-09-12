"use client";

import { useEffect, useState } from "react";

// Pool activity straight from the deployed subgraph
// (Subgraph Studio `ethonline` v0.4.0) in trimmed Messari DEX-AMM shape --
// the same `liquidityPools { swaps { tokenIn amountIn ... } }` pattern that
// works against any real Messari-standardized DEX subgraph returns real rows
// here. No RPC calls on this panel. Refreshes every 15s.
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1758739/ethonline/v0.4.0";

interface PoolRow {
  id: string;
  name: string | null;
  inputTokens: { id: string; symbol: string; name: string; decimals: number }[];
}

interface SwapRow {
  id: string;
  hash: string;
  pool: { id: string; name: string | null };
  tokenIn: { symbol: string };
  amountIn: string;
  tokenOut: { symbol: string };
  amountOut: string;
  blockNumber: string;
  timestamp: string;
}

const QUERY = `{
  liquidityPools {
    id name cumulativeVolumeUSD
    inputTokens { id symbol name decimals }
  }
  swaps(first: 20, orderBy: blockNumber, orderDirection: desc) {
    id hash blockNumber timestamp
    pool { id name }
    tokenIn { symbol } amountIn
    tokenOut { symbol } amountOut
  }
  swapStats: swaps(first: 1000) { pool { id } }
}`;

const PROOF_QUERY = `{
  liquidityPools {
    id
    inputTokens { symbol }
    swaps(first: 5, orderBy: blockNumber, orderDirection: desc) {
      tokenIn { symbol }
      amountIn
      tokenOut { symbol }
      amountOut
    }
  }
}`;

function fmt18(raw: string): string {
  try {
    const v = BigInt(raw);
    const whole = v / 10n ** 18n;
    const frac = ((v % 10n ** 18n) / 10n ** 16n).toString().padStart(2, "0");
    return `${whole.toLocaleString("en-US")}.${frac}`;
  } catch {
    return raw;
  }
}

function fmtTime(ts: string): string {
  const ms = Number(ts) * 1000;
  if (!Number.isFinite(ms)) return ts;
  return new Date(ms).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function GraphPoolActivityPanel() {
  const [pools, setPools] = useState<PoolRow[] | null>(null);
  const [swaps, setSwaps] = useState<SwapRow[] | null>(null);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function fetchGraph() {
      try {
        const res = await fetch(SUBGRAPH_URL, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ query: QUERY }),
        });
        if (!res.ok) throw new Error(`subgraph HTTP ${res.status}`);
        const body = await res.json();
        if (body.errors) throw new Error(JSON.stringify(body.errors).slice(0, 200));
        if (cancelled) return;
        setPools(body.data.liquidityPools);
        setSwaps(body.data.swaps);
        const tally: Record<string, number> = {};
        for (const s of body.data.swapStats as { pool: { id: string } }[]) {
          tally[s.pool.id] = (tally[s.pool.id] ?? 0) + 1;
        }
        setCounts(tally);
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    }

    const interval = setInterval(fetchGraph, 15000);
    fetchGraph();
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h2 className="text-base font-semibold">Pool activity, from The Graph (Messari shape)</h2>
      <p className="mt-1 text-xs text-neutral-500">
        <span className="font-mono">liquidityPools</span> + <span className="font-mono">swaps</span> in
        Messari DEX-AMM field names — the same query pattern works against any standardized DEX
        subgraph. No RPC calls on this panel. Refreshes every 15s.
      </p>
      {error && <p className="mt-3 text-sm text-red-400">Subgraph query failed: {error}</p>}
      {!pools && !error && <p className="mt-3 text-sm text-neutral-500">Loading from subgraph…</p>}

      {pools && (
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          {pools.map((p) => (
            <div key={p.id} className="rounded-lg bg-neutral-950 p-3">
              <p className="text-xs font-medium text-neutral-200">{p.name ?? p.id.slice(0, 10)}</p>
              <p className="mt-1 font-mono text-[11px] text-neutral-500">
                {p.inputTokens.map((t) => t.symbol).join(" / ")} ·{" "}
                <span className="text-sky-400">{counts[p.id] ?? 0} indexed swaps</span>
              </p>
              <p className="mt-1 font-mono text-[11px] text-neutral-600">{p.id.slice(0, 18)}…</p>
            </div>
          ))}
        </div>
      )}

      {swaps && swaps.length > 0 && (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead>
              <tr className="text-neutral-500">
                <th className="py-1 pr-3 font-medium">Time</th>
                <th className="py-1 pr-3 font-medium">Pool</th>
                <th className="py-1 pr-3 text-right font-medium">In</th>
                <th className="py-1 pr-3 text-right font-medium">Out</th>
                <th className="py-1 font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              {swaps.map((s) => (
                <tr key={s.id} className="border-t border-neutral-800">
                  <td className="py-2 pr-3 text-neutral-400">{fmtTime(s.timestamp)}</td>
                  <td className="py-2 pr-3 text-neutral-300">{(s.pool.name ?? s.pool.id).split(" / ")[0]}</td>
                  <td className="py-2 pr-3 text-right font-mono">
                    {fmt18(s.amountIn)} {s.tokenIn.symbol}
                  </td>
                  <td className="py-2 pr-3 text-right font-mono">
                    {fmt18(s.amountOut)} {s.tokenOut.symbol}
                  </td>
                  <td className="py-2">
                    <a
                      className="font-mono text-sky-400 hover:underline"
                      href={`https://sepolia.basescan.org/tx/${s.hash}`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {s.hash.slice(0, 10)}…
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <details className="mt-4 rounded-lg bg-neutral-950 p-3">
        <summary className="cursor-pointer text-xs text-neutral-400">
          Standards proof — paste this into any Messari DEX subgraph, same shape back
        </summary>
        <pre className="mt-2 overflow-x-auto font-mono text-[11px] leading-relaxed text-neutral-300">
          {PROOF_QUERY}
        </pre>
      </details>
    </div>
  );
}
