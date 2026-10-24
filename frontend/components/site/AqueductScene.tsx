"use client";

import { useId } from "react";
import { useEased } from "@/lib/motion";

/**
 * The project's metaphor, drawn: Aqua liquidity is water in the channel, `_exposureGate1D` is
 * the sluice gate, and the two outlets are the two execution venues. The gate can only ever drop
 * INTO the channel -- there is no position above the rim -- which is the monotonicity property:
 * downstream flow can be reduced or stopped, never increased.
 *
 * `fill` is the derate factor (1 = full fill, 0 = halted), computed by the caller from a real
 * (or explicitly simulated) exposure reading.
 */

const W = 1200;
const BED = 222; // channel floor
const DEPTH = 58; // full water depth
const CH_X0 = 0;
const CH_X1 = 960;
const GATE_X = 500;

function archesPath(x0: number, x1: number, bay: number, top: number, bottom: number, spring: number, inset: number): string {
  let d = `M${x0} ${top} H${x1} V${bottom} H${x0} Z`;
  for (let x = x0; x + bay <= x1 + 0.5; x += bay) {
    const a = x + inset;
    const b = x + bay - inset;
    const r = (b - a) / 2;
    d += ` M${a} ${bottom - (bottom === 520 ? 0 : 8)} V${spring} A${r} ${r} 0 0 1 ${b} ${spring} V${bottom - (bottom === 520 ? 0 : 8)} Z`;
  }
  return d;
}

const UPPER = archesPath(CH_X0, CH_X1, 80, 238, 304, 276, 12);
const LOWER = archesPath(CH_X0, CH_X1, 160, 304, 520, 392, 24);

function wave(y: number, amp: number): string {
  // 2400px of sine, wavelength 60, closed down to the bed so it can be a filled shape.
  let d = `M-240 ${BED} V${y}`;
  for (let x = -240; x < 2400; x += 60) {
    d += ` q15 ${-amp} 30 0 t30 0`;
  }
  return d + ` V${BED} Z`;
}

