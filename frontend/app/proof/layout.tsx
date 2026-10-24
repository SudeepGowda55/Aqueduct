import type { Metadata } from "next";
import { pageMetadata } from "@/lib/site";

// Server layout so this client-component page still ships its own server-rendered metadata.
export const metadata: Metadata = pageMetadata("/proof", "Live proof", "Live RPC and subgraph reads from Base Sepolia: maker exposure across Aqua strategies, cross-venue consistency and Uniswap v4 pool activity.");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
