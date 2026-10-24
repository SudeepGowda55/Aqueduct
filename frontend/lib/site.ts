export const REPO_URL = "https://github.com/SudeepGowda55/Aqueduct";

/** Link to a file (optionally a line range) in the repo on GitHub. */
export function repoFile(path: string): string {
  return `${REPO_URL}/blob/main/${path}`;
}

export const NAV_LINKS = [
  { href: "/", label: "Story" },
  { href: "/mechanism", label: "Mechanism" },
  { href: "/proof", label: "Live proof" },
  { href: "/safety", label: "Safety" },
  { href: "/console", label: "Console" },
] as const;

export const BAND_META = {
  safe: { label: "Safe", long: "Safe — normal fill", color: "var(--safe)" },
  derate: { label: "Derated", long: "Derated — smaller fill", color: "var(--derate)" },
  halt: { label: "Halted", long: "Halted — swaps revert", color: "var(--halt)" },
} as const;

// ---------- Link previews / SEO ----------
// Production domain from the README's "Live off-chain links".
export const SITE = {
  url: "https://aqueduct-protocol.vercel.app",
  name: "Aqueduct",
  tagline: "exposure-gated Aqua liquidity",
  description: "Exposure-gated Aqua liquidity, backing both a direct SwapVM swap and a Uniswap v4 pool.",
} as const;

export const OG_IMAGE = { url: "/og.png", width: 1200, height: 627, alt: "Aqueduct — liquidity behind a gate that only closes" };

/** Per-route metadata. Next REPLACES (not merges) a parent's openGraph/twitter, so every route
 *  re-lists the shared image here rather than relying on the root layout's. */
export function pageMetadata(path: string, title: string | null, description: string) {
  const fullTitle = title ? `${title} · ${SITE.name}` : `${SITE.name} — ${SITE.tagline}`;
  return {
    ...(title ? { title } : {}),
    description,
    alternates: { canonical: path },
    openGraph: {
      type: "website" as const,
      siteName: SITE.name,
      title: fullTitle,
      description,
      url: path,
      images: [OG_IMAGE],
    },
    twitter: { card: "summary_large_image" as const, title: fullTitle, description, images: [OG_IMAGE.url] },
  };
}
