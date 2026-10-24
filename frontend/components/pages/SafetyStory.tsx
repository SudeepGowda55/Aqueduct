"use client";

import { useState } from "react";
import { Reveal, SectionHead } from "@/components/site/Reveal";

// Straight from the README's threat model table -- every row ends in a smaller fill or none.
const MODES = [
  {
    name: "Unauthorized write",
    trigger: "A non-keeper address calls pushExposure",
    fails: "Reverts. No write path exists at all.",
    proof: "onlyKeeper modifier, ExposureOracle.sol",
    outcome: "revert",
    layer: 1,
  },
  {
    name: "Wrong or malicious reading",
    trigger: "Compromised keeper key, faulty Graph pipeline, garbage data",
    fails: "Can only derate or halt relative to the unsigned baseline, never improve it",
    proof: "test_MaliciousOracle_CanOnlyEverMakeFillMoreConservative + two 257-run fuzz properties",
    outcome: "derate",
    layer: 2,
  },
  {
    name: "Stale reading",
    trigger: "block.timestamp > updatedAt + maxStaleness",
    fails: "Hard revert, no fill. Treated exactly like a dangerous reading.",
    proof: "ExposureGateOracleStale, test_Reverts_WhenOracleReadingStale (direct and v4 path)",
    outcome: "revert",
    layer: 2,
  },
  {
    name: "Keeper stops entirely",
    trigger: "No new pushes, ever",
    fails: "The same staleness revert kicks in once maxStaleness elapses",
    proof: "Same staleness tests as above",
    outcome: "revert",
    layer: 2,
  },
  {
    name: "Maker distrusts the feed",
    trigger: "Maker calls setPausedByMaker(true)",
    fails: "Halts immediately, with no staleness wait and no keeper cooperation",
    proof: "test/MakerEmergencyPause.t.sol",
    outcome: "revert",
    layer: 3,
  },
  {
    name: "Exposure ≥ halt threshold",
    trigger: "exposureBps >= haltExposureBps",
    fails: "Hard revert, on either venue",
    proof: "ExposureGateExceedsHaltThreshold, test/CrossVenueConsistency.t.sol",
    outcome: "revert",
    layer: 2,
  },
  {
    name: "Exposure between max and halt",
    trigger: "maxExposureBps < exposureBps < haltExposureBps",
    fails: "Linear derate: strictly worse for the taker, never better",
    proof: "test_Derate_*, test/EndToEndAggregateExposure.t.sol",
    outcome: "derate",
    layer: 2,
  },
  {
    name: "Over-committed across strategies",
    trigger: "Σ committed > wallet balance (Aqua allows this)",
    fails: "The aggregate fails closed for every strategy the maker has shipped, even one that looks safe alone",
    proof: "test/MultiStrategyExposure.t.sol, test/EndToEndAggregateExposure.t.sol",
    outcome: "derate",
    layer: 2,
  },
] as const;

const LAYERS = [
  { n: 1, t: "Authorization", d: "Only the keeper address can call pushExposure. A stranger has no write path at all." },
  { n: 2, t: "Monotonicity", d: "Even an authorized but wrong reading can only derate or halt. The fill limit never depends on trusting the oracle." },
  { n: 3, t: "The maker's own switch", d: "setPausedByMaker is checked before the reading is read. One bool per maker, with no admin override." },
];

function OutcomeGlyph({ outcome }: { outcome: "revert" | "derate" }) {
  const closed = outcome === "revert";
  return (
    <svg viewBox="0 0 220 90" className="h-auto w-full max-w-60" aria-label={closed ? "Gate fully closed: no fill" : "Gate partly lowered: smaller fill"}>
      <rect x="0" y="40" width="220" height="40" rx="4" fill="#d9caad" />
      <rect x="0" y="46" width="100" height="30" fill="var(--water)" />
      <rect x="112" y={closed ? 76 : 60} width="108" height={closed ? 0 : 16} fill="var(--water)" style={{ transition: "all .7s var(--ease-water)" }} />
      <rect x="98" y={closed ? 8 : -6} width="16" height="70" rx="2" fill="var(--ink)" style={{ transition: "all .7s var(--ease-water)" }} />
      <text x="166" y="30" textAnchor="middle" className={`font-mono text-[11px] font-semibold ${closed ? "fill-(--halt)" : "fill-(--derate)"}`}>
        {closed ? "NO FILL" : "SMALLER FILL"}
      </text>
    </svg>
  );
}

