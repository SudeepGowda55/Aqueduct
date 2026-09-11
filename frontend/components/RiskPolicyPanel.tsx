"use client";

import { useDeployment } from "@/lib/DeploymentProvider";

const PROFILES = [
  { name: "Conservative", max: 30, halt: 60 },
  { name: "Normal", max: 50, halt: 90 },
  { name: "Aggressive", max: 70, halt: 95 },
] as const;

/// `_exposureGate1D` already takes `maxExposureBps`/`haltExposureBps` as per-order arguments (see
/// ExposureGateArgsBuilder.build in src/opcodes/ExposureGate.sol) -- there is nothing hard-coded
/// about this maker's specific 50%/90% thresholds, they're just what THIS demo strategy chose.
/// Any maker shipping their own SwapVM program picks their own numbers, the same way they pick
/// their own AMM curve or fee. This panel makes that configurability visible rather than adding
/// new on-chain functionality to demonstrate it -- the three profiles below are illustrative
/// presets a maker could choose from, not separate deployments.
export function RiskPolicyPanel() {
  const { deployment } = useDeployment();
  if (!deployment) return null;

  const activeMax = deployment.maxExposureBps / 100;
  const activeHalt = deployment.haltExposureBps / 100;

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Maker risk policy</h3>
      <p className="mt-1 text-xs text-neutral-500">
        <code>maxExposureBps</code> and <code>haltExposureBps</code> are arguments the maker
        chooses when building their SwapVM program -- a reusable risk-control primitive, not a
        hackathon constant. This deployment&apos;s maker chose:
      </p>
      <div className="mt-3 grid grid-cols-3 gap-2">
        {PROFILES.map((profile) => {
          const isActive = profile.max === activeMax && profile.halt === activeHalt;
          return (
            <div
              key={profile.name}
              className={`rounded-lg border p-3 text-center ${
                isActive ? "border-cyan-700 bg-cyan-500/10" : "border-neutral-800 bg-neutral-950/40"
              }`}
            >
              <p className={`text-xs font-medium ${isActive ? "text-cyan-300" : "text-neutral-500"}`}>
                {profile.name}
                {isActive && " (active)"}
              </p>
              <p className="mt-1 font-mono text-[11px] text-neutral-400">max {profile.max}%</p>
              <p className="font-mono text-[11px] text-neutral-400">halt {profile.halt}%</p>
            </div>
          );
        })}
      </div>
      <p className="mt-3 text-[11px] text-neutral-600">
        Proven interchangeable in <code>test/ExposureGate.t.sol</code> and{" "}
        <code>test/MultiStrategyExposure.t.sol</code>, which exercise the same opcode against
        several different threshold pairs -- swapping profiles only ever changes where the
        derate/halt bands sit, never the monotonicity guarantee itself.
      </p>
    </div>
  );
}
