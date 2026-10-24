import type { Metadata } from "next";
import { pageMetadata } from "@/lib/site";
import { MechanismStory } from "@/components/pages/MechanismStory";

export const metadata: Metadata = pageMetadata(
  "/mechanism",
  "Mechanism",
  "How _exposureGate1D derates or halts a maker's fill, and why it can never enlarge one."
);

export default function MechanismPage() {
  return <MechanismStory />;
}
