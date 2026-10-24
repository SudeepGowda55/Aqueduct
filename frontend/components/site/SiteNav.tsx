"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { useLiveExposure } from "@/lib/useLiveExposure";
import { BAND_META, NAV_LINKS, REPO_URL } from "@/lib/site";

export function AqueductMark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden>
      <rect x="2" y="6" width="28" height="5" rx="1.5" fill="var(--water)" />
      <path d="M3 11h26v17h-5v-7a5 5 0 0 0-10 0v7H9v-7a3 3 0 0 0-1-2.2V28H3z" fill="var(--ink)" />
      <path d="M4 8.5h24" stroke="var(--water-bright)" strokeWidth="1.2" strokeDasharray="3 3" className="flow-dash" />
    </svg>
  );
}

export function GitHubButton() {
  return (
    <a
      href={REPO_URL}
      target="_blank"
      rel="noreferrer"
      aria-label="GitHub repository"
      className="grid h-9 w-9 shrink-0 place-items-center rounded-full border border-(--line-strong) text-(--ink-faint) transition-colors hover:border-(--ink) hover:text-(--ink)"
    >
      <svg width="17" height="17" viewBox="0 0 16 16" fill="currentColor" aria-hidden>
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
      </svg>
    </a>
  );
}

/// Live oracle reading in the chrome -- the real ExposureOracle value, on every page.
function LiveChip() {
  const live = useLiveExposure();
  const meta = live.band ? BAND_META[live.band] : null;
  return (
    <Link
      href="/proof"
      className="hidden items-center gap-2 rounded-full border border-(--line) bg-white/50 px-3 py-1.5 font-mono text-[11px] text-(--ink-soft) transition-colors hover:border-(--line-strong) lg:inline-flex"
      title="Live ExposureOracle reading for the demo maker (Base Sepolia)"
    >
      <span className="live-dot" style={{ color: meta?.color ?? "var(--ink-faint)" }} />
      {live.bps === null ? "oracle…" : `${(live.bps / 100).toFixed(1)}% · ${meta?.label}`}
    </Link>
  );
}

export function SiteNav() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  // Close the mobile menu on navigation (state adjusted during render, not in an effect).
  const [menuPath, setMenuPath] = useState(pathname);
  if (menuPath !== pathname) {
    setMenuPath(pathname);
    setOpen(false);
  }
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const isActive = (href: string) => (href === "/" ? pathname === "/" : pathname.startsWith(href));

  return (
    <header
      className={`sticky top-0 z-50 transition-[background-color,border-color,backdrop-filter] duration-500 ${
        scrolled || open
          ? "border-b border-(--line) bg-[rgba(246,241,231,0.85)] backdrop-blur-md"
          : "border-b border-transparent"
      }`}
    >
      <nav className="mx-auto flex h-16 max-w-6xl items-center gap-4 px-4 sm:px-6">
        <Link href="/" className="flex items-center gap-2.5" aria-label="Aqueduct home">
          <AqueductMark />
          <span className="font-(family-name:--font-display) text-lg font-bold tracking-tight">Aqueduct</span>
        </Link>

        <ul className="ml-6 hidden items-center gap-1 md:flex">
          {NAV_LINKS.map((l) => (
            <li key={l.href}>
              <Link
                href={l.href}
                className={`relative rounded-full px-3 py-1.5 text-sm transition-colors ${
                  isActive(l.href) ? "text-(--ink)" : "text-(--ink-faint) hover:text-(--ink)"
                }`}
              >
                {l.label}
                <span
                  className={`absolute inset-x-3 -bottom-0.5 h-[2px] origin-left rounded-full bg-(--water) transition-transform duration-500 ${
                    isActive(l.href) ? "scale-x-100" : "scale-x-0"
                  }`}
                />
              </Link>
            </li>
          ))}
        </ul>

        <div className="ml-auto flex items-center gap-2">
          <LiveChip />
          <Link href="/console" className="btn btn-aqua hidden !py-2 text-[13px] sm:inline-flex">
            Open console
          </Link>
          <GitHubButton />
          <button
            className="grid h-9 w-9 place-items-center rounded-full border border-(--line-strong) md:hidden"
            onClick={() => setOpen((o) => !o)}
            aria-label={open ? "Close menu" : "Open menu"}
            aria-expanded={open}
          >
            <span className="relative block h-3 w-4">
              <span className={`absolute left-0 h-[1.5px] w-4 bg-(--ink) transition-all duration-300 ${open ? "top-1.5 rotate-45" : "top-0"}`} />
              <span className={`absolute left-0 h-[1.5px] w-4 bg-(--ink) transition-all duration-300 ${open ? "top-1.5 -rotate-45" : "top-3"}`} />
            </span>
          </button>
        </div>
      </nav>

      <div
        className={`overflow-hidden transition-[max-height] duration-500 md:hidden ${open ? "max-h-96" : "max-h-0"}`}
      >
        <ul className="flex flex-col px-4 pb-4">
          {NAV_LINKS.map((l) => (
            <li key={l.href}>
              <Link
                href={l.href}
                className={`flex items-center justify-between border-b border-(--line) py-3 font-(family-name:--font-display) text-xl ${
                  isActive(l.href) ? "text-(--water)" : "text-(--ink)"
                }`}
              >
                {l.label}
                <span aria-hidden>→</span>
              </Link>
            </li>
          ))}
        </ul>
      </div>
    </header>
  );
}
