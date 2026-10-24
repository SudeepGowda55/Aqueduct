import type { Metadata } from "next";
import { pageMetadata } from "@/lib/site";
import { MechanismStory } from "@/components/pages/MechanismStory";

export const metadata: Metadata = pageMetadata(
  "/mechanism",
  "Mechanism",
  "How the _exposureGate1D SwapVM instruction derates or halts a maker's fill from live exposure, and why by construction it can never enlarge one."
);

export default function MechanismPage() {
  return <MechanismStory />;
}
