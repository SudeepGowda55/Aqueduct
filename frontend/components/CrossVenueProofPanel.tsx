"use client";

import { Contract } from "ethers";
import { useEffect, useState } from "react";
import { EXPOSURE_ORACLE_ABI } from "@/lib/abis";
import { EXPOSURE_BANDS, exposureBand } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { getReadProvider } from "@/lib/readProvider";

const BAND_COPY = {
  safe: { label: EXPOSURE_BANDS.safeLabel, text: "text-emerald-400", bg: "bg-emerald-500/10", icon: "✅" },
  derate: { label: EXPOSURE_BANDS.derateLabel, text: "text-amber-400", bg: "bg-amber-500/10", icon: "⚠️" },
  halt: { label: EXPOSURE_BANDS.haltLabel, text: "text-red-400", bg: "bg-red-500/10", icon: "⛔" },
} as const;

/// This is the Uniswap track story in one screen: ONE maker, ONE Aqua strategy, ONE exposure
/// reading -- shown feeding into both execution venues at once. Both bands below are computed
/// from the exact same on-chain values (see test/CrossVenueConsistency.t.sol for the on-chain
/// proof this isn't just a UI coincidence: the two venues bottom out in the literal same
/// `_exposureGate1D` opcode execution, so they can't help but agree).
export function CrossVenueProofPanel() {
  const { deployment } = useDeployment();
  const [exposureBps, setExposureBps] = useState<number | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function fetchExposure() {
      try {
        const oracle = new Contract(deployment!.oracle, EXPOSURE_ORACLE_ABI, getReadProvider());
        const [bps] = await oracle.exposureOf(deployment!.maker);
        if (!cancelled) setExposureBps(Number(bps));
      } catch {
        // ExposureGauge already surfaces read failures; this panel just goes quiet.
      }
    }

    fetchExposure();
    const interval = setInterval(fetchExposure, 4000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [deployment]);

  if (!deployment || !deployment.v4 || exposureBps === null) return null;

  const band = exposureBand(exposureBps, deployment.maxExposureBps, deployment.haltExposureBps);
  const copy = BAND_COPY[band];

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Same strategy. Same risk. Different venue.</h3>
      <div className="mt-3 space-y-1 text-xs text-neutral-500">
        <p>
          Maker: <span className="font-mono text-neutral-400">{deployment.maker}</span>
        </p>
        <p>
          Aqua strategy hash: <span className="font-mono text-neutral-400">{deployment.strategyHash}</span>
        </p>
        <p>
          Exposure: <span className="font-mono text-neutral-300">{(exposureBps / 100).toFixed(2)}%</span>
        </p>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-3 text-center">
        <div className={`rounded-lg border border-neutral-800 p-4 ${copy.bg}`}>
          <p className="text-xs font-medium text-neutral-400">1inch SwapVM</p>
          <p className="mt-1 text-[10px] text-neutral-600">direct swap, no pool</p>
          <p className={`mt-2 text-lg font-semibold ${copy.text}`}>
            {copy.icon} {copy.label}
          </p>
        </div>
        <div className={`rounded-lg border border-neutral-800 p-4 ${copy.bg}`}>
          <p className="text-xs font-medium text-neutral-400">Uniswap v4</p>
          <p className="mt-1 text-[10px] text-neutral-600">via AquaV4Hook</p>
          <p className={`mt-2 text-lg font-semibold ${copy.text}`}>
            {copy.icon} {copy.label}
          </p>
        </div>
      </div>

      <p className="mt-3 text-[11px] text-neutral-600">
        Both venues source liquidity from -- and are gated by -- the exact same Aqua strategy. This
        isn&apos;t two independent systems that happen to agree; the v4 pool has no liquidity of
        its own, and both paths read the identical <code>ExposureOracle</code> entry through the
        identical <code>_exposureGate1D</code> opcode.
      </p>
    </div>
  );
}
