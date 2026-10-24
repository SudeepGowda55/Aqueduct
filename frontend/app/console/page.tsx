"use client";

import { ActivityLogPanel } from "@/components/ActivityLogPanel";
import { ConnectWallet } from "@/components/ConnectWallet";
import { DeploymentStatus } from "@/components/DeploymentStatus";
import { DynamicFeePoolPanel } from "@/components/DynamicFeePoolPanel";
import { EmergencyPausePanel } from "@/components/EmergencyPausePanel";
import { ExposureGauge } from "@/components/ExposureGauge";
import { KeeperPanel } from "@/components/KeeperPanel";
import { RiskPolicyPanel } from "@/components/RiskPolicyPanel";
import { SophisticatedPositionPanel } from "@/components/SophisticatedPositionPanel";
import { SwapVMPanel } from "@/components/SwapVMPanel";
import { UniswapPanel } from "@/components/UniswapPanel";
import { Reveal } from "@/components/site/Reveal";

function Group({ label, title, children }: { label: string; title: string; children: React.ReactNode }) {
  return (
    <section>
      <Reveal className="mb-4 flex items-baseline gap-3 border-b border-(--line) pb-2">
        <span className="numeral text-2xl">{label}</span>
        <h2 className="eyebrow text-(--ink-soft)!">{title}</h2>
      </Reveal>
      <div className="grid gap-6 md:grid-cols-2">{children}</div>
    </section>
  );
}

export default function ConsolePage() {
  return (
    <div className="mx-auto max-w-6xl px-4 pt-12 sm:px-6 md:pt-16">
      <div className="flex flex-col gap-6 md:flex-row md:items-end md:justify-between">
        <Reveal>
          <p className="eyebrow">Console · Base Sepolia (chain id 84532)</p>
          <h1 className="display mt-3 text-5xl md:text-6xl">Open the sluice.</h1>
          <p className="mt-4 max-w-xl text-[15px] leading-relaxed text-(--ink-soft)">
            Push exposure readings as the keeper, then swap the same maker strategy directly through SwapVM or through
            Uniswap v4 and watch both react identically.
          </p>
        </Reveal>
        <ConnectWallet />
      </div>

      <div className="mt-8">
        <DeploymentStatus />
      </div>

      <div className="mt-10 grid gap-10 xl:grid-cols-[1fr_300px]">
        <div className="space-y-12">
          <Group label="I" title="Reading & keeper">
            <section className="panel p-5">
              <h3 className="panel-title">Maker exposure</h3>
              <div className="mt-4">
                <ExposureGauge />
              </div>
            </section>
            <KeeperPanel />
          </Group>

          <Group label="II" title="Swap the same strategy on two venues">
            <SwapVMPanel />
            <UniswapPanel />
          </Group>

          <Group label="III" title="Composed position & dynamic fee">
            <SophisticatedPositionPanel />
            <DynamicFeePoolPanel />
          </Group>

          <Group label="IV" title="Policy & emergency halt">
            <RiskPolicyPanel />
            <EmergencyPausePanel />
          </Group>

          <Reveal className="rounded-2xl bg-(--ink) p-8 text-center text-(--paper)">
            <p className="display text-2xl md:text-3xl">
              The oracle can lie, but it cannot make the maker trade more than the underlying SwapVM program authorized.
            </p>
            <p className="mx-auto mt-4 max-w-2xl text-xs leading-relaxed text-[#b3a68f]">
              Try every keeper preset, including &quot;Malicious (100%)&quot;. Every reading either derates a fill or halts
              it, and none can produce a better fill than the maker&apos;s own unsigned program already allowed. See{" "}
              <code className="bg-white/10! text-(--water-bright)!">test_MaliciousOracle_CanOnlyEverMakeFillMoreConservative</code>.
            </p>
          </Reveal>
        </div>

        <aside className="xl:sticky xl:top-24 xl:self-start" data-lenis-prevent>
          <ActivityLogPanel />
        </aside>
      </div>
    </div>
  );
}
