"use client";

import { Contract, formatUnits } from "ethers";
import { useEffect, useState } from "react";
import { AQUA_ABI, ERC20_ABI, EXPOSURE_ORACLE_ABI } from "@/lib/abis";
import { EXPOSURE_BANDS, exposureBand } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { getReadProvider } from "@/lib/readProvider";

const BAND_COPY = {
  safe: { label: EXPOSURE_BANDS.safeLabel, text: "text-emerald-400" },
  derate: { label: EXPOSURE_BANDS.derateLabel, text: "text-amber-400" },
  halt: { label: EXPOSURE_BANDS.haltLabel, text: "text-red-400" },
} as const;

interface StrategyRow {
  label: string;
  committed: bigint | null; // null = not shipped on this deployment
}

interface Snapshot {
  decimals: number;
  symbol: string;
  rows: StrategyRow[];
  totalCommitted: bigint;
  walletBalance: bigint;
  exposureBps: number;
}

/// Scene 1 of the pitch: show the problem before explaining the opcode. This is deliberately
/// honest about what's ACTUALLY shipped on this deployment rather than inventing strategies to
/// match a fixed "A/B/C" mockup -- see test/MultiStrategyExposure.t.sol for the on-chain proof of
/// the full three-strategy story, and deployment.json's `strategies` array for what this specific
/// live deployment has really shipped (currently just one). If more strategies are ever shipped
/// for real and added there, this panel picks them up automatically with no code change.
export function AggregateExposurePanel() {
  const { deployment } = useDeployment();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function compute() {
      try {
        const provider = getReadProvider();
        const aqua = new Contract(deployment!.aqua, AQUA_ABI, provider);
        const oracle = new Contract(deployment!.oracle, EXPOSURE_ORACLE_ABI, provider);
        const tokenIn = new Contract(deployment!.tokenIn, ERC20_ABI, provider);

        const shipped = deployment!.strategies ?? [{ label: "Strategy A", strategyHash: deployment!.strategyHash }];

        const [decimals, symbol, walletBalance, [exposureBps], committedAmounts] = await Promise.all([
          tokenIn.decimals(),
          tokenIn.symbol(),
          tokenIn.balanceOf(deployment!.maker),
          oracle.exposureOf(deployment!.maker),
          Promise.all(
            shipped.map(async (s) => {
              const [balanceIn] = await aqua.safeBalances(
                deployment!.maker, deployment!.swapVM, s.strategyHash, deployment!.tokenIn, deployment!.tokenOut
              );
              return balanceIn as bigint;
            })
          ),
        ]);

        const rows: StrategyRow[] = shipped.map((s, i) => ({ label: s.label, committed: committedAmounts[i] }));
        // Pad up to 3 rows with explicitly-unshipped placeholders, continuing the alphabet, so the
        // panel always shows the shape of the multiplier-effect story even on a deployment that
        // has only ever shipped one strategy -- never as fake committed amounts, only as "--".
        for (let i = rows.length; i < 3; i++) {
          rows.push({ label: `Strategy ${String.fromCharCode(65 + i)}`, committed: null });
        }

        const totalCommitted = committedAmounts.reduce((sum, v) => sum + v, 0n);

        if (cancelled) return;
        setSnapshot({ decimals: Number(decimals), symbol, rows, totalCommitted, walletBalance, exposureBps: Number(exposureBps) });
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    }

    compute();
    const interval = setInterval(compute, 8000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [deployment]);

  if (!deployment) return null;
  if (error) return <p className="text-sm text-red-400">Failed to compute aggregate exposure: {error}</p>;
  if (!snapshot) return <p className="text-sm text-neutral-500">Loading aggregate exposure...</p>;

  const informationalPct =
    snapshot.walletBalance > 0n ? Number((10_000n * snapshot.totalCommitted) / snapshot.walletBalance) / 100 : 0;
  const band = exposureBand(snapshot.exposureBps, deployment.maxExposureBps, deployment.haltExposureBps);
  const copy = BAND_COPY[band];

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Why this maker is exposure-gated</h3>
      <p className="mt-1 text-xs text-neutral-500">
        Aqua lets one wallet back several strategies at once (the &quot;multiplier effect&quot;).
        Committed amounts below are live on-chain reads of this maker&apos;s actual shipped
        strategies -- not invented for this panel.
      </p>

      <div className="mt-4 rounded-lg border border-neutral-800 bg-neutral-950/40 p-4">
        <div className="flex items-center justify-between text-xs text-neutral-500">
          <span>Maker wallet balance</span>
          <span className="font-mono text-neutral-300">
            {formatUnits(snapshot.walletBalance, snapshot.decimals)} {snapshot.symbol}
          </span>
        </div>
        <div className="mt-3 space-y-1.5 border-t border-neutral-800 pt-3">
          {snapshot.rows.map((row) => (
            <div key={row.label} className="flex items-center justify-between text-xs">
              <span className="text-neutral-500">{row.label}</span>
              {row.committed === null ? (
                <span className="font-mono text-neutral-700">— not shipped on this deployment</span>
              ) : (
                <span className="font-mono text-neutral-300">
                  {formatUnits(row.committed, snapshot.decimals)} {snapshot.symbol}
                </span>
              )}
            </div>
          ))}
        </div>
        <div className="mt-3 flex items-center justify-between border-t border-neutral-800 pt-3 text-xs">
          <span className="font-medium text-neutral-400">Total committed</span>
          <span className="font-mono text-neutral-200">
            {formatUnits(snapshot.totalCommitted, snapshot.decimals)} {snapshot.symbol}
          </span>
        </div>
        <div className="mt-1 flex items-center justify-between text-[11px] text-neutral-600">
          <span>Committed / wallet (informational only -- see note below)</span>
          <span className="font-mono">{informationalPct.toFixed(2)}%</span>
        </div>
      </div>

      <div className="mt-3 flex items-center justify-between rounded-lg border border-neutral-800 bg-neutral-950/60 p-3">
        <span className="text-xs font-medium text-neutral-400">Live gating exposure (from ExposureOracle)</span>
        <span className={`font-mono text-sm font-semibold ${copy.text}`}>
          {(snapshot.exposureBps / 100).toFixed(2)}% -- {copy.label}
        </span>
      </div>

      <p className="mt-3 text-[11px] text-neutral-600">
        These are two different numbers on purpose: the committed/wallet ratio above is
        informational context (what an off-chain Graph keeper would compute for real, see{" "}
        <code>keeper/pushExposure.ts</code>); the gating exposure is whatever this deployment&apos;s
        keeper has actually posted to <code>ExposureOracle</code> right now, which is the one that
        really drives every swap panel below.
      </p>
    </div>
  );
}
