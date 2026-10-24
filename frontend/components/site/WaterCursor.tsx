"use client";

import { useEffect, useRef } from "react";
import { prefersReducedMotion } from "@/lib/motion";

/// A ring that trails the pointer like a ripple, swells over anything clickable, and drops a
/// ripple on click. Buttons are gently magnetic. Fine pointers only, never under reduced motion.
export function WaterCursor() {
  const ring = useRef<HTMLDivElement>(null);
  const dot = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (prefersReducedMotion() || !window.matchMedia("(pointer: fine)").matches) return;
    const r = ring.current!;
    const d = dot.current!;
    r.style.opacity = "1";
    d.style.opacity = "1";
    let x = innerWidth / 2,
      y = innerHeight / 2,
      rx = x,
      ry = y,
      scale = 1,
      targetScale = 1,
      frame = 0;
    let magnet: HTMLElement | null = null;

    const onMove = (e: PointerEvent) => {
      x = e.clientX;
      y = e.clientY;
      const el = e.target as HTMLElement;
      targetScale = el.closest("a, button, input, select, summary, [role=option]") ? 1.9 : 1;
      const btn = el.closest<HTMLElement>(".btn");
      if (magnet && magnet !== btn) magnet.style.transform = "";
      magnet = btn;
      if (btn) {
        const b = btn.getBoundingClientRect();
        btn.style.transform = `translate(${(x - (b.left + b.width / 2)) * 0.18}px, ${(y - (b.top + b.height / 2)) * 0.25}px)`;
      }
    };
    const onDown = (e: PointerEvent) => {
      const ripple = document.createElement("span");
      ripple.className = "cursor-ripple";
      ripple.style.left = `${e.clientX}px`;
      ripple.style.top = `${e.clientY}px`;
      document.body.appendChild(ripple);
      window.setTimeout(() => ripple.remove(), 800);
    };
    const loop = () => {
      rx += (x - rx) * 0.16;
      ry += (y - ry) * 0.16;
      scale += (targetScale - scale) * 0.15;
      r.style.transform = `translate(${rx}px, ${ry}px) translate(-50%, -50%) scale(${scale})`;
      d.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%)`;
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    addEventListener("pointermove", onMove, { passive: true });
    addEventListener("pointerdown", onDown, { passive: true });
    return () => {
      cancelAnimationFrame(frame);
      removeEventListener("pointermove", onMove);
      removeEventListener("pointerdown", onDown);
      if (magnet) magnet.style.transform = "";
    };
  }, []);

  return (
    <>
      <div ref={ring} className="cursor-ring" aria-hidden />
      <div ref={dot} className="cursor-dot" aria-hidden />
    </>
  );
}
