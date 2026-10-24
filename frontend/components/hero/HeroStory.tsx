"use client";

import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import dynamic from "next/dynamic";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { AqueductScene } from "@/components/site/AqueductScene";
import { SplitWords } from "@/components/site/SplitWords";
import { exposureBand } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { prefersReducedMotion } from "@/lib/motion";
import { BAND_META } from "@/lib/site";
import { useLiveExposure } from "@/lib/useLiveExposure";
import { fillFraction } from "@/lib/xyc";
import { heroStore, storeExposure, storeFill } from "./heroStore";

if (typeof window !== "undefined") gsap.registerPlugin(ScrollTrigger);

// Start fetching the 3D chunk as soon as this module evaluates (in parallel with hydration),
// instead of waiting for the first render to request it.
const loadCanvas = () => import("./AqueductCanvas");
if (typeof window !== "undefined") void loadCanvas();
const AqueductCanvas = dynamic(loadCanvas, { ssr: false });

// Timeline segment lengths (GSAP "duration" units on a scrubbed timeline = share of the scroll).
const SEG = { move: 1, hold: 0.6 };
const STEPS = [
  {
    key: "safe",
    n: "01",
    eyebrow: "Simulated reading · 10%",
    title: "Safe: the gate stays out of the water.",
    body: "At or below maxExposureBps the opcode does nothing. The maker's program fills exactly as written.",
  },
  {
    key: "derate",
    n: "02",
    eyebrow: "Simulated reading · 70%",
    title: "Derated: the gate drops, the fill shrinks.",
    body: "Between 50% and 90% the fill scales down linearly. At 70% every taker gets half the ungated output. Never more.",
  },
  {
    key: "halt",
    n: "03",
    eyebrow: "Simulated reading · 95%",
    title: "Halted: both venues run dry at once.",
    body: "At 90% or above the swap reverts on SwapVM and Uniswap v4 alike. They share one gate, so they can't disagree.",
  },
  { key: "live", n: "04", eyebrow: "Back to the live oracle", title: "Now: the real reading, from Base Sepolia.", body: "" },
] as const;
const CHAPTER_KEYS = ["intro", ...STEPS.map((s) => s.key)];

// Where each chapter starts on the timeline (switch halfway through the move into it).
const BOUNDS = [0, 0.5, 0.5 + 1.6, 0.5 + 3.2, 0.5 + 4.8];
// 3 × (move + hold) + final move + 0.2 tail, matching the timeline built below.
const TOTAL = 3 * (SEG.move + SEG.hold) + SEG.move + 0.2;

function hasWebGL(): boolean {
  try {
    const c = document.createElement("canvas");
    return Boolean(c.getContext("webgl2") || c.getContext("webgl"));
  } catch {
    return false;
  }
}

function Hud() {
  const exp = useRef<HTMLSpanElement>(null);
  const fill = useRef<HTMLSpanElement>(null);
  const marker = useRef<HTMLSpanElement>(null);
  const tag = useRef<HTMLSpanElement>(null);
  const band = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    let frame = 0;
    let shown = storeExposure();
    const loop = () => {
      shown += (storeExposure() - shown) * 0.12;
      const f = fillFraction(shown, heroStore.maxBps, heroStore.haltBps);
      const b = exposureBand(shown, heroStore.maxBps, heroStore.haltBps);
      if (exp.current) exp.current.textContent = `${(shown / 100).toFixed(1)}%`;
      if (fill.current) fill.current.textContent = f <= 0 ? "REVERTS" : `${Math.round(f * 100)}%`;
      if (marker.current) marker.current.style.left = `${Math.min(100, shown / 100)}%`;
      if (tag.current) tag.current.textContent = heroStore.weight > 0.5 ? "SIMULATED" : "LIVE";
      if (band.current) {
        band.current.textContent = BAND_META[b].label;
        band.current.style.color = BAND_META[b].color;
      }
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  }, []);

  return (
    <div className="pointer-events-none w-full max-w-xs rounded-2xl border border-(--line) bg-(--paper)/95 p-4 font-mono text-[11px] text-(--ink-soft)">
      <div className="flex items-center justify-between">
        <span ref={tag} className="tracking-[0.18em]">LIVE</span>
        <span ref={band} className="font-semibold" />
      </div>
      <div className="mt-2 grid grid-cols-2 gap-2">
        <div>
          <div className="eyebrow">Exposure</div>
          <span ref={exp} className="display block text-3xl text-(--ink) tabular-nums" />
        </div>
        <div>
          <div className="eyebrow">Fill</div>
          <span ref={fill} className="display block text-3xl text-(--water) tabular-nums" />
        </div>
      </div>
      <div className="relative mt-3 h-1.5 rounded-full bg-[linear-gradient(90deg,var(--safe)_0_50%,var(--derate)_50%_90%,var(--halt)_90%)]">
        <span ref={marker} className="absolute top-1/2 h-3.5 w-1.5 -translate-x-1/2 -translate-y-1/2 rounded-sm bg-(--ink)" />
      </div>
    </div>
  );
}

