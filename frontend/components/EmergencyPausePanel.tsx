"use client";

import { Contract, Wallet, keccak256, toUtf8Bytes } from "ethers";
import { useEffect, useState } from "react";
import { EXPOSURE_ORACLE_ABI } from "@/lib/abis";
import { useActivityLog } from "@/lib/ActivityLogProvider";
import { useDeployment } from "@/lib/DeploymentProvider";
import { getReadProvider } from "@/lib/readProvider";

// Same fixed, non-secret demo constant AqueductDemo.s.sol derives the maker key from
// (`uint256(keccak256("aqueduct.demo.maker"))`) -- not a real secret, and needed here because the
// maker (not the keeper, not this app's deployer) is the only one authorized to flip their own
// kill switch. Standing in for a real maker's own wallet the same way KeeperPanel stands in for
// the off-chain Graph keeper.
const MAKER_PRIVATE_KEY = keccak256(toUtf8Bytes("aqueduct.demo.maker"));

/// Proves the third, independent security layer described in ExposureGate.sol's contract-level
/// comment: on top of keeper authorization and gate monotonicity, the maker holds their own kill
/// switch that needs neither the keeper's nor anyone else's cooperation (`setPausedByMaker`, added
/// to `ExposureOracle`). If the live Base Sepolia `ExposureOracle` predates this function, the
/// call below fails against real deployed bytecode rather than crashing the page -- see the
/// fallback state, which is the honest answer for a contract this addition hasn't been redeployed
/// to yet (the capability is fully implemented and tested, see test/MakerEmergencyPause.t.sol).
export function EmergencyPausePanel() {
  const { deployment } = useDeployment();
  const { log } = useActivityLog();
  const [isPaused, setIsPaused] = useState<boolean | null>(null);
  const [supported, setSupported] = useState<boolean | null>(null);
  const [isToggling, setIsToggling] = useState(false);

  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;

    async function fetchPauseState() {
      try {
        const oracle = new Contract(deployment!.oracle, EXPOSURE_ORACLE_ABI, getReadProvider());
        const paused: boolean = await oracle.isPausedByMaker(deployment!.maker);
        if (cancelled) return;
        setIsPaused(paused);
        setSupported(true);
      } catch {
        if (!cancelled) setSupported(false);
      }
    }

    fetchPauseState();
    const interval = setInterval(fetchPauseState, 5000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [deployment]);

  const toggle = async () => {
    if (!deployment) return;
    setIsToggling(true);
    try {
      const makerWallet = new Wallet(MAKER_PRIVATE_KEY, getReadProvider());
      const oracle = new Contract(deployment.oracle, EXPOSURE_ORACLE_ABI, makerWallet);
      const next = !isPaused;
      log("info", `Maker ${next ? "pausing" : "unpausing"} their own strategy...`);
      const tx = await oracle.setPausedByMaker(next);
      await tx.wait();
      setIsPaused(next);
      log("success", `Maker ${next ? "paused" : "unpaused"} -- every gated fill will ${next ? "now revert" : "resume normally"}.`, tx.hash);
    } catch (err) {
      log("error", `Failed to toggle pause: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setIsToggling(false);
    }
  };

  if (!deployment) return null;

  if (supported === false) {
    return (
      <div className="rounded-xl border border-dashed border-neutral-800 bg-neutral-900/30 p-5">
        <h3 className="text-sm font-semibold text-neutral-400">Maker emergency halt</h3>
        <p className="mt-1 text-xs text-neutral-600">
          Not live on this deployment yet -- <code>ExposureOracle.setPausedByMaker</code> was added
          after Base Sepolia address above was deployed. Fully implemented and tested (see{" "}
          <code>src/oracle/ExposureOracle.sol</code> and <code>test/MakerEmergencyPause.t.sol</code>
          ); a redeploy would make this control live without changing anything else about the demo.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Maker emergency halt</h3>
      <p className="mt-1 text-xs text-neutral-500">
        A third, independent layer on top of keeper authorization and gate monotonicity: if the
        maker distrusts the exposure feed itself -- not just one bad reading -- they can halt every
        strategy they&apos;ve shipped against this oracle themselves, immediately, with no
        dependency on the keeper or staleness catching up.
      </p>
      <div className="mt-4 flex items-center gap-3">
        <span
          className={`inline-block rounded-full px-3 py-1 text-xs font-medium ${
            isPaused ? "bg-red-500/10 text-red-400" : "bg-emerald-500/10 text-emerald-400"
          }`}
        >
          {isPaused === null ? "Loading..." : isPaused ? "Paused by maker" : "Not paused"}
        </span>
        <button
          onClick={toggle}
          disabled={isToggling || isPaused === null}
          className="rounded-lg border border-neutral-700 px-3 py-2 text-xs font-medium text-neutral-200 hover:bg-neutral-800 disabled:opacity-50"
        >
          {isToggling ? "Sending..." : isPaused ? "Unpause" : "Pause (emergency halt)"}
        </button>
      </div>
    </div>
  );
}
