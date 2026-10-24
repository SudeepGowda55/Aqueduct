"use client";

import { Contract, formatUnits, parseUnits } from "ethers";
import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { AqueductScene } from "@/components/site/AqueductScene";
import { Reveal, SectionHead } from "@/components/site/Reveal";
import { AQUA_ABI, ERC20_ABI } from "@/lib/abis";
import { exposureBand } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { feePipsToPercent, predictedFeePips } from "@/lib/dynamicFee";
import { getReadProvider } from "@/lib/readProvider";
import { BAND_META, repoFile } from "@/lib/site";
import { useLiveExposure } from "@/lib/useLiveExposure";
import { applyExposureGate, fillFraction, xycAmountOut } from "@/lib/xyc";

// Same illustrative presets as RiskPolicyPanel -- thresholds are per-order arguments a maker picks.
const PROFILES = [
  { name: "Conservative", max: 3000, halt: 6000 },
  { name: "Normal", max: 5000, halt: 9000 },
  { name: "Aggressive", max: 7000, halt: 9500 },
] as const;

interface Reserves {
  balanceIn: bigint;
  balanceOut: bigint;
  decimals: number;
  symbolIn: string;
  symbolOut: string;
}

function useStrategyReserves(): Reserves | null {
  const { deployment } = useDeployment();
  const [reserves, setReserves] = useState<Reserves | null>(null);
  useEffect(() => {
    if (!deployment) return;
    let cancelled = false;
    const provider = getReadProvider();
    const aqua = new Contract(deployment.aqua, AQUA_ABI, provider);
    const tokenIn = new Contract(deployment.tokenIn, ERC20_ABI, provider);
    const tokenOut = new Contract(deployment.tokenOut, ERC20_ABI, provider);
    Promise.all([
      aqua.safeBalances(deployment.maker, deployment.swapVM, deployment.strategyHash, deployment.tokenIn, deployment.tokenOut),
      tokenIn.decimals(),
      tokenIn.symbol(),
      tokenOut.symbol(),
    ])
      .then(([[balanceIn, balanceOut], decimals, symbolIn, symbolOut]) => {
        if (!cancelled) setReserves({ balanceIn, balanceOut, decimals: Number(decimals), symbolIn, symbolOut });
      })
      .catch(() => {
        // The simulator still works on fill fractions without live reserves.
      });
    return () => {
      cancelled = true;
    };
  }, [deployment]);
  return reserves;
}

const CW = 640;
const CH = 270;
const PAD = { l: 46, r: 16, t: 34, b: 36 };
const cx = (bps: number) => PAD.l + (bps / 10000) * (CW - PAD.l - PAD.r);
const cy = (fill: number) => PAD.t + (1 - fill) * (CH - PAD.t - PAD.b);

