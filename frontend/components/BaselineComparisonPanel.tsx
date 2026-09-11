"use client";

import { Contract, formatUnits, parseUnits } from "ethers";
import { useEffect, useState } from "react";
import { AQUA_ABI, ERC20_ABI, EXPOSURE_ORACLE_ABI } from "@/lib/abis";
import { useDeployment } from "@/lib/DeploymentProvider";
import { getReadProvider } from "@/lib/readProvider";
import { applyExposureGate, xycAmountOut } from "@/lib/xyc";

interface Snapshot {
  decimals: number;
  symbolIn: string;
  symbolOut: string;
  ungatedOut: bigint;
  gatedOut: bigint;
  halted: boolean;
  exposureBps: number;
  committedIn: bigint;
  makerWalletIn: bigint;
}

/// Makes the economic effect of `_exposureGate1D` immediately legible: instead of just "swap
/// succeeded", show the SAME swap amount priced two ways -- what the maker's pool would give up
/// with no exposure gate at all (computed from live reserves, the pool's own constant-product
/// curve), and what it actually gives up right now, gated. Both numbers come from live, public,
/// keyless reads (no wallet needed) -- see lib/xyc.ts for why this is a faithful mirror of the
/// deployed contract's own math, not an approximation.
export function BaselineComparisonPanel() {
  const { deployment } = useDeployment();
  const [amount, setAmount] = useState("100");
  const [reversed, setReversed] = useState(false);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function compute() {
      try {
        const provider = getReadProvider();
        const [tokenInAddr, tokenOutAddr] = reversed
          ? [deployment!.tokenOut, deployment!.tokenIn]
          : [deployment!.tokenIn, deployment!.tokenOut];

        const tokenIn = new Contract(tokenInAddr, ERC20_ABI, provider);
        const tokenOut = new Contract(tokenOutAddr, ERC20_ABI, provider);
        const aqua = new Contract(deployment!.aqua, AQUA_ABI, provider);
        const oracle = new Contract(deployment!.oracle, EXPOSURE_ORACLE_ABI, provider);

        const [decimals, symbolIn, symbolOut] = await Promise.all([
          tokenIn.decimals(),
          tokenIn.symbol(),
          tokenOut.symbol(),
        ]);
        if (!amount || Number(amount) <= 0) {
          if (!cancelled) setSnapshot(null);
          return;
        }
        const amountWei = parseUnits(amount, decimals);

        const [[balanceIn, balanceOut], [exposureBps], makerWalletIn] = await Promise.all([
          aqua.safeBalances(deployment!.maker, deployment!.swapVM, deployment!.strategyHash, tokenInAddr, tokenOutAddr),
          oracle.exposureOf(deployment!.maker),
          tokenIn.balanceOf(deployment!.maker),
        ]);

        const ungatedOut = xycAmountOut(amountWei, balanceIn, balanceOut);
        const { amountOut: gatedOut, halted } = applyExposureGate(
          ungatedOut,
          BigInt(exposureBps),
          BigInt(deployment!.maxExposureBps),
          BigInt(deployment!.haltExposureBps)
        );

        if (cancelled) return;
        setSnapshot({
          decimals: Number(decimals),
          symbolIn,
          symbolOut,
          ungatedOut,
          gatedOut,
          halted,
          exposureBps: Number(exposureBps),
          committedIn: balanceIn,
          makerWalletIn,
        });
        setError(null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    }

    compute();
    const interval = setInterval(compute, 5000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [deployment, amount, reversed]);

  if (!deployment) return null;

  const reductionPct =
    snapshot && !snapshot.halted && snapshot.ungatedOut > 0n
      ? Number((10_000n * (snapshot.ungatedOut - snapshot.gatedOut)) / snapshot.ungatedOut) / 100
      : null;

  const committedPct =
    snapshot && snapshot.makerWalletIn > 0n
      ? Number((10_000n * snapshot.committedIn) / snapshot.makerWalletIn) / 100
      : null;

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Ungated vs. exposure-gated</h3>
      <p className="mt-1 text-xs text-neutral-500">
        The same swap amount, priced two ways from the maker&apos;s live pool reserves: what the
        constant-product curve alone would give up (no exposure gate), and what it actually gives
        up right now. No wallet needed -- both numbers come from public reads.
      </p>

      <div className="mt-4 flex items-center gap-2 text-xs text-neutral-400">
        <span>{reversed ? "tokenOut" : "tokenIn"}</span>
        <button
          onClick={() => setReversed((r) => !r)}
          className="rounded-full border border-neutral-700 px-2 py-1 hover:bg-neutral-800"
          title="Flip direction"
        >
          ⇄
        </button>
        <span>{reversed ? "tokenIn" : "tokenOut"}</span>
        <input
          type="number"
          min={0}
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          className="ml-auto w-28 rounded-lg border border-neutral-700 bg-neutral-950 px-3 py-2 text-sm text-neutral-200"
        />
      </div>

      {error && <p className="mt-3 text-xs text-red-400">Failed to compute: {error}</p>}

      {snapshot && (
        <div className="mt-4 grid grid-cols-2 gap-3">
          <div className="rounded-lg border border-neutral-800 bg-neutral-950/60 p-3">
            <p className="text-[11px] uppercase tracking-wide text-neutral-500">Ungated</p>
            <p className="mt-1 font-mono text-sm text-neutral-200">
              {amount} {snapshot.symbolIn}
            </p>
            <p className="font-mono text-sm text-neutral-500">↓</p>
            <p className="font-mono text-lg text-neutral-100">
              {formatUnits(snapshot.ungatedOut, snapshot.decimals)} {snapshot.symbolOut}
            </p>
          </div>
          <div
            className={`rounded-lg border p-3 ${
              snapshot.halted ? "border-red-900 bg-red-500/10" : "border-amber-900/50 bg-amber-500/5"
            }`}
          >
            <p className="text-[11px] uppercase tracking-wide text-neutral-500">Exposure-gated</p>
            <p className="mt-1 font-mono text-sm text-neutral-200">
              {amount} {snapshot.symbolIn}
            </p>
            <p className="font-mono text-sm text-neutral-500">↓</p>
            {snapshot.halted ? (
              <p className="font-mono text-lg text-red-400">❌ HALTED</p>
            ) : (
              <p className="font-mono text-lg text-neutral-100">
                {formatUnits(snapshot.gatedOut, snapshot.decimals)} {snapshot.symbolOut}
              </p>
            )}
          </div>

          <div className="col-span-2 rounded-lg border border-neutral-800 bg-neutral-950/40 p-3 text-xs text-neutral-400">
            <p>
              Maker exposure: <span className="font-mono text-neutral-200">{(snapshot.exposureBps / 100).toFixed(2)}%</span>
              {reductionPct !== null && (
                <>
                  {" "}
                  — liquidity reduction:{" "}
                  <span className="font-mono text-amber-400">{reductionPct.toFixed(2)}%</span>
                </>
              )}
              {snapshot.halted && <span className="text-red-400"> — no fill at all, by design</span>}
            </p>
            {committedPct !== null && (
              <p className="mt-1">
                Committed in this strategy:{" "}
                <span className="font-mono text-neutral-200">
                  {formatUnits(snapshot.committedIn, snapshot.decimals)} {snapshot.symbolIn}
                </span>{" "}
                / maker wallet holds{" "}
                <span className="font-mono text-neutral-200">
                  {formatUnits(snapshot.makerWalletIn, snapshot.decimals)} {snapshot.symbolIn}
                </span>{" "}
                (<span className="font-mono">{committedPct.toFixed(1)}%</span> of this token committed to this one
                strategy alone -- see <code>MultiStrategyExposure.t.sol</code> for what happens once a maker backs
                several).
              </p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
