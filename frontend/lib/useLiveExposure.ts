"use client";

import { Contract } from "ethers";
import { useEffect, useState } from "react";
import { EXPOSURE_ORACLE_ABI } from "./abis";
import { exposureBand } from "./constants";
import { useDeployment } from "./DeploymentProvider";
import { getReadProvider } from "./readProvider";

export interface LiveExposure {
  bps: number | null;
  updatedAt: number | null;
  band: "safe" | "derate" | "halt" | null;
  maxBps: number;
  haltBps: number;
  error: string | null;
}

/// The same `ExposureOracle.exposureOf(maker)` read ExposureGauge does, shared by the site chrome
/// (nav chip, hero aqueduct) so every page's visuals are driven by the real live reading.
export function useLiveExposure(intervalMs = 8000): LiveExposure {
  const { deployment } = useDeployment();
  const [bps, setBps] = useState<number | null>(null);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function read() {
      if (document.hidden) return;
      try {
        const oracle = new Contract(deployment!.oracle, EXPOSURE_ORACLE_ABI, getReadProvider());
        const [value, ts] = await oracle.exposureOf(deployment!.maker);
        if (cancelled) return;
        setBps(Number(value));
        setUpdatedAt(Number(ts));
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    }

    read();
    const interval = setInterval(read, intervalMs);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [deployment, intervalMs]);

  const maxBps = deployment?.maxExposureBps ?? 5000;
  const haltBps = deployment?.haltExposureBps ?? 9000;
  return {
    bps,
    updatedAt,
    band: bps === null ? null : exposureBand(bps, maxBps, haltBps),
    maxBps,
    haltBps,
    error,
  };
}
