"use client";

import { useEffect, useState } from "react";
import { useDeployment } from "@/lib/DeploymentProvider";

// One-line safety verdict from the deployed subgraph
// (Subgraph Studio `ethonline` v0.4.0) -- worst status across the maker's
// positions, exposure vs thresholds, cross-venue coverage, latest swap.
// Same reasoning as the MCP `maker_safety_verdict` tool. Refreshes every 15s.
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1758739/ethonline/v0.4.0";

interface PositionRow {
  strategyHash: string;
  venues: string[];
  exposureBps: string;
  status: string;
  isPausedByMaker: boolean;
}

interface SwapRow {
  pool: { id: string; name: string | null };
  tokenIn: { symbol: string };
  amountIn: string;
  tokenOut: { symbol: string };
  amountOut: string;
}

const RANK: Record<string, number> = { SAFE: 1, DERATED: 2, HALTED: 3, PAUSED: 4 };

const VERDICT_STYLE: Record<string, string> = {
  SAFE: "bg-emerald-500/10 text-emerald-400",
  DERATED: "bg-amber-500/10 text-amber-400",
  HALTED: "bg-red-500/10 text-red-400",
  PAUSED: "bg-neutral-500/10 text-neutral-300",
  UNKNOWN: "bg-neutral-500/10 text-neutral-500",
};

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

export function GraphVerdictBanner() {
  const { deployment } = useDeployment();
  const [verdict, setVerdict] = useState<string | null>(null);
  const [summary, setSummary] = useState<string>("");
  const [coverage, setCoverage] = useState<{ cross: number; total: number }>({ cross: 0, total: 0 });
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function fetchGraph() {
      const query = `{
        exposurePositions(where: { maker: "${deployment!.maker.toLowerCase()}" }) {
          strategyHash venues exposureBps status isPausedByMaker
        }
        swaps(first: 1, orderBy: blockNumber, orderDirection: desc) {
          pool { id name } tokenIn { symbol } amountIn tokenOut { symbol } amountOut
        }
      }`;
      try {
        const res = await fetch(SUBGRAPH_URL, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ query }),
        });
        if (!res.ok) throw new Error(`subgraph HTTP ${res.status}`);
        const body = await res.json();
        if (body.errors) throw new Error(JSON.stringify(body.errors).slice(0, 200));
        if (cancelled) return;
        const rows = body.data.exposurePositions as PositionRow[];
        const swaps = body.data.swaps as SwapRow[];
        if (rows.length === 0) {
          setVerdict("UNKNOWN");
          setSummary("No positions indexed for this maker yet.");
          setCoverage({ cross: 0, total: 0 });
        } else {
          let worst = "SAFE";
          let worstRank = 0;
          let maxExposure = 0;
          let pausedAny = false;
          let cross = 0;
          for (const r of rows) {
            const rank = RANK[r.status] ?? 0;
            if (rank > worstRank) {
              worstRank = rank;
              worst = r.status;
            }
            maxExposure = Math.max(maxExposure, Number(r.exposureBps) || 0);
            if (r.isPausedByMaker) pausedAny = true;
            if (r.venues.includes("uniswap-v4")) cross += 1;
          }
          const last = swaps[0];
          setVerdict(worst);
          setSummary(
            `${(maxExposure / 100).toFixed(1)}% exposure, ${cross}/${rows.length} positions cross-venue` +
              (pausedAny ? ", maker pause active" : "") +
              (last ? `, last swap ${fmt18(last.amountIn)} ${last.tokenIn.symbol} → ${fmt18(last.amountOut)} ${last.tokenOut.symbol}` : "")
          );
          setCoverage({ cross, total: rows.length });
        }
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
  }, [deployment]);

  if (!deployment) return null;

  const pct = coverage.total > 0 ? Math.round((coverage.cross / coverage.total) * 100) : 0;

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <div className="flex flex-wrap items-center gap-3">
        <h2 className="text-base font-semibold">Maker safety</h2>
        {verdict && (
          <span className={`inline-block rounded-full px-2 py-0.5 text-[11px] ${VERDICT_STYLE[verdict] ?? ""}`}>
            {verdict}
          </span>
        )}
        {error && <span className="text-xs text-red-400">Subgraph query failed: {error}</span>}
        {!verdict && !error && <span className="text-xs text-neutral-500">Loading from subgraph…</span>}
      </div>
      {verdict && (
        <>
          <p className="mt-2 text-xs text-neutral-400">{summary}</p>
          <div className="mt-3">
            <div className="h-1.5 w-full overflow-hidden rounded-full bg-neutral-800">
              <div className="h-full rounded-full bg-sky-500" style={{ width: `${pct}%` }} />
            </div>
            <p className="mt-1 text-[11px] text-neutral-500">
              Cross-venue coverage: {coverage.cross}/{coverage.total} strategies fill on SwapVM and Uniswap v4
            </p>
          </div>
        </>
      )}
    </div>
  );
}
