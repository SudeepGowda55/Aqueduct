"use client";

import { Fragment, type CSSProperties } from "react";
import { useReveal } from "@/lib/motion";

/// Headline words rise out of their own masks, staggered, once the line scrolls into view.
/// Spaces stay OUTSIDE the masks so words never glue together.
export function SplitWords({ text, className = "", delay = 0 }: { text: string; className?: string; delay?: number }) {
  const ref = useReveal<HTMLSpanElement>();
  const words = text.split(" ");
  return (
    <span ref={ref} className={`split ${className}`} aria-label={text}>
      {words.map((w, i) => (
        <Fragment key={i}>
          <span className="split-mask" aria-hidden>
            <span className="split-word" style={{ "--i": i, "--d0": `${delay}ms` } as CSSProperties}>
              {w}
            </span>
          </span>
          {i < words.length - 1 ? " " : ""}
        </Fragment>
      ))}
    </span>
  );
}
