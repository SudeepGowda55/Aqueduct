"use client";

import { AggregateExposurePanel } from "@/components/AggregateExposurePanel";
import { BaselineComparisonPanel } from "@/components/BaselineComparisonPanel";
import { CrossVenueProofPanel } from "@/components/CrossVenueProofPanel";
import { DeploymentAddresses, DeploymentStatus } from "@/components/DeploymentStatus";
import { ExposureGauge } from "@/components/ExposureGauge";
import { GraphExposurePanel } from "@/components/GraphExposurePanel";
import { GraphPoolActivityPanel } from "@/components/GraphPoolActivityPanel";
import { GraphVerdictBanner } from "@/components/GraphVerdictBanner";
import { Reveal, SectionHead } from "@/components/site/Reveal";

export default function ProofPage() {
  return (
    <div className="mx-auto max-w-6xl px-4 pt-14 sm:px-6 md:pt-20">
      <SectionHead numeral="I" eyebrow="Live proof · Base Sepolia" title="Read straight from the chain and the subgraph.">
        Nothing on this page is mocked. Every panel is a public RPC read or a query against the deployed subgraph
        (Subgraph Studio <code>ethonline</code> v0.4.0). No wallet is needed.
      </SectionHead>

      <div className="mt-10 space-y-6">
        <DeploymentStatus />
        <div className="grid items-start gap-6 lg:grid-cols-2">
          <Reveal className="space-y-6">
            <GraphVerdictBanner />
            <section className="panel p-5">
              <h2 className="panel-title">Maker exposure</h2>
              <p className="mt-1 text-xs text-neutral-500">ExposureOracle.exposureOf(maker), refreshed every 4s.</p>
              <div className="mt-5">
                <ExposureGauge />
              </div>
            </section>
          </Reveal>
          <Reveal delay={100}>
            <AggregateExposurePanel />
          </Reveal>
        </div>
      </div>

      <div className="mt-24">
        <SectionHead numeral="II" eyebrow="Venue independence" title="Same strategy, two venues, one number.">
          The v4 pool has no liquidity of its own. Both venues read the same <code>Aqua.safeBalances</code> and the same
          oracle entry through the same opcode, so the predicted fill is literally the same computation done twice.
        </SectionHead>
        <div className="mt-10 grid gap-6 lg:grid-cols-2">
          <Reveal>
            <CrossVenueProofPanel />
          </Reveal>
          <Reveal delay={100}>
            <BaselineComparisonPanel />
          </Reveal>
        </div>
      </div>

      <div className="mt-24">
        <SectionHead numeral="III" eyebrow="The Graph" title="One query, joined across contracts.">
          The subgraph joins Aqua commitments, oracle readings and v4 swaps into one <code>ExposurePosition</code> per
          maker and strategy, and exposes pool activity in the standard Messari DEX-AMM shape.
        </SectionHead>
        <div className="mt-10 space-y-6">
          <Reveal>
            <GraphExposurePanel />
          </Reveal>
          <Reveal>
            <GraphPoolActivityPanel />
          </Reveal>
          <DeploymentAddresses />
        </div>
      </div>
    </div>
  );
}