function DerateCurve({
  max,
  halt,
  sim,
  live,
  onPick,
}: {
  max: number;
  halt: number;
  sim: number;
  live: number | null;
  onPick: (bps: number) => void;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const line = `M${cx(0)} ${cy(1)} H${cx(max)} L${cx(halt)} ${cy(0)} H${cx(10000)}`;
  const bands = [
    { from: 0, to: max, key: "safe" as const },
    { from: max, to: halt, key: "derate" as const },
    { from: halt, to: 10000, key: "halt" as const },
  ];

  const toBps = (clientX: number, el: SVGSVGElement) => {
    const r = el.getBoundingClientRect();
    const x = ((clientX - r.left) / r.width) * CW;
    return Math.round(Math.max(0, Math.min(10000, ((x - PAD.l) / (CW - PAD.l - PAD.r)) * 10000)) / 50) * 50;
  };

  const shown = hover ?? sim;
  const shownFill = fillFraction(shown, max, halt);

  return (
    <div className="relative">
      <svg
        viewBox={`0 0 ${CW} ${CH}`}
        className="h-auto w-full cursor-crosshair touch-none select-none"
        role="img"
        aria-label={`Fill versus exposure: 100% fill up to ${max / 100}% exposure, linear derate to zero at ${halt / 100}%, halted above.`}
        onPointerMove={(e) => setHover(toBps(e.clientX, e.currentTarget))}
        onPointerLeave={() => setHover(null)}
        onPointerDown={(e) => onPick(toBps(e.clientX, e.currentTarget))}
      >
        {bands.map((b) => (
          <g key={b.key}>
            <rect
              x={cx(b.from)}
              y={PAD.t}
              width={cx(b.to) - cx(b.from)}
              height={CH - PAD.t - PAD.b}
              fill={BAND_META[b.key].color}
              opacity="0.09"
              style={{ transition: "all .6s var(--ease-water)" }}
            />
            {cx(b.to) - cx(b.from) > 60 && (
              <text x={(cx(b.from) + cx(b.to)) / 2} y={PAD.t - 12} textAnchor="middle" className="fill-(--ink-soft) font-mono text-[11px]">
                {BAND_META[b.key].label.toUpperCase()}
              </text>
            )}
          </g>
        ))}
        {[0, 0.5, 1].map((f) => (
          <g key={f}>
            <path d={`M${PAD.l} ${cy(f)} H${CW - PAD.r}`} stroke="var(--line)" strokeWidth="1" />
            <text x={PAD.l - 8} y={cy(f) + 4} textAnchor="end" className="fill-(--ink-faint) font-mono text-[11px]">
              {f * 100}%
            </text>
          </g>
        ))}
        {[0, 2500, 5000, 7500, 10000].map((b) => (
          <text key={b} x={cx(b)} y={CH - 12} textAnchor="middle" className="fill-(--ink-faint) font-mono text-[11px]">
            {b / 100}%
          </text>
        ))}
        <text x={CW - PAD.r} y={CH - 26} textAnchor="end" className="fill-(--ink-faint) font-mono text-[10px]">
          exposure →
        </text>

        <path d={line} fill="none" stroke="var(--water)" strokeWidth="2.5" strokeLinejoin="round" style={{ transition: "d .6s var(--ease-water)" }} />

        {live !== null && (
          <g>
            <path d={`M${cx(live)} ${PAD.t} V${CH - PAD.b}`} stroke="var(--ink)" strokeWidth="1" strokeDasharray="3 4" />
            <text x={cx(live) + 5} y={PAD.t + 12} className="fill-(--ink) font-mono text-[10px]">
              live
            </text>
          </g>
        )}
        {hover !== null && <path d={`M${cx(hover)} ${PAD.t} V${CH - PAD.b}`} stroke="var(--ink-faint)" strokeWidth="1" />}
        <circle cx={cx(shown)} cy={cy(shownFill)} r="7" fill="var(--water)" stroke="var(--paper)" strokeWidth="2.5" />
      </svg>
      <div className="pointer-events-none mt-1 text-right font-mono text-[11px] text-(--ink-soft)" aria-live="polite">
        {hover !== null ? "hover" : "selected"} · exposure {(shown / 100).toFixed(1)}% → fill {(shownFill * 100).toFixed(1)}%
      </div>
    </div>
  );
}

function GateSimulator() {
  const live = useLiveExposure();
  const reserves = useStrategyReserves();
  const { deployment } = useDeployment();
  const [profileIdx, setProfileIdx] = useState(1);
  const [sim, setSim] = useState(7000);
  const [amount, setAmount] = useState("10");

  const profile = PROFILES[profileIdx];
  const isDeployed = deployment && profile.max === deployment.maxExposureBps && profile.halt === deployment.haltExposureBps;
  const band = exposureBand(sim, profile.max, profile.halt);
  const fill = fillFraction(sim, profile.max, profile.halt);

  const outcome = useMemo(() => {
    if (!reserves || !amount || Number(amount) <= 0) return null;
    try {
      const amountWei = parseUnits(amount, reserves.decimals);
      const ungated = xycAmountOut(amountWei, reserves.balanceIn, reserves.balanceOut);
      const gated = applyExposureGate(ungated, BigInt(sim), BigInt(profile.max), BigInt(profile.halt));
      return { ungated, ...gated };
    } catch {
      return null;
    }
  }, [reserves, amount, sim, profile]);

  const fee = predictedFeePips(sim);

  return (
    <section className="mx-auto mt-14 max-w-6xl px-4 sm:px-6">
      <Reveal className="panel overflow-hidden">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-(--line) px-5 py-4 sm:px-6">
          <div>
            <p className="eyebrow">Simulation · same math as ExposureGate.sol (lib/xyc.ts)</p>
            <h2 className="panel-title mt-1 text-xl!">Move the reading. Watch the gate.</h2>
          </div>
          <div className="flex flex-wrap gap-1.5" role="group" aria-label="Risk profile">
            {PROFILES.map((p, i) => (
              <button
                key={p.name}
                onClick={() => setProfileIdx(i)}
                aria-pressed={profileIdx === i}
                className={`rounded-full border px-3 py-1 font-mono text-[11px] transition-all duration-300 ${
                  profileIdx === i ? "border-(--water) bg-(--water) text-white" : "border-(--line-strong) text-(--ink-soft) hover:border-(--water)"
                }`}
              >
                {p.name} {p.max / 100}/{p.halt / 100}
              </button>
            ))}
          </div>
        </div>

        <div className="grid gap-0 lg:grid-cols-[1.25fr_1fr]">
          <div className="border-b border-(--line) p-4 sm:p-6 lg:border-r lg:border-b-0">
            <div className="lg:sticky lg:top-24">
            <AqueductScene fill={fill} className="h-auto w-full" />
            <div className="mt-4">
              <label htmlFor="sim-exposure" className="flex items-baseline justify-between text-sm">
                <span className="font-medium">Simulated exposure reading</span>
                <span className="display text-3xl" style={{ color: BAND_META[band].color }}>
                  {(sim / 100).toFixed(1)}%
                </span>
              </label>
              <input
                id="sim-exposure"
                type="range"
                min={0}
                max={10000}
                step={50}
                value={sim}
                onChange={(e) => setSim(Number(e.target.value))}
                className="lever mt-3"
                style={{ "--max": `${profile.max / 100}%`, "--halt-at": `${profile.halt / 100}%` } as CSSProperties}
              />
              <div className="mt-3 flex flex-wrap gap-2">
                {live.bps !== null && (
                  <button onClick={() => setSim(live.bps!)} className="btn btn-ghost py-1! text-xs!">
                    <span className="live-dot" style={{ color: live.band ? BAND_META[live.band].color : undefined }} />
                    Use live reading ({(live.bps / 100).toFixed(1)}%)
                  </button>
                )}
                <button onClick={() => setSim(10000)} className="btn btn-ghost py-1! text-xs!">
                  Malicious 100%
                </button>
              </div>
            </div>
            </div>
          </div>

          <div className="flex flex-col gap-5 p-4 sm:p-6">
            <DerateCurve max={profile.max} halt={profile.halt} sim={sim} live={live.bps} onPick={setSim} />

            <div className="rounded-xl border border-(--line) bg-(--paper) p-4">
              <div className="flex items-center justify-between gap-3 text-sm">
                <span className="text-(--ink-soft)">Reference swap</span>
                <span className="flex items-center gap-2">
                  <input
                    type="number"
                    min={0}
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    className="field w-24 py-1!"
                    aria-label="Reference swap amount"
                  />
                  <span className="font-mono text-xs">{reserves?.symbolIn ?? "tokenIn"}</span>
                </span>
              </div>
              <dl className="mt-4 grid grid-cols-2 gap-3 font-mono text-sm">
                <div>
                  <dt className="eyebrow">Ungated curve</dt>
                  <dd className="mt-1 break-all">{outcome ? Number(formatUnits(outcome.ungated, reserves!.decimals)).toFixed(4) : "…"}</dd>
                </div>
                <div>
                  <dt className="eyebrow">Gated fill</dt>
                  <dd className="mt-1 break-all font-semibold" style={{ color: BAND_META[band].color }}>
                    {!outcome ? "…" : outcome.halted ? "REVERTS" : Number(formatUnits(outcome.amountOut, reserves!.decimals)).toFixed(4)}
                  </dd>
                </div>
              </dl>
              <p className="mt-3 text-xs text-(--ink-faint)">
                {reserves ? `${reserves.symbolOut} out, priced from Strategy A's live Aqua reserves.` : "Loading Strategy A's live Aqua reserves…"}{" "}
                Gated is never above ungated, whatever the reading.
              </p>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-xl border border-(--line) p-4">
                <p className="eyebrow">Gate band</p>
                <p className="mt-2 text-sm font-semibold" style={{ color: BAND_META[band].color }}>
                  {band === "safe" ? "●" : band === "derate" ? "◐" : "■"} {BAND_META[band].long}
                </p>
              </div>
              <div className="rounded-xl border border-(--line) p-4">
                <p className="eyebrow">v4 dynamic fee</p>
                <p className="mt-2 font-mono text-sm font-semibold text-(--plum)">
                  {fee} pips · {feePipsToPercent(fee)}
                </p>
              </div>
            </div>
            <p className="font-mono text-[11px] text-(--ink-faint)">
              {isDeployed ? "Normal 50/90 is what the live demo maker chose." : "Illustrative profile. The live maker uses 50/90."} Click the
              curve to set a reading.
            </p>
          </div>
        </div>
      </Reveal>
    </section>
  );
}

const PIPELINE = [
  { t: "Aqua", k: "on-chain", d: "The maker commits balances to every strategy via ship / pull." },
  { t: "The Graph", k: "subgraph", d: "ExposurePosition joins commitments, oracle readings and v4 swaps." },
  { t: "Keeper", k: "off-chain", d: "keeper/pushExposure.ts sums the maker's commitments and pushes one reading." },
  { t: "ExposureOracle", k: "on-chain", d: "Only the keeper can write. Stale readings revert. The maker can pause." },
  { t: "_exposureGate1D", k: "SwapVM opcode", d: "Derates or halts the fill. Never improves it." },
];

function Pipeline() {
  return (
    <section className="mx-auto mt-32 max-w-6xl px-4 sm:px-6">
      <SectionHead numeral="II" eyebrow="The pipeline" title="From scattered commitments to one reading.">
        The risk calculation stays off the swap path, and only its result lands on-chain. The gate trusts the
        oracle only to make fills smaller.
      </SectionHead>
      <ol className="mt-12 grid gap-0 lg:grid-cols-5">
        {PIPELINE.map((s, i) => (
          <Reveal as="li" key={s.t} delay={i * 110} className="relative flex lg:flex-col">
            <div className="flex flex-col items-center lg:flex-row">
              <span className="grid h-11 w-11 shrink-0 place-items-center rounded-full border-2 border-(--water) bg-(--paper) font-mono text-sm text-(--water)">
                {i + 1}
              </span>
              {i < PIPELINE.length - 1 && (
                <svg className="h-full min-h-14 w-3 lg:h-3 lg:min-h-0 lg:w-full" preserveAspectRatio="none" viewBox="0 0 100 100" aria-hidden>
                  <path d="M50 0 V100" className="lg:hidden" stroke="var(--water)" strokeWidth="6" strokeDasharray="10 14" vectorEffect="non-scaling-stroke" />
                  <path d="M0 50 H100" className="hidden lg:block flow-dash" stroke="var(--water)" strokeWidth="2.5" strokeDasharray="6 8" vectorEffect="non-scaling-stroke" />
                </svg>
              )}
            </div>
            <div className="pb-8 pl-4 lg:pl-0 lg:pr-5 lg:pt-5">
              <p className="eyebrow">{s.k}</p>
              <p className="mt-1 font-mono text-[15px] font-semibold">{s.t}</p>
              <p className="mt-2 text-sm leading-relaxed text-(--ink-soft)">{s.d}</p>
            </div>
          </Reveal>
        ))}
      </ol>
      <Reveal className="mt-2 grid gap-4 sm:grid-cols-2">
        {[
          { t: "1inch SwapVM", d: "Direct swap, no pool. The maker's program runs with the gate inside it.", c: "var(--water)" },
          { t: "Uniswap v4 · AquaV4Hook", d: "The pool holds no liquidity of its own. Every fill is sourced live from the same strategy.", c: "var(--plum)" },
        ].map((v) => (
          <div key={v.t} className="panel flex gap-4 p-5">
            <span className="mt-1 h-10 w-1.5 shrink-0 rounded-full" style={{ background: v.c }} />
            <div>
              <p className="font-mono text-sm font-semibold">→ {v.t}</p>
              <p className="mt-1 text-sm text-(--ink-soft)">{v.d}</p>
            </div>
          </div>
        ))}
      </Reveal>
    </section>
  );
}

function Composition() {
  const steps = [
    { op: "_xycSwapXD", role: "prices the swap", detail: "constant product from live Aqua reserves", dir: "=", c: "var(--ink)" },
    { op: "_oraclePriceAdjuster1D", role: "can only improve", detail: "toward Chainlink ETH/USD, capped at +3%", dir: "↑", c: "var(--water)" },
    { op: "_exposureGate1D", role: "can only worsen", detail: "toward the maker's real risk, down to a halt", dir: "↓", c: "var(--halt)" },
  ];
  return (
    <section className="mx-auto mt-32 max-w-6xl px-4 sm:px-6">
      <SectionHead numeral="III" eyebrow="Strategy P · a sophisticated position" title="Bounded from both directions.">
        One live program stacks three SwapVM instructions. The order matters: the derate applies on top of the
        price adjustment, so a favorable price reading can never get past a halt.
      </SectionHead>
      <div className="mt-12 grid gap-4 md:grid-cols-3">
        {steps.map((s, i) => (
          <Reveal key={s.op} delay={i * 140} className="panel relative p-6">
            <div className="flex items-center justify-between">
              <span className="eyebrow">Instruction {i + 1}</span>
              <span className="display text-4xl" style={{ color: s.c }}>
                {s.dir}
              </span>
            </div>
            <p className="mt-5 break-all font-mono text-base font-semibold">{s.op}</p>
            <p className="mt-2 text-sm font-medium" style={{ color: s.c }}>
              {s.role}
            </p>
            <p className="mt-1 text-sm text-(--ink-soft)">{s.detail}</p>
          </Reveal>
        ))}
      </div>
      <Reveal className="mt-8">
        <div className="relative h-16 rounded-xl border border-(--line) bg-(--paper)">
          <div className="absolute inset-y-4 left-[6%] right-[30%] rounded-l-full bg-[linear-gradient(90deg,var(--halt),var(--derate)_60%,var(--line))] opacity-80" />
          <div className="absolute inset-y-4 left-[70%] right-[22%] rounded-r-full bg-(--water) opacity-80" />
          <span className="absolute top-1/2 left-[70%] h-10 w-0.5 -translate-y-1/2 bg-(--ink)" />
          <span className="absolute -bottom-6 left-[70%] -translate-x-1/2 font-mono text-[10px] text-(--ink-soft)">curve price</span>
          <span className="absolute -bottom-6 left-[78%] -translate-x-1/2 font-mono text-[10px] text-(--water)">+3% cap</span>
          <span className="absolute -bottom-6 left-[6%] font-mono text-[10px] text-(--halt)">halt</span>
        </div>
        <p className="mt-10 font-mono text-[11px] text-(--ink-faint)">
          Schematic, not to scale. Proof: test/SophisticatedPosition.t.sol · live strategy hash 0xe3f9…cd88
        </p>
      </Reveal>
    </section>
  );
}

function VenueIndependence() {
  return (
    <section className="mx-auto mt-32 max-w-6xl px-4 sm:px-6">
      <SectionHead numeral="IV" eyebrow="Why it isn't just a v4 hook" title="The policy travels with the liquidity.">
        A normal hook bakes its logic into one pool. Here the risk limit lives at the Aqua strategy layer, so the
        same policy gates any venue that reaches that liquidity.
      </SectionHead>
      <div className="mt-12 grid gap-5 md:grid-cols-2">
        <Reveal className="panel p-6">
          <p className="eyebrow text-(--water)!">Aqueduct</p>
          <svg viewBox="0 0 320 170" className="mt-4 h-auto w-full" aria-label="Risk policy above the Aqua strategy, branching to SwapVM, Uniswap v4 and any future venue">
            <rect x="110" y="6" width="100" height="28" rx="6" fill="var(--ink)" />
            <text x="160" y="25" textAnchor="middle" className="fill-(--paper) font-mono text-[11px]">risk policy</text>
            <rect x="70" y="56" width="180" height="28" rx="6" fill="var(--water)" />
            <text x="160" y="75" textAnchor="middle" className="fill-white font-mono text-[11px]">Aqua strategy / SwapVM</text>
            <path d="M160 34V56M160 84v20M50 104H270M50 104v22M160 104v22M270 104v22" stroke="var(--water)" strokeWidth="2" fill="none" strokeDasharray="5 5" className="flow-dash" />
            {[
              { x: 50, t: "SwapVM" },
              { x: 160, t: "Uniswap v4" },
              { x: 270, t: "future venue" },
            ].map((v) => (
              <g key={v.t}>
                <rect x={v.x - 46} y="128" width="92" height="28" rx="6" fill="none" stroke="var(--ink)" strokeDasharray={v.t === "future venue" ? "4 3" : undefined} />
                <text x={v.x} y="147" textAnchor="middle" className="fill-(--ink) font-mono text-[11px]">{v.t}</text>
              </g>
            ))}
          </svg>
        </Reveal>
        <Reveal delay={120} className="panel panel-dashed p-6">
          <p className="eyebrow">A normal hook</p>
          <svg viewBox="0 0 320 170" className="mt-4 h-auto w-full" aria-label="Uniswap pool with hard-coded hook logic that dies with the pool">
            <rect x="100" y="30" width="120" height="28" rx="6" fill="none" stroke="var(--ink-faint)" />
            <text x="160" y="49" textAnchor="middle" className="fill-(--ink-soft) font-mono text-[11px]">Uniswap pool</text>
            <path d="M160 58v30" stroke="var(--ink-faint)" strokeWidth="2" />
            <rect x="80" y="88" width="160" height="28" rx="6" fill="var(--paper-deep)" stroke="var(--ink-faint)" />
            <text x="160" y="107" textAnchor="middle" className="fill-(--ink-soft) font-mono text-[11px]">hard-coded hook logic</text>
            <text x="160" y="145" textAnchor="middle" className="fill-(--halt) font-mono text-[11px]">dies with this one pool</text>
          </svg>
        </Reveal>
      </div>
      <Reveal className="mt-8">
        <a href={repoFile("src/hooks/AsyncLiquidityHook.sol")} target="_blank" rel="noreferrer" className="font-mono text-sm text-(--water) hover:underline">
          The reusable async-liquidity base behind AquaV4Hook ↗
        </a>
      </Reveal>
    </section>
  );
}

export function MechanismStory() {
  return (
    <>
      <section className="mx-auto max-w-6xl px-4 pt-14 sm:px-6 md:pt-20">
        <SectionHead numeral="I" eyebrow="Mechanism" title={<>A gate with no position above the rim.</>}>
          <code>_exposureGate1D</code> runs after the swap-pricing instruction. At or below{" "}
          <code>maxExposureBps</code> it does nothing. Between max and halt it scales the fill down linearly. At{" "}
          <code>haltExposureBps</code> or above it reverts. There is no branch where it can make the fill bigger.
        </SectionHead>
      </section>
      <GateSimulator />
      <Pipeline />
      <Composition />
      <VenueIndependence />
    </>
  );
}
