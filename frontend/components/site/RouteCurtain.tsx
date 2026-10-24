"use client";

import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { prefersReducedMotion } from "@/lib/motion";
import { NAV_LINKS } from "@/lib/site";

type Phase = "idle" | "cover" | "reveal";
const COVER_MS = 520;

/// Page transition: water floods up over the page, the destination's name surfaces, then the water
/// drains out the top revealing the new route. Only the fixed overlay animates -- never a page
/// wrapper -- so sticky/fixed elements inside pages are unaffected.
export function RouteCurtain() {
  const router = useRouter();
  const pathname = usePathname();
  const [phase, setPhase] = useState<Phase>("idle");
  const [label, setLabel] = useState("");

  // Intercept internal link clicks so the cover can play before navigation.
  useEffect(() => {
    if (prefersReducedMotion()) return;
    const onClick = (e: MouseEvent) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as HTMLElement).closest("a");
      if (!a || a.target === "_blank" || a.hasAttribute("download")) return;
      const url = new URL(a.href, location.href);
      if (url.origin !== location.origin || url.pathname === location.pathname) return;
      e.preventDefault();
      setLabel(NAV_LINKS.find((l) => l.href === url.pathname)?.label ?? "Aqueduct");
      setPhase("cover");
      window.setTimeout(() => router.push(url.pathname + url.search + url.hash), COVER_MS);
    };
    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
  }, [router]);

  // The new route has rendered: drain the water away.
  const [seenPath, setSeenPath] = useState(pathname);
  if (seenPath !== pathname) {
    setSeenPath(pathname);
    if (phase === "cover") setPhase("reveal");
  }
  useEffect(() => {
    if (phase !== "reveal") return;
    const id = window.setTimeout(() => setPhase("idle"), 900);
    return () => window.clearTimeout(id);
  }, [phase]);

  if (phase === "idle") return null;
  return (
    <div className={`curtain curtain-${phase}`} aria-hidden>
      <svg className="curtain-wave" viewBox="0 0 1200 40" preserveAspectRatio="none">
        <path d="M0 40 V20 Q75 0 150 20 T300 20 T450 20 T600 20 T750 20 T900 20 T1050 20 T1200 20 V40 Z" fill="var(--water)" />
      </svg>
      <div className="curtain-label display">{label}</div>
    </div>
  );
}
