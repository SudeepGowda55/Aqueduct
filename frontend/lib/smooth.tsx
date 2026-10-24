"use client";

import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import Lenis from "lenis";
import { usePathname } from "next/navigation";
import { useEffect, type ReactNode } from "react";
import { prefersReducedMotion } from "./motion";

declare global {
  interface Window {
    __lenis?: Lenis;
  }
}

if (typeof window !== "undefined") gsap.registerPlugin(ScrollTrigger);

/// Lenis smooth scroll driven from gsap.ticker, with ScrollTrigger kept in sync. Skipped entirely
/// under prefers-reduced-motion (native scrolling, no scrub smoothing).
export function SmoothScroll({ children }: { children: ReactNode }) {
  const pathname = usePathname();

  useEffect(() => {
    if (prefersReducedMotion()) return;
    const lenis = new Lenis({ lerp: 0.085, wheelMultiplier: 0.9 });
    window.__lenis = lenis;
    lenis.on("scroll", ScrollTrigger.update);
    const tick = (time: number) => lenis.raf(time * 1000);
    gsap.ticker.add(tick);
    gsap.ticker.lagSmoothing(0);
    return () => {
      gsap.ticker.remove(tick);
      lenis.destroy();
      delete window.__lenis;
    };
  }, []);

  // New route: start at the top and re-measure every trigger against the new page's layout.
  useEffect(() => {
    window.__lenis?.scrollTo(0, { immediate: true, force: true });
    const id = requestAnimationFrame(() => ScrollTrigger.refresh());
    return () => cancelAnimationFrame(id);
  }, [pathname]);

  return <>{children}</>;
}
