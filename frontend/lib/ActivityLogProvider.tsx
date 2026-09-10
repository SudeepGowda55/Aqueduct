"use client";

import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from "react";

export interface LogEntry {
  id: number;
  timestamp: string;
  level: "info" | "success" | "error";
  message: string;
  txHash?: string;
}

interface ActivityLogState {
  entries: LogEntry[];
  log: (level: LogEntry["level"], message: string, txHash?: string) => void;
  clear: () => void;
}

const ActivityLogContext = createContext<ActivityLogState | null>(null);

export function ActivityLogProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<LogEntry[]>([]);
  const nextId = useRef(0);

  const log = useCallback((level: LogEntry["level"], message: string, txHash?: string) => {
    setEntries((prev) => [
      { id: nextId.current++, timestamp: new Date().toLocaleTimeString(), level, message, txHash },
      ...prev,
    ]);
  }, []);

  const clear = useCallback(() => setEntries([]), []);

  return (
    <ActivityLogContext.Provider value={{ entries, log, clear }}>{children}</ActivityLogContext.Provider>
  );
}

export function useActivityLog(): ActivityLogState {
  const ctx = useContext(ActivityLogContext);
  if (!ctx) throw new Error("useActivityLog must be used within an ActivityLogProvider");
  return ctx;
}