export function HeroStory() {
  const live = useLiveExposure();
  const { deployment } = useDeployment();
  const section = useRef<HTMLElement>(null);
  const [chapter, setChapter] = useState(0);
  const [active, setActive] = useState(true);
  const [mode, setMode] = useState<"pending" | "webgl" | "svg" | "static">("pending");
  const [canvasReady, setCanvasReady] = useState(false);

  // Feed the real reading into the store.
  useEffect(() => {
    if (live.bps !== null) heroStore.live = live.bps;
    heroStore.maxBps = live.maxBps;
    heroStore.haltBps = live.haltBps;
  }, [live.bps, live.maxBps, live.haltBps]);

  useEffect(() => {
    const reduced = prefersReducedMotion();
    const id = requestAnimationFrame(() => setMode(reduced ? "static" : hasWebGL() ? "webgl" : "svg"));
    return () => cancelAnimationFrame(id);
  }, []);

  // One scrubbed timeline over the whole pinned section, tweening the plain store.
  useEffect(() => {
    if (mode === "pending" || mode === "static" || !section.current) return;
    heroStore.weight = 0;
    heroStore.cam = 0;
    heroStore.scripted = 1000;
    const tl = gsap.timeline({
      defaults: { ease: "power2.inOut" },
      scrollTrigger: {
        trigger: section.current,
        start: "top top",
        end: "bottom bottom",
        scrub: 0.8,
        onUpdate: (st) => {
          const t = st.progress * TOTAL;
          let idx = 0;
          for (let i = 0; i < BOUNDS.length; i++) if (t >= BOUNDS[i]) idx = i;
          setChapter((c) => (c === idx ? c : idx));
        },
      },
    });
    tl.to(heroStore, { weight: 1, scripted: 1000, cam: 1, duration: SEG.move })
      .to(heroStore, { duration: SEG.hold })
      .to(heroStore, { scripted: 7000, cam: 2, duration: SEG.move })
      .to(heroStore, { duration: SEG.hold })
      .to(heroStore, { scripted: 9500, cam: 3, duration: SEG.move })
      .to(heroStore, { duration: SEG.hold })
      .to(heroStore, { weight: 0, cam: 0.55, duration: SEG.move })
      .to(heroStore, { duration: 0.2 });

    const io = new IntersectionObserver(([e]) => setActive(e.isIntersecting), { rootMargin: "100px" });
    io.observe(section.current);
    return () => {
      io.disconnect();
      tl.scrollTrigger?.kill();
      tl.kill();
    };
  }, [mode]);

  const jump = (i: number) => {
    const el = section.current;
    if (!el) return;
    const span = el.offsetHeight - innerHeight;
    const y = el.offsetTop + span * ((BOUNDS[i] + (i ? SEG.move / 2 : 0)) / TOTAL);
    if (window.__lenis) window.__lenis.scrollTo(y, { duration: 1.6 });
    else scrollTo({ top: y, behavior: "smooth" });
  };

  const liveBand = live.band ? BAND_META[live.band] : null;
  const short = deployment ? `${deployment.maker.slice(0, 6)}…${deployment.maker.slice(-4)}` : "…";
  const isStatic = mode === "static";

  return (
    <section ref={section} className={isStatic ? "relative" : "relative h-[560vh]"} aria-label="How the exposure gate works, told in four steps">
      <div className={isStatic ? "relative flex flex-col-reverse pb-10" : "sticky top-0 h-svh overflow-hidden"}>
        {/* Stage */}
        <div className={isStatic ? "relative mx-auto max-w-6xl px-2" : "absolute inset-0"}>
          {mode === "webgl" && (
            <div className={`absolute inset-0 transition-opacity duration-1000 ${canvasReady ? "opacity-100" : "opacity-0"}`}>
              <AqueductCanvas active={active} onReady={() => setCanvasReady(true)} />
            </div>
          )}
          {(mode === "svg" || isStatic) && (
            <div className={isStatic ? "" : "absolute inset-x-0 bottom-[6vh] mx-auto max-w-5xl px-4 lg:left-[30%]"}>
              <SvgStage />
            </div>
          )}
        </div>

        {/* Legibility wash between the 3D stage and the copy */}
        {!isStatic && (
          <>
            <div className="pointer-events-none absolute inset-x-0 top-0 h-[60%] bg-[linear-gradient(180deg,var(--paper)_48%,transparent)] lg:hidden" />
            <div className="pointer-events-none absolute inset-y-0 left-0 hidden w-[52%] bg-[linear-gradient(90deg,rgba(246,241,231,0.9)_35%,transparent)] lg:block" />
          </>
        )}

        {/* Copy */}
        <div className={`${isStatic ? "relative" : "absolute inset-0"} pointer-events-none`}>
          <div className="mx-auto flex h-full max-w-6xl flex-col px-4 pt-24 pb-6 sm:px-6 md:pt-28 lg:justify-center lg:pt-16">
            <div className="relative max-w-xl lg:max-w-lg">
              {/* Intro */}
              <div className={`chapter ${chapter === 0 || isStatic ? "chapter-on" : ""}`}>
                <p className="eyebrow">1inch Aqua · SwapVM · Uniswap v4 · The Graph</p>
                <h1 className="display mt-4 text-[clamp(2.6rem,6.4vw,5.6rem)]">
                  <SplitWords text="Liquidity behind a gate that" />{" "}
                  <SplitWords text="only closes." className="text-(--water) italic" delay={420} />
                </h1>
                <p className="mt-5 max-w-md text-[15px] leading-relaxed text-(--ink-soft) md:text-base">
                  <code>_exposureGate1D</code> reads a maker&apos;s live exposure across every strategy and can only derate or
                  halt their fill, on 1inch SwapVM and Uniswap v4 alike.
                </p>
                <div className="pointer-events-auto mt-6 flex flex-wrap gap-3">
                  <Link href="/mechanism" className="btn btn-aqua">
                    See how the gate works →
                  </Link>
                  <Link href="/console" className="btn btn-ghost bg-(--paper)/70">
                    Open the console
                  </Link>
                </div>
              </div>

              {/* Story chapters */}
              {!isStatic &&
                STEPS.map((c, k) => {
                  const i = k + 1;
                  return (
                    <div key={c.key} className={`chapter chapter-abs ${chapter === i ? "chapter-on" : ""}`}>
                      <p className="eyebrow">
                        <span className="text-(--water)">{c.n}</span> · {c.eyebrow}
                      </p>
                      <h2 className="display mt-4 text-[clamp(2.2rem,5vw,4.4rem)]">{c.title}</h2>
                      <p className="mt-5 max-w-md text-[15px] leading-relaxed text-(--ink-soft) md:text-base">
                        {c.key === "live" ? (
                          live.bps === null ? (
                            "Reading ExposureOracle on Base Sepolia…"
                          ) : (
                            <>
                              <span className="live-dot mr-2 align-middle" style={{ color: liveBand?.color }} />
                              ExposureOracle reports <b className="text-(--ink)">{(live.bps / 100).toFixed(1)}%</b> for maker{" "}
                              {short}. That&apos;s {liveBand?.long.toLowerCase()}, on both venues.
                            </>
                          )
                        ) : (
                          c.body
                        )}
                      </p>
                      {c.key === "live" && (
                        <div className="pointer-events-auto mt-6 flex flex-wrap gap-3">
                          <Link href="/proof" className="btn btn-aqua">
                            See the live proof →
                          </Link>
                        </div>
                      )}
                    </div>
                  );
                })}
            </div>

            {!isStatic && (
              <div className="mt-auto flex items-end justify-between gap-4 lg:absolute lg:inset-x-6 lg:bottom-8 lg:mx-auto lg:max-w-6xl">
                <nav className="pointer-events-auto flex items-center gap-2" aria-label="Story steps">
                  {CHAPTER_KEYS.map((key, i) => (
                    <button
                      key={key}
                      onClick={() => jump(i)}
                      aria-label={`Go to step: ${key}`}
                      aria-current={chapter === i}
                      className={`h-2 rounded-full transition-all duration-500 ${chapter === i ? "w-9 bg-(--water)" : "w-2 bg-(--line-strong) hover:bg-(--ink-faint)"}`}
                    />
                  ))}
                  <span className={`ml-3 font-mono text-[11px] text-(--ink-faint) transition-opacity duration-500 ${chapter === 0 ? "opacity-100" : "opacity-0"}`}>
                    <span className="scroll-hint inline-block">↓</span> scroll to move the gate
                  </span>
                </nav>
                <div className="hidden sm:block">
                  <Hud />
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}

/// No-WebGL / reduced-motion stage: the SVG aqueduct, driven by the same store.
function SvgStage() {
  const [fill, setFill] = useState(1);
  useEffect(() => {
    let frame = 0;
    let last = -1;
    const loop = () => {
      const f = Math.round(storeFill() * 100) / 100;
      if (f !== last) {
        last = f;
        setFill(f);
      }
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  }, []);
  return <AqueductScene fill={fill} className="h-auto w-full" />;
}
