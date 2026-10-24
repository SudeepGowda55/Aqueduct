import Link from "next/link";
import { NAV_LINKS, REPO_URL } from "@/lib/site";
import { ArchRow } from "./Reveal";

export function SiteFooter() {
  return (
    <footer className="mt-24 text-[#d8cdb8]">
      <ArchRow className="block h-14 w-full text-(--ink) md:h-20" count={14} />
      <div className="bg-(--ink)">
        <div className="mx-auto grid max-w-6xl gap-10 px-4 pb-10 pt-8 sm:px-6 md:grid-cols-[1.4fr_1fr_1fr]">
          <div>
            <p className="font-(family-name:--font-display) text-2xl font-bold text-[#f6f1e7]">Aqueduct</p>
            <p className="mt-3 max-w-sm text-sm leading-relaxed text-[#a99b83]">
              Exposure-gated Aqua liquidity. One maker strategy, safety-checked whether it fills through
              1inch SwapVM or a Uniswap v4 pool. Live on Base Sepolia (chain id 84532).
            </p>
          </div>
          <div>
            <p className="eyebrow !text-[#8d7f68]">Pages</p>
            <ul className="mt-3 space-y-2 text-sm">
              {NAV_LINKS.map((l) => (
                <li key={l.href}>
                  <Link href={l.href} className="transition-colors hover:text-(--water-bright)">
                    {l.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>
          <div>
            <p className="eyebrow !text-[#8d7f68]">Built on</p>
            <ul className="mt-3 space-y-2 text-sm">
              <li>1inch Aqua + SwapVM</li>
              <li>Uniswap v4 hooks</li>
              <li>The Graph (Subgraph Studio)</li>
              <li>
                <a href={REPO_URL} target="_blank" rel="noreferrer" className="hover:text-(--water-bright)">
                  Source on GitHub ↗
                </a>
              </li>
            </ul>
          </div>
        </div>
        <div className="mx-auto max-w-6xl border-t border-[#2f2a22] px-4 py-5 font-mono text-[11px] text-[#7d6f5a] sm:px-6">
          Testnet demo · get Base Sepolia ETH from a faucet to connect and swap.
        </div>
      </div>
    </footer>
  );
}
