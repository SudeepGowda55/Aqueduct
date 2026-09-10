"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { loadDeployment, type Deployment } from "./deployment";

interface DeploymentState {
  deployment: Deployment | null;
  isLoading: boolean;
  error: string | null;
  reload: () => void;
}

const DeploymentContext = createContext<DeploymentState | null>(null);

export function DeploymentProvider({ children }: { children: ReactNode }) {
  const [deployment, setDeployment] = useState<Deployment | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    loadDeployment()
      .then((d) => {
        if (cancelled) return;
        setDeployment(d);
        setError(null);
      })
      .catch((err) => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [reloadKey]);

  const reload = () => {
    setIsLoading(true);
    setError(null);
    setReloadKey((k) => k + 1);
  };

  return (
    <DeploymentContext.Provider value={{ deployment, isLoading, error, reload }}>
      {children}
    </DeploymentContext.Provider>
  );
}

export function useDeployment(): DeploymentState {
  const ctx = useContext(DeploymentContext);
  if (!ctx) throw new Error("useDeployment must be used within a DeploymentProvider");
  return ctx;
}
