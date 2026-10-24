import type { Metadata } from "next";
import { pageMetadata } from "@/lib/site";
import { SafetyStory } from "@/components/pages/SafetyStory";

export const metadata: Metadata = pageMetadata(
  "/safety",
  "Safety",
  "Aqueduct's threat model: a wrong or stale oracle reading, a stopped keeper or a distrusted feed all fail closed, with a smaller fill or no fill."
);

export default function SafetyPage() {
  return <SafetyStory />;
}
