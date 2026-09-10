"use client";

import { Contract, Wallet, keccak256, toUtf8Bytes } from "ethers";
import { useState } from "react";
import { EXPOSURE_ORACLE_ABI } from "@/lib/abis";
import { useActivityLog } from "@/lib/ActivityLogProvider";
import { useDeployment } from "@/lib/DeploymentProvider";
import { getReadProvider } from "@/lib/readProvider";

// Same fixed, non-secret demo constant AqueductDemo.s.sol derives its keeper key from
// (`uint256(keccak256("aqueduct.demo.keeper"))`) -- not a real secret, and the whole point of
// this panel: it stands in for the off-chain Graph keeper (see subgraph/ and
// keeper/pushExposure.ts) so the safety story can be demoed live without deploying a real
// subgraph indexer.
const KEEPER_PRIVATE_KEY = keccak256(toUtf8Bytes("aqueduct.demo.keeper"));

const PRESETS = [
  { label: "Safe (10%)", bps: 1_000 },
  { label: "Derated (70%)", bps: 7_000 },
  { label: "Halted (90%)", bps: 9_000 },
];

export function KeeperPanel() {
  const { deployment } = useDeployment();
  const { log } = useActivityLog();
  const [customBps, setCustomBps] = useState("");
  const [isPushing, setIsPushing] = useState(false);

  const push = async (bps: number) => {
    if (!deployment) return;
    setIsPushing(true);
    try {
      const keeperWallet = new Wallet(KEEPER_PRIVATE_KEY, getReadProvider());
      const oracle = new Contract(deployment.oracle, EXPOSURE_ORACLE_ABI, keeperWallet);
      log("info", `Keeper pushing exposure: ${(bps / 100).toFixed(1)}%...`);
      const tx = await oracle.pushExposure(deployment.maker, bps);
      await tx.wait();
      log("success", `Exposure updated to ${(bps / 100).toFixed(1)}%`, tx.hash);
    } catch (err) {
      log("error", `Failed to push exposure: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setIsPushing(false);
    }
  };

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Keeper control (demo)</h3>
      <p className="mt-1 text-xs text-neutral-500">
        Stands in for the off-chain Graph pipeline (see <code>subgraph/</code> +{" "}
        <code>keeper/pushExposure.ts</code>), which would push this same value automatically in
        production. Use it to move the maker&apos;s reported exposure and watch both swap panels
        react.
      </p>
      <div className="mt-4 flex flex-wrap gap-2">
        {PRESETS.map((preset) => (
          <button
            key={preset.bps}
            onClick={() => push(preset.bps)}
            disabled={isPushing || !deployment}
            className="rounded-lg border border-neutral-700 px-3 py-2 text-xs font-medium text-neutral-200 hover:bg-neutral-800 disabled:opacity-50"
          >
            {preset.label}
          </button>
        ))}
      </div>
      <div className="mt-3 flex gap-2">
        <input
          type="number"
          min={0}
          max={10000}
          placeholder="Custom bps (0-10000)"
          value={customBps}
          onChange={(e) => setCustomBps(e.target.value)}
          className="w-40 rounded-lg border border-neutral-700 bg-neutral-950 px-3 py-2 text-xs text-neutral-200"
        />
        <button
          onClick={() => customBps && push(Number(customBps))}
          disabled={isPushing || !deployment || !customBps}
          className="rounded-lg bg-neutral-800 px-3 py-2 text-xs font-medium text-neutral-200 hover:bg-neutral-700 disabled:opacity-50"
        >
          Push
        </button>
      </div>
    </div>
  );
}
