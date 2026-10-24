import type { Metadata } from "next";
import { pageMetadata } from "@/lib/site";

// Server layout so this client-component page still ships its own server-rendered metadata.
export const metadata: Metadata = pageMetadata("/console", "Console", "Push exposure readings to the ExposureOracle, then swap the same maker strategy on SwapVM and Uniswap v4 and watch the gate derate or halt it.");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
