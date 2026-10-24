"use client";

import type { CSSProperties, ReactNode } from "react";
import { useCountUp, useReveal } from "@/lib/motion";

export function Reveal({
  children,
  delay = 0,
  className = "",
  as: Tag = "div",
}: {
  children: ReactNode;
  delay?: number;
  className?: string;
  as?: "div" | "section" | "li" | "article";
}) {
  const ref = useReveal<HTMLElement>();
  return (
    <Tag
      ref={ref as never}
      className={`reveal ${className}`}
      style={{ "--d": `${delay}ms` } as CSSProperties}
    >
      {children}
    </Tag>
  );
}

export function SectionHead({
  numeral,
  eyebrow,
  title,
  children,
}: {
  numeral: string;
  eyebrow: string;
  title: ReactNode;
  children?: ReactNode;
}) {
  return (
    <Reveal className="grid gap-4 md:grid-cols-[110px_1fr] md:gap-8">
      <div className="numeral text-6xl leading-none md:text-7xl" aria-hidden>
        {numeral}
      </div>
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h2 className="display mt-3 text-4xl text-(--ink) md:text-5xl">{title}</h2>
        {children && <div className="mt-4 max-w-2xl text-[15px] leading-relaxed text-(--ink-soft)">{children}</div>}
      </div>
    </Reveal>
  );
}

export function CountUp({ to, decimals = 0, suffix = "" }: { to: number; decimals?: number; suffix?: string }) {
  const { ref, value } = useCountUp(to);
  return (
    <span ref={ref} className="tabular-nums">
      {value.toLocaleString("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}
      {suffix}
    </span>
  );
}

/// A row of stone arches -- the section divider and footer motif.
export function ArchRow({ className = "", count = 12 }: { className?: string; count?: number }) {
  const w = 100;
  return (
    <svg
      viewBox={`0 0 ${count * w} 90`}
      preserveAspectRatio="none"
      className={className}
      aria-hidden
    >
      <path
        d={
          `M0 0 H${count * w} V90 ` +
          Array.from({ length: count }, (_, i) => {
            const x = (count - i) * w;
            return `H${x - 12} V62 A38 38 0 0 0 ${x - w + 12} 62 V90`;
          }).join(" ") +
          " H0 Z"
        }
        fill="currentColor"
      />
    </svg>
  );
}