export function AqueductScene({
  fill,
  caption,
  className = "",
  showLabels = true,
}: {
  fill: number;
  caption?: string;
  className?: string;
  showLabels?: boolean;
}) {
  const uid = useId().replace(/:/g, "");
  const f = useEased(Math.max(0, Math.min(1, fill)), 0.06);
  const halted = fill <= 0;

  const upTop = BED - DEPTH;
  const downTop = BED - DEPTH * f;
  // Gate plate bottom sits on the downstream surface; fully down means it seals on the bed.
  const plateBottom = BED - (DEPTH + 6) * f;
  const streamW = 3 + 15 * f;
  const basinLevel = 26 * f;

  return (
    <svg
      viewBox={`0 0 ${W} 560`}
      className={className}
      role="img"
      aria-label={`Aqueduct diagram: liquidity flows through the exposure gate at ${Math.round(fill * 100)}% of its ungated amount${halted ? " — halted, swaps revert" : ""}, into the SwapVM and Uniswap v4 outlets equally.`}
    >
      <defs>
        <linearGradient id={`water-${uid}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#4fb8bb" />
          <stop offset="1" stopColor="#1c7c84" />
        </linearGradient>
        <linearGradient id={`stone-${uid}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#e8dcc4" />
          <stop offset="1" stopColor="#d6c6a8" />
        </linearGradient>
        <pattern id={`course-${uid}`} width="64" height="22" patternUnits="userSpaceOnUse">
          <path d="M0 21.5H64M32 0V22" stroke="#c2b08f" strokeWidth="1" opacity="0.55" />
        </pattern>
        <clipPath id={`up-${uid}`}>
          <rect x={CH_X0} y={upTop - 12} width={GATE_X - CH_X0} height={DEPTH + 12} />
        </clipPath>
        <clipPath id={`down-${uid}`}>
          <rect x={GATE_X + 14} y={upTop - 12} width={CH_X1 - GATE_X - 14} height={DEPTH + 12} />
        </clipPath>
      </defs>

      {/* Ground */}
      <path d={`M0 520 H${W}`} stroke="var(--line-strong)" strokeWidth="1.5" />
      <path d={`M0 528 H${W}`} stroke="var(--line)" strokeWidth="1" strokeDasharray="2 8" />

      {/* Arcades */}
      <path d={LOWER} fill={`url(#stone-${uid})`} fillRule="evenodd" />
      <path d={LOWER} fill={`url(#course-${uid})`} fillRule="evenodd" />
      <path d={UPPER} fill={`url(#stone-${uid})`} fillRule="evenodd" />
      <path d={UPPER} fill={`url(#course-${uid})`} fillRule="evenodd" />
      <rect x={CH_X0} y={300} width={CH_X1 - CH_X0} height={8} fill="#c7b493" />

      {/* Channel walls + bed */}
      <rect x={CH_X0} y={140} width={CH_X1 - CH_X0} height={98} fill={`url(#stone-${uid})`} />
      <rect x={CH_X0} y={150} width={CH_X1 - CH_X0} height={BED - 150} fill="#cfc0a2" />
      <rect x={CH_X0} y={136} width={CH_X1 - CH_X0 + 6} height={8} rx="2" fill="#bfab88" />

      {/* Water: upstream always full (the maker's committed Aqua liquidity) */}
      <g clipPath={`url(#up-${uid})`}>
        <path d={wave(upTop, 5)} fill={`url(#water-${uid})`} className="flow-x-slow" />
        <path d={wave(upTop + 5, 3)} fill="#ffffff" opacity="0.12" className="flow-x" />
      </g>
      {/* Water: downstream, scaled by the gate */}
      <g clipPath={`url(#down-${uid})`}>
        <path d={wave(downTop, 4 * f + 0.5)} fill={`url(#water-${uid})`} className="flow-x" opacity={f > 0.01 ? 1 : 0} />
      </g>

      {/* Outlets: two streams, one source -- they always carry the same flow */}
      <g opacity={f > 0.01 ? 1 : 0} style={{ transition: "opacity .6s" }}>
        {[
          `M${CH_X1} ${downTop + 4} C${CH_X1 + 50} ${downTop} ${1030} 330 ${1030} 470`,
          `M${CH_X1} ${downTop + 4} C${CH_X1 + 120} ${downTop} ${1140} 330 ${1140} 470`,
        ].map((d, i) => (
          <g key={i}>
            <path d={d} fill="none" stroke={`url(#water-${uid})`} strokeWidth={streamW} strokeLinecap="round" />
            <path d={d} fill="none" stroke="#e9fbf9" strokeWidth={Math.max(1, streamW / 4)} strokeDasharray="6 14" strokeLinecap="round" className="fall" opacity="0.8" />
          </g>
        ))}
      </g>

      {/* Basins */}
      {[
        { x: 985, label: "1inch SwapVM", sub: "direct swap" },
        { x: 1095, label: "Uniswap v4", sub: "AquaV4Hook" },
      ].map((b) => (
        <g key={b.label}>
          <rect x={b.x} y={470} width={90} height={50} rx="4" fill="#d9caad" />
          <rect x={b.x + 6} y={514 - basinLevel} width={78} height={basinLevel} fill={`url(#water-${uid})`} />
          <rect x={b.x} y={466} width={90} height={7} rx="2" fill="#bfab88" />
          {showLabels && (
            <>
              <text x={b.x + 45} y={548} textAnchor="middle" className="fill-(--ink) font-mono text-[15px] font-semibold">
                {b.label}
              </text>
            </>
          )}
        </g>
      ))}

      {/* Sluice gate: frame, wheel, plate */}
      <g>
        <rect x={GATE_X - 18} y={44} width={12} height={196} fill="#a8946f" />
        <rect x={GATE_X + 20} y={44} width={12} height={196} fill="#a8946f" />
        <rect x={GATE_X - 30} y={36} width={74} height={14} rx="3" fill="var(--ink)" />
        <g transform={`rotate(${(1 - f) * 540} ${GATE_X + 7} 22)`}>
          <circle cx={GATE_X + 7} cy={22} r={16} fill="none" stroke="var(--ink)" strokeWidth="3" />
          {[0, 60, 120].map((a) => (
            <path key={a} d={`M${GATE_X + 7} 6 V38`} stroke="var(--ink)" strokeWidth="2.5" transform={`rotate(${a} ${GATE_X + 7} 22)`} />
          ))}
        </g>
        <rect x={GATE_X + 3} y={50} width={8} height={Math.max(0, plateBottom - 160)} fill="#6c6252" />
        <rect x={GATE_X - 6} y={plateBottom - 112} width={26} height={112} rx="2" fill="var(--ink)" />
        <path d={`M${GATE_X - 6} ${plateBottom - 80} H${GATE_X + 20} M${GATE_X - 6} ${plateBottom - 44} H${GATE_X + 20}`} stroke="#3d362d" strokeWidth="2" />
        <rect x={GATE_X - 6} y={plateBottom - 4} width={26} height={4} fill={halted ? "var(--halt)" : f < 1 ? "var(--derate)" : "var(--safe)"} />
      </g>

      {showLabels && (
        <g className="font-mono text-[15px]">
          <text x={24} y={120} className="fill-(--ink-faint)">AQUA STRATEGY · MAKER LIQUIDITY →</text>
          <text x={GATE_X + 46} y={78} className="fill-(--ink) font-semibold">_exposureGate1D</text>
          <text x={GATE_X + 46} y={100} className="fill-(--ink-faint)">only ever lowers</text>
          <text
            x={CH_X1}
            y={120}
            textAnchor="end"
            className={halted ? "fill-(--halt) font-semibold" : "fill-(--ink) font-semibold"}
          >
            {halted ? "HALTED · SWAPS REVERT" : `DOWNSTREAM FILL ${Math.round(f * 100)}%`}
          </text>
        </g>
      )}
      {caption && showLabels && (
        <text x={24} y={548} className="fill-(--ink-faint) font-mono text-[13px]">
          {caption}
        </text>
      )}
    </svg>
  );
}
