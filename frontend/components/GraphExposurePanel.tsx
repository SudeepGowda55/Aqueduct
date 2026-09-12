"use client";

import { useEffect, useState } from "react";
import { useDeployment } from "@/lib/DeploymentProvider";

// Everything on this panel comes from the deployed subgraph
// (Subgraph Studio `ethonline` v0.3.0) -- not from RPC reads. The subgraph
// joins Aqua commitments, ExposureOracle readings and v4 swaps into one
// ExposurePosition per (maker, strategy), so this is a single GraphQL query,
// not N contract calls.
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1758739/ethonline/v0.3.0";

interface PositionRow {
  strategyHash: string;
  venues: string[];
  committedAmount: string;
  makerWalletBalance: string;
  exposureBps: string;
  maxExposureBps: string;
  haltExposureBps: string;
  status: string;
  isPausedByMaker: boolean;
  updatedAt: string;
}

interface SnapshotRow {
  exposureBps: string;
  status: string;
  blockNumber: string;
  blockTimestamp: string;
}

const STATUS_STYLE: Record<string, string> = {
  SAFE: "bg-emerald-500/10 text-emerald-400",
  DERATED: "bg-amber-500/10 text-amber-400",
  HALTED: "bg-red-500/10 text-red-400",
  PAUSED: "bg-neutral-500/10 text-neutral-300",
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

export function GraphExposurePanel() {
  const { deployment } = useDeployment();
  const [positions, setPositions] = useState<PositionRow[] | null>(null);
  const [snapshots, setSnapshots] = useState<SnapshotRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function fetchGraph() {
      const query = `{
        exposurePositions(where: { maker: "${deployment!.maker.toLowerCase()}" }) {
          strategyHash venues committedAmount makerWalletBalance
          exposureBps maxExposureBps haltExposureBps status isPausedByMaker updatedAt
        }
        exposureSnapshots(first: 60, orderBy: blockNumber, orderDirection: asc) {
          exposureBps status blockNumber blockTimestamp
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
        setPositions(body.data.exposurePositions);
        setSnapshots(body.data.exposureSnapshots);
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

  const crossVenue = (positions ?? []).filter((p) => p.venues.includes("uniswap-v4"));
  const points = (snapshots ?? []).map((s) => Number(s.exposureBps));
  const maxY = Math.max(10000, ...points);
  const spark =
    points.length > 1
      ? points
          .map((v, i) => `${(i / (points.length - 1)) * 100},${100 - (v / maxY) * 96}`)
          .join(" ")
      : "";

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h2 className="text-base font-semibold">Exposure, from The Graph</h2>
      <p className="mt-1 text-xs text-neutral-500">
        One <span className="font-mono">exposurePositions</span> query against the deployed subgraph joins Aqua
        commitments, oracle readings and v4 swaps — no RPC calls on this panel. Refreshes every 15s.
      </p>
      {error && <p className="mt-3 text-sm text-red-400">Subgraph query failed: {error}</p>}
      {!positions && !error && <p className="mt-3 text-sm text-neutral-500">Loading from subgraph…</p>}

      {positions && (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead>
              <tr className="text-neutral-500">
                <th className="py-1 pr-3 font-medium">Strategy</th>
                <th className="py-1 pr-3 font-medium">Venues</th>
                <th className="py-1 pr-3 text-right font-medium">Committed</th>
                <th className="py-1 pr-3 text-right font-medium">Exposure</th>
                <th className="py-1 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {positions.map((p) => (
                <tr key={p.strategyHash} className="border-t border-neutral-800">
                  <td className="py-2 pr-3 font-mono">{p.strategyHash.slice(0, 10)}…</td>
                  <td className="py-2 pr-3">
                    {p.venues.map((v) => (
                      <span
                        key={v}
                        className={`mr-1 inline-block rounded-full px-2 py-0.5 text-[11px] ${
                          v === "uniswap-v4" ? "bg-sky-500/10 text-sky-400" : "bg-neutral-500/10 text-neutral-300"
                        }`}
                      >
                        {v}
                      </span>
                    ))}
                  </td>
                  <td className="py-2 pr-3 text-right font-mono">{fmt18(p.committedAmount)}</td>
                  <td className="py-2 pr-3 text-right font-mono">{(Number(p.exposureBps) / 100).toFixed(1)}%</td>
                  <td className="py-2">
                    <span className={`inline-block rounded-full px-2 py-0.5 text-[11px] ${STATUS_STYLE[p.status] ?? ""}`}>
                      {p.status}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {crossVenue.length > 0 && (
        <p className="mt-3 text-xs text-neutral-400">
          Cross-venue positions (same strategy fills on SwapVM <em>and</em> Uniswap v4):{" "}
          <span className="font-mono">{crossVenue.map((p) => p.strategyHash.slice(0, 10)).join(", ")}</span>
        </p>
      )}

      {spark && (
        <div className="mt-4">
          <p className="text-xs text-neutral-500">
            Exposure history ({snapshots!.length} indexed readings, oldest → latest)
          </p>
          <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="mt-1 h-20 w-full rounded-lg bg-neutral-950 p-1">
            <polyline points={spark} fill="none" stroke="#38bdf8" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
          </svg>
        </div>
      )}
    </div>
  );
}
