"use client";

import { ActivityLogPanel } from "@/components/ActivityLogPanel";
import { ConnectWallet } from "@/components/ConnectWallet";
import { DeploymentAddresses, DeploymentStatus } from "@/components/DeploymentStatus";
import { ExposureGauge } from "@/components/ExposureGauge";
import { KeeperPanel } from "@/components/KeeperPanel";
import { SwapVMPanel } from "@/components/SwapVMPanel";
import { UniswapPanel } from "@/components/UniswapPanel";
import { ActivityLogProvider } from "@/lib/ActivityLogProvider";
import { DeploymentProvider } from "@/lib/DeploymentProvider";
import { WalletProvider } from "@/lib/WalletProvider";

export default function Home() {
  return (
    <WalletProvider>
      <DeploymentProvider>
        <ActivityLogProvider>
          <div className="mx-auto min-h-screen max-w-5xl px-6 py-10 text-neutral-100">
            <header className="flex items-start justify-between gap-4">
              <div>
                <h1 className="text-2xl font-bold tracking-tight">Aqueduct</h1>
                <p className="mt-1 max-w-xl text-sm text-neutral-500">
                  Exposure-gated Aqua liquidity. One maker strategy, safety-checked whether it
                  fills a swap directly through SwapVM or through a Uniswap v4 pool.
                </p>
              </div>
              <ConnectWallet />
            </header>

            <div className="mt-8 space-y-6">
              <DeploymentStatus />

              <section className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-6">
                <h2 className="text-sm font-semibold text-neutral-200">Maker exposure</h2>
                <div className="mt-4">
                  <ExposureGauge />
                </div>
              </section>

              <div className="grid gap-6 md:grid-cols-2">
                <SwapVMPanel />
                <UniswapPanel />
              </div>

              <div className="grid gap-6 md:grid-cols-2">
                <KeeperPanel />
                <ActivityLogPanel />
              </div>

              <DeploymentAddresses />
            </div>

            <footer className="mt-10 border-t border-neutral-900 pt-6 text-xs text-neutral-600">
              Local demo frontend -- talks to a local anvil node at http://127.0.0.1:8545 (chain id
              31337). See the project README for the full architecture and how each piece fits
              together.
            </footer>
          </div>
        </ActivityLogProvider>
      </DeploymentProvider>
    </WalletProvider>
  );
}
