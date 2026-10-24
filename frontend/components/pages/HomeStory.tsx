"use client";

import Link from "next/link";
import { useState, type CSSProperties } from "react";
import { AqueductScene } from "@/components/site/AqueductScene";
import { CountUp, Reveal, SectionHead } from "@/components/site/Reveal";
import { useDeployment } from "@/lib/DeploymentProvider";
import { BAND_META, repoFile } from "@/lib/site";
import { useLiveExposure } from "@/lib/useLiveExposure";
import { fillFraction } from "@/lib/xyc";
import { exposureBand } from "@/lib/constants";

const PREVIEWS = [
  { key: "live", label: "Live oracle" },
  { key: 7000, label: "Preview 70%" },
  { key: 9500, label: "Preview 95%" },
] as const;

type PreviewKey = (typeof PREVIEWS)[number]["key"];

function Hero() {
  const live = useLiveExposure();
  const { deployment } = useDeployment();
  const [mode, setMode] = useState<PreviewKey>("live");

  const bps = mode === "live" ? live.bps : mode;
  const fill = bps === null ? 1 : fillFraction(bps, live.maxBps, live.haltBps);
  const band = bps === null ? null : exposureBand(bps, live.maxBps, live.haltBps);
  const short = deployment ? `${deployment.maker.slice(0, 6)}…${deployment.maker.slice(-4)}` : "…";

  return (
    <section className="relative overflow-hidden">
      <div className="mx-auto max-w-6xl px-4 pt-14 sm:px-6 md:pt-20">
        <Reveal>
          <p className="eyebrow">1inch Aqua · SwapVM · Uniswap v4 · The Graph — live on Base Sepolia</p>
        </Reveal>
        <Reveal delay={80}>
          <h1 className="display mt-5 max-w-4xl text-[clamp(2.75rem,8vw,6.5rem)]">
            Liquidity behind a gate that <span className="text-(--water) italic">only closes.</span>
          </h1>
        </Reveal>
        <Reveal delay={180}>
          <p className="mt-6 max-w-2xl text-lg leading-relaxed text-(--ink-soft)">
            Aqueduct adds <code>_exposureGate1D</code> to SwapVM. It reads a maker&apos;s live, cross-strategy
            exposure and derates or halts their fill, whether the swap goes direct through 1inch SwapVM or
            through a Uniswap v4 pool. A wrong, stale or malicious reading can only make the maker quote more
            conservatively. Never more.
          </p>
        </Reveal>
        <Reveal delay={260} className="mt-8 flex flex-wrap gap-3">
          <Link href="/mechanism" className="btn btn-aqua">
            See how the gate works →
          </Link>
          <Link href="/console" className="btn btn-ghost">
            Open the live console
          </Link>
        </Reveal>
      </div>

      <Reveal delay={200} className="mx-auto mt-10 max-w-6xl px-2 sm:px-6">
        <AqueductScene fill={fill} className="h-auto w-full" />
      </Reveal>

      <div className="mx-auto max-w-6xl px-4 sm:px-6">
        <div className="mt-2 flex flex-col gap-4 border-t border-(--line) pt-5 md:flex-row md:items-center md:justify-between">
          <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Gate reading">
            {PREVIEWS.map((p) => (
              <button
                key={p.key}
                onClick={() => setMode(p.key)}
                aria-pressed={mode === p.key}
                className={`rounded-full border px-3.5 py-1.5 font-mono text-xs transition-all duration-300 ${
                  mode === p.key
                    ? "border-(--ink) bg-(--ink) text-(--paper)"
                    : "border-(--line-strong) text-(--ink-soft) hover:border-(--ink)"
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>
          <p className="font-mono text-xs leading-relaxed text-(--ink-faint)">
            {mode === "live" ? (
              live.bps === null ? (
                "Reading ExposureOracle on Base Sepolia…"
              ) : (
                <>
                  <span className="live-dot mr-2 align-middle" style={{ color: band ? BAND_META[band].color : undefined }} />
                  LIVE · ExposureOracle reports <b className="text-(--ink)">{(live.bps / 100).toFixed(1)}%</b> for
                  maker {short} · derate above {live.maxBps / 100}%, halt at {live.haltBps / 100}%
                </>
              )
            ) : (
              <>
                PREVIEW · simulated reading of <b className="text-(--ink)">{(Number(mode) / 100).toFixed(0)}%</b>, same
                math as ExposureGate.sol · {band ? BAND_META[band].long : ""}
              </>
            )}
          </p>
        </div>
      </div>
    </section>
  );
}

const ILLUSTRATIVE = [
  { name: "Strategy A", pct: 60 },
  { name: "Strategy B", pct: 60 },
  { name: "Strategy C", pct: 60 },
];

function Problem() {
  return (
    <section className="mx-auto mt-28 max-w-6xl px-4 sm:px-6">
      <SectionHead numeral="I" eyebrow="The problem" title={<>Three honest checks. One over-committed maker.</>}>
        Aqua lets one wallet back several strategies at once. Each strategy checks its own commitment
        against the wallet and passes. Nothing looks at all of them together, so the maker can still be
        committed far beyond what they hold.
      </SectionHead>

      <Reveal className="mt-12 grid gap-6 md:grid-cols-[1fr_1fr]">
        <div className="panel p-6">
          <p className="eyebrow">Checked one by one</p>
          <ul className="mt-5 space-y-5">
            {ILLUSTRATIVE.map((s, i) => (
              <li key={s.name}>
                <div className="flex items-baseline justify-between text-sm">
                  <span className="font-medium">{s.name}</span>
                  <span className="font-mono text-xs text-(--safe)">✓ {s.pct}% of wallet · passes</span>
                </div>
                <div className="mt-2 h-3 overflow-hidden rounded-full bg-(--paper-deep)">
                  <div
                    className="bar h-full rounded-full bg-(--water)"
                    style={{ "--w": `${s.pct}%`, "--bd": `${250 + i * 180}ms` } as CSSProperties}
                  />
                </div>
              </li>
            ))}
          </ul>
        </div>
        <div className="panel p-6">
          <p className="eyebrow">Seen together</p>
          <p className="display mt-4 text-6xl text-(--halt)">
            <CountUp to={180} suffix="%" />
          </p>
          <p className="mt-1 text-sm text-(--ink-soft)">of the wallet committed in total</p>
          <div className="relative mt-6 h-3 rounded-full bg-(--paper-deep)">
            <div
              className="bar h-full rounded-full bg-[linear-gradient(90deg,var(--water)_0_55%,var(--halt)_55%)]"
              style={{ "--w": "100%", "--bd": "900ms" } as CSSProperties}
            />
            <span className="absolute -top-6 left-[55%] -translate-x-1/2 font-mono text-[10px] text-(--ink-faint)">
              wallet
            </span>
            <span className="absolute -bottom-1 left-[55%] h-5 w-px bg-(--ink)" />
          </div>
          <p className="mt-6 text-sm leading-relaxed text-(--ink-soft)">
            Aqueduct&apos;s oracle aggregates <em>every</em> strategy the maker has shipped, so each one is
            gated on the total, including strategies that look safe on their own.
          </p>
          <p className="mt-4 font-mono text-[11px] text-(--ink-faint)">
            Illustrative numbers, not live data. On-chain proof: test/MultiStrategyExposure.t.sol.
          </p>
        </div>
      </Reveal>
    </section>
  );
}

const PIECES = [
  {
    n: "①",
    title: "ExposureGate1D",
    tag: "a new SwapVM instruction",
    body: "Turns an off-chain exposure reading into a one-way limit on liquidity. It can derate or halt a fill and can never improve one.",
    file: "src/opcodes/ExposureGate.sol",
    glyph: (
      <g>
        <rect x="6" y="26" width="52" height="14" rx="2" fill="var(--mist)" />
        <rect x="27" y="6" width="10" height="30" rx="1.5" fill="var(--ink)" />
        <path d="M6 33h18" stroke="var(--water)" strokeWidth="3" />
        <path d="M40 36h18" stroke="var(--water)" strokeWidth="1.5" />
      </g>
    ),
  },
  {
    n: "②",
    title: "Exposure Oracle",
    tag: "a cross-strategy risk layer",
    body: "Works out how much liquidity a maker can safely expose right now, summed across every Aqua strategy they've shipped. A Graph subgraph and a keeper feed it.",
    file: "src/oracle/ExposureOracle.sol",
    glyph: (
      <g>
        <path d="M8 40a24 24 0 0 1 48 0" fill="none" stroke="var(--line-strong)" strokeWidth="6" />
        <path d="M8 40a24 24 0 0 1 24-24" fill="none" stroke="var(--safe)" strokeWidth="6" />
        <path d="M32 40l12-14" stroke="var(--ink)" strokeWidth="3" strokeLinecap="round" />
      </g>
    ),
  },
  {
    n: "③",
    title: "AquaV4Hook",
    tag: "execution that doesn't depend on the venue",
    body: "Offers the same Aqua liquidity, under the same exposure limit, through a Uniswap v4 pool. The risk policy belongs to the strategy, not to any one pool.",
    file: "src/hooks/AquaV4Hook.sol",
    glyph: (
      <g>
        <path d="M32 6v14" stroke="var(--water)" strokeWidth="4" />
        <path d="M32 20c0 10-18 8-18 22M32 20c0 10 18 8 18 22" fill="none" stroke="var(--water)" strokeWidth="4" />
        <rect x="6" y="42" width="16" height="10" rx="2" fill="var(--ink)" />
        <rect x="42" y="42" width="16" height="10" rx="2" fill="var(--plum)" />
      </g>
    ),
  },
];

function Pieces() {
  return (
    <section className="mx-auto mt-32 max-w-6xl px-4 sm:px-6">
      <SectionHead numeral="II" eyebrow="Three pieces, nothing else" title="Gate. Oracle. Hook.">
        Everything in the repo supports exactly three components, not a pile of loosely related features.
      </SectionHead>
      <div className="mt-12 grid gap-5 md:grid-cols-3">
        {PIECES.map((p, i) => (
          <Reveal key={p.title} delay={i * 120} as="article" className="panel group flex flex-col p-6 hover:-translate-y-1">
            <div className="flex items-start justify-between">
              <svg width="64" height="56" viewBox="0 0 64 56" aria-hidden className="transition-transform duration-500 group-hover:scale-110">
                {p.glyph}
              </svg>
              <span className="numeral text-3xl">{p.n}</span>
            </div>
            <h3 className="display mt-6 text-2xl">{p.title}</h3>
            <p className="eyebrow mt-1">{p.tag}</p>
            <p className="mt-4 flex-1 text-sm leading-relaxed text-(--ink-soft)">{p.body}</p>
            <a
              href={repoFile(p.file)}
              target="_blank"
              rel="noreferrer"
              className="mt-6 inline-flex items-center gap-1 font-mono text-xs text-(--water) hover:underline"
            >
              {p.file} ↗
            </a>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

const FAILURES = [
  "Unauthorized write",
  "Wrong or malicious reading",
  "Stale reading",
  "Keeper stops entirely",
  "Maker distrusts the feed",
  "Exposure ≥ halt threshold",
  "Exposure between max and halt",
  "Over-committed across strategies",
];

function FailsClosed() {
  return (
    <section className="mt-32 bg-(--ink) py-24 text-(--paper)">
      <div className="mx-auto max-w-6xl px-4 sm:px-6">
        <Reveal>
          <p className="eyebrow text-[#a99b83]!">III · The one property</p>
          <h2 className="display mt-5 max-w-4xl text-[clamp(2.5rem,6vw,5rem)]">
            Every failure mode <span className="text-(--water-bright)">fails closed.</span>
          </h2>
          <p className="mt-6 max-w-2xl text-[15px] leading-relaxed text-[#cfc3ad]">
            Not &ldquo;degrades gracefully&rdquo;. Every way this system can go wrong ends in a strictly smaller fill or no
            fill at all, never in a taker getting more than the maker&apos;s own unsigned program authorized.
          </p>
        </Reveal>
        <ul className="mt-12 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {FAILURES.map((f, i) => (
            <Reveal as="li" key={f} delay={i * 60}>
              <Link
                href="/safety"
                className="flex h-full items-center justify-between gap-3 rounded-xl border border-[#3a342b] px-4 py-4 text-sm transition-colors duration-300 hover:border-(--water-bright) hover:bg-[#1f1c16]"
              >
                <span>{f}</span>
                <span className="shrink-0 font-mono text-[10px] text-(--water-bright)">CLOSED</span>
              </Link>
            </Reveal>
          ))}
        </ul>
        <Reveal className="mt-10">
          <Link href="/safety" className="font-mono text-sm text-(--water-bright) hover:underline">
            Read the full threat model →
          </Link>
        </Reveal>
      </div>
    </section>
  );
}

function LiveFacts() {
  const { deployment } = useDeployment();
  const strategies = (deployment?.strategies?.length ?? 1) + (deployment?.sophisticatedPosition ? 1 : 0);
  const pools = (deployment?.v4 ? 1 : 0) + (deployment?.dynamicFeePool ? 1 : 0);

  const facts = [
    { value: strategies, label: "maker strategies shipped", note: "A, B, C + Strategy P" },
    { value: pools, label: "Uniswap v4 pools sourced from Aqua", note: "static fee + risk-adjusted fee" },
    { value: 1555, label: "pips fee at 10% exposure", note: "verified on-chain, dynamic-fee pool" },
    { value: 7888, label: "pips fee at 70% exposure", note: "same pool, same formula" },
  ];

  return (
    <section className="mx-auto mt-32 max-w-6xl px-4 sm:px-6">
      <SectionHead numeral="IV" eyebrow="Live on Base Sepolia · chain 84532" title="Really deployed, really exercised.">
        Every contract is live on testnet, and both venues were each verified with a real swap transaction. The
        numbers below come from <code>deployment.json</code> and the README&apos;s on-chain verification.
      </SectionHead>
      <div className="mt-12 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border border-(--line) bg-(--line) lg:grid-cols-4">
        {facts.map((f, i) => (
          <Reveal key={f.label} delay={i * 90} className="bg-(--paper) p-6">
            <p className="display text-5xl text-(--water) md:text-6xl">{deployment ? <CountUp to={f.value} /> : "—"}</p>
            <p className="mt-3 text-sm font-medium">{f.label}</p>
            <p className="mt-1 font-mono text-[11px] text-(--ink-faint)">{f.note}</p>
          </Reveal>
        ))}
      </div>

      <div className="mt-16 grid gap-5 md:grid-cols-3">
        {[
          { href: "/mechanism", t: "Mechanism", d: "Drag the gate yourself. Same derate math as the contract." },
          { href: "/proof", t: "Live proof", d: "Subgraph, oracle and reserves: the same number on both venues." },
          { href: "/console", t: "Console", d: "Connect a wallet, push readings, swap on both venues." },
        ].map((c, i) => (
          <Reveal key={c.href} delay={i * 100}>
            <Link href={c.href} className="panel group block p-6">
              <p className="eyebrow">Next</p>
              <p className="display mt-3 flex items-center justify-between text-3xl">
                {c.t}
                <span className="text-(--water) transition-transform duration-500 group-hover:translate-x-1.5">→</span>
              </p>
              <p className="mt-3 text-sm text-(--ink-soft)">{c.d}</p>
            </Link>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

export function HomeStory() {
  return (
    <>
      <Hero />
      <Problem />
      <Pieces />
      <FailsClosed />
      <LiveFacts />
    </>
  );
}
