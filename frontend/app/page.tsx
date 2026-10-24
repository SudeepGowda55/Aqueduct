import type { Metadata } from "next";
import { HomeStory } from "@/components/pages/HomeStory";
import { pageMetadata, SITE } from "@/lib/site";

export const metadata: Metadata = pageMetadata("/", null, SITE.description);

export default function Home() {
  return <HomeStory />;
}
