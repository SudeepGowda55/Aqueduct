import type { Metadata } from "next";
import { pageMetadata } from "@/lib/site";
import { SafetyStory } from "@/components/pages/SafetyStory";

export const metadata: Metadata = pageMetadata(
  "/safety",
  "Safety",
  "Aqueduct's threat model: every failure mode fails closed."
);

export default function SafetyPage() {
  return <SafetyStory />;
}
