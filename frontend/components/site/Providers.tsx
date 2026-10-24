"use client";

import type { ReactNode } from "react";
import { ActivityLogProvider } from "@/lib/ActivityLogProvider";
import { DeploymentProvider } from "@/lib/DeploymentProvider";
import { SmoothScroll } from "@/lib/smooth";
import { WalletProvider } from "@/lib/WalletProvider";

// Hoisted into the root layout so the wallet connection, the loaded deployment and the activity
// log all survive client-side navigation between pages.
export function Providers({ children }: { children: ReactNode }) {
  return (
    <WalletProvider>
      <DeploymentProvider>
        <ActivityLogProvider>
          <SmoothScroll>{children}</SmoothScroll>
        </ActivityLogProvider>
      </DeploymentProvider>
    </WalletProvider>
  );
}
