"use client";

import { Contract } from "ethers";
import { useEffect, useState } from "react";
import { EXPOSURE_ORACLE_ABI } from "@/lib/abis";
import { exposureBand } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { getReadProvider } from "@/lib/readProvider";

const BAND_STYLES = {
  safe: { label: "Safe -- normal fill", ring: "stroke-emerald-500", text: "text-emerald-400", bg: "bg-emerald-500/10" },
  derate: { label: "Derated -- worse price, still fills", ring: "stroke-amber-500", text: "text-amber-400", bg: "bg-amber-500/10" },
  halt: { label: "Halted -- swaps revert", ring: "stroke-red-500", text: "text-red-400", bg: "bg-red-500/10" },
} as const;

export function ExposureGauge() {
  const { deployment } = useDeployment();
  const [exposureBps, setExposureBps] = useState<number | null>(null);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function fetchExposure() {
      try {
        const oracle = new Contract(deployment!.oracle, EXPOSURE_ORACLE_ABI, getReadProvider());
        const [bps, ts] = await oracle.exposureOf(deployment!.maker);
        if (cancelled) return;
        setExposureBps(Number(bps));
        setUpdatedAt(Number(ts));
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    }

    const interval = setInterval(fetchExposure, 4000);
    fetchExposure();
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [deployment]);

  if (!deployment) return null;
  if (error) {
    return <p className="text-sm text-red-400">Failed to read exposure: {error}</p>;
  }
  if (exposureBps === null) {
    return <p className="text-sm text-neutral-500">Loading exposure...</p>;
  }

  const band = exposureBand(exposureBps, deployment.maxExposureBps, deployment.haltExposureBps);
  const style = BAND_STYLES[band];
  const pct = exposureBps / 100;
  const circumference = 2 * Math.PI * 54;
  const dashOffset = circumference * (1 - Math.min(exposureBps, 10_000) / 10_000);

  return (
    <div className="flex items-center gap-6">
      <svg width="128" height="128" viewBox="0 0 128 128" className="shrink-0 -rotate-90">
        <circle cx="64" cy="64" r="54" fill="none" stroke="currentColor" strokeWidth="10" className="text-neutral-800" />
        <circle
          cx="64"
          cy="64"
          r="54"
          fill="none"
          strokeWidth="10"
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={dashOffset}
          className={`${style.ring} transition-[stroke-dashoffset] duration-500`}
        />
        <text x="64" y="64" textAnchor="middle" dominantBaseline="middle" className="rotate-90 fill-neutral-100 text-2xl font-semibold" style={{ transform: "rotate(90deg)", transformOrigin: "64px 64px" }}>
          {pct.toFixed(1)}%
        </text>
      </svg>
      <div>
        <span className={`inline-block rounded-full px-3 py-1 text-sm font-medium ${style.bg} ${style.text}`}>
          {style.label}
        </span>
        <p className="mt-2 text-xs text-neutral-500">
          Maker: <span className="font-mono">{deployment.maker}</span>
        </p>
        <p className="text-xs text-neutral-500">
          Thresholds: derate at {(deployment.maxExposureBps / 100).toFixed(0)}%, halt at{" "}
          {(deployment.haltExposureBps / 100).toFixed(0)}%
        </p>
        {updatedAt !== null && updatedAt > 0 && (
          <p className="text-xs text-neutral-600">Last updated: {new Date(updatedAt * 1000).toLocaleTimeString()}</p>
        )}
      </div>
    </div>
  );
}
