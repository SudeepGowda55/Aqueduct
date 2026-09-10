"use client";

import { useActivityLog } from "@/lib/ActivityLogProvider";

const LEVEL_STYLES = {
  info: "text-neutral-400",
  success: "text-emerald-400",
  error: "text-red-400",
} as const;

export function ActivityLogPanel() {
  const { entries, clear } = useActivityLog();

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-950 p-5">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-neutral-200">Activity</h3>
        {entries.length > 0 && (
          <button onClick={clear} className="text-xs text-neutral-600 hover:text-neutral-400">
            Clear
          </button>
        )}
      </div>
      <div className="mt-3 max-h-72 space-y-2 overflow-y-auto font-mono text-xs">
        {entries.length === 0 && <p className="text-neutral-600">Nothing yet -- try a swap or push an exposure reading.</p>}
        {entries.map((entry) => (
          <div key={entry.id} className={LEVEL_STYLES[entry.level]}>
            <span className="text-neutral-600">[{entry.timestamp}]</span> {entry.message}
            {entry.txHash && (
              <span className="ml-1 text-neutral-600">
                tx: {entry.txHash.slice(0, 10)}...{entry.txHash.slice(-8)}
              </span>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