export function SafetyStory() {
  const [sel, setSel] = useState(1);
  const mode = MODES[sel];

  return (
    <div className="mx-auto max-w-6xl px-4 pt-14 sm:px-6 md:pt-20">
      <SectionHead numeral="I" eyebrow="Threat model" title={<>Pick a failure. Watch it fail closed.</>}>
        Every row below ends in either a strictly smaller fill or no fill at all, never in a taker getting more than
        the maker&apos;s unsigned SwapVM program authorized. That&apos;s why none of the parts need to be trusted on
        their own.
      </SectionHead>

      <Reveal className="mt-12 grid gap-6 lg:grid-cols-[1fr_1.1fr]">
        <ul className="space-y-2" role="listbox" aria-label="Failure modes">
          {MODES.map((m, i) => (
            <li key={m.name}>
              <button
                role="option"
                aria-selected={sel === i}
                onClick={() => setSel(i)}
                onMouseEnter={() => setSel(i)}
                className={`flex w-full items-center justify-between gap-3 rounded-xl border px-4 py-3 text-left text-sm transition-all duration-300 ${
                  sel === i ? "border-(--ink) bg-(--ink) text-(--paper)" : "border-(--line) bg-white/40 hover:border-(--line-strong)"
                }`}
              >
                <span className="flex items-center gap-3">
                  <span className="font-mono text-[11px] opacity-60">{String(i + 1).padStart(2, "0")}</span>
                  {m.name}
                </span>
                <span className={`shrink-0 font-mono text-[10px] ${m.outcome === "revert" ? "text-(--halt)" : "text-(--derate)"} ${sel === i ? "text-(--water-bright)!" : ""}`}>
                  {m.outcome === "revert" ? "REVERTS" : "DERATES"}
                </span>
              </button>
            </li>
          ))}
        </ul>

        <div className="panel p-6 lg:sticky lg:top-24 lg:self-start" aria-live="polite">
          <p className="eyebrow">Failure {String(sel + 1).padStart(2, "0")} · caught by layer {mode.layer}</p>
          <h2 className="display mt-3 text-3xl">{mode.name}</h2>
          <div className="mt-6">
            <OutcomeGlyph outcome={mode.outcome} />
          </div>
          <dl className="mt-6 space-y-4 text-sm">
            <div>
              <dt className="eyebrow">Trigger</dt>
              <dd className="mt-1 font-mono text-[13px]">{mode.trigger}</dd>
            </div>
            <div>
              <dt className="eyebrow">Fails closed by</dt>
              <dd className="mt-1">{mode.fails}</dd>
            </div>
            <div>
              <dt className="eyebrow">Proven by</dt>
              <dd className="mt-1 font-mono text-[12px] text-(--water-deep)">{mode.proof}</dd>
            </div>
          </dl>
        </div>
      </Reveal>

      <div className="mt-32">
        <SectionHead numeral="II" eyebrow="Defence in depth" title="Three independent walls, stacked.">
          Each layer covers a case the one before it can&apos;t. Authorization stops a stranger, monotonicity limits
          what a compromised keeper can do, and the maker&apos;s own switch covers not trusting the pipeline right now.
        </SectionHead>
        <div className="mt-12 space-y-3">
          {LAYERS.map((l, i) => (
            <Reveal key={l.n} delay={i * 140}>
              <div
                className={`flex flex-col gap-3 rounded-2xl border p-6 transition-colors duration-500 sm:flex-row sm:items-center sm:gap-8 ${
                  mode.layer === l.n ? "border-(--water) bg-(--mist)/50" : "border-(--line) bg-white/40"
                }`}
                style={{ marginLeft: `${i * 4}%` }}
              >
                <span className="numeral text-5xl">{["I", "II", "III"][i]}</span>
                <div>
                  <p className="display text-2xl">{l.t}</p>
                  <p className="mt-1 max-w-2xl text-sm text-(--ink-soft)">{l.d}</p>
                </div>
                {mode.layer === l.n && <span className="ml-auto font-mono text-[11px] text-(--water)">catches failure {String(sel + 1).padStart(2, "0")}</span>}
              </div>
            </Reveal>
          ))}
        </div>
      </div>

      <div className="mt-32 grid gap-6 md:grid-cols-2">
        <Reveal className="panel p-6">
          <p className="eyebrow">Three questions, three answers</p>
          <ul className="mt-4 space-y-4 text-sm leading-relaxed">
            <li>
              <b>Liquidity</b> comes from Aqua: the maker&apos;s real wallet balance, committed via ship / pull.
            </li>
            <li>
              <b>Risk</b> is calculated by ExposureOracle → <code>_exposureGate1D</code>, entirely at the Aqua/SwapVM
              layer.
            </li>
            <li>
              <b>Uniswap v4 is an execution venue</b>, nothing more. AquaV4Hook holds no liquidity of its own.
            </li>
          </ul>
        </Reveal>
        <Reveal delay={120} className="panel p-6">
          <p className="eyebrow">Why no third protocol</p>
          <p className="mt-4 text-sm leading-relaxed text-(--ink-soft)">
            1inch and Uniswap already prove the whole claim: exposure-gated liquidity that doesn&apos;t depend on the
            venue. A third, likely half-finished integration (Aave, Morpho, Curve) would dilute that story rather than
            strengthen it. The project aims for depth of proof on one thesis, not breadth of protocol logos.
          </p>
        </Reveal>
      </div>
    </div>
  );
}
