"use client";

import { useEffect, useRef } from "react";

/// A band of statements flowing like a channel. Scroll velocity (from Lenis) speeds it up and
/// leans it into the direction of travel.
export function Marquee({ items, dark = false }: { items: string[]; dark?: boolean }) {
  const track = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = track.current;
    if (!el) return;
    // Velocity measured from scrollY each frame (works with or without Lenis, which mounts after us).
    let skew = 0,
      last = scrollY,
      frame = 0;
    const loop = () => {
      const target = Math.max(-8, Math.min(8, (scrollY - last) * 0.25));
      last = scrollY;
      skew += (target - skew) * 0.1;
      el.style.setProperty("--skew", `${-skew}deg`);
      el.style.setProperty("--boost", `${1 + Math.abs(skew) / 3}`);
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  }, []);

  const row = (hidden: boolean) => (
    <div className="marquee-row" aria-hidden={hidden}>
      {items.map((t) => (
        <span key={t} className="flex items-center gap-8">
          <span>{t}</span>
          <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden>
            <path d="M2 12 Q9 2 16 12" fill="none" stroke="currentColor" strokeWidth="2" />
          </svg>
        </span>
      ))}
    </div>
  );

  return (
    <div className={`marquee ${dark ? "marquee-dark" : ""}`}>
      <div ref={track} className="marquee-track">
        {row(false)}
        {row(true)}
      </div>
    </div>
  );
}
