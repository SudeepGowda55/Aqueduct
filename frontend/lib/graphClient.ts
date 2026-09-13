// Shared client helper for the three Graph panels.
//
// All subgraph reads go through `/api/subgraph` (server-cached, 30s TTL,
// stale-served on 429) instead of hitting Studio directly from the browser.
// Polling policy: 60s base interval + jitter, staggered per panel, skipped
// while the tab is hidden. On 429 the last-good render is kept.

export class SubgraphRateLimitError extends Error {
  status = 429;
  retryAfterSec: number;
  constructor(message: string, retryAfterSec = 30) {
    super(message);
    this.name = "SubgraphRateLimitError";
    this.retryAfterSec = retryAfterSec;
  }
}

// Dedup concurrent identical queries within one browser tab.
const inflight = new Map<string, Promise<unknown>>();

export async function fetchSubgraph<T>(query: string): Promise<T & { _stale?: boolean; _warning?: string }> {
  if (inflight.has(query)) return inflight.get(query) as Promise<T & { _stale?: boolean; _warning?: string }>;
  const task = (async () => {
    const res = await fetch("/api/subgraph", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query }),
    });
    if (res.status === 429) {
      const retryAfter = Number(res.headers.get("Retry-After")) || 30;
      throw new SubgraphRateLimitError(`rate limited (429) — retrying in ${retryAfter}s`, retryAfter);
    }
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error((body as { error?: string }).error ?? `subgraph HTTP ${res.status}`);
    }
    const body = (await res.json()) as { data: T; _stale?: boolean; _warning?: string };
    return { ...(body.data as object), _stale: body._stale, _warning: body._warning } as T & {
      _stale?: boolean;
      _warning?: string;
    };
  })();
  inflight.set(query, task);
  try {
    return await task;
  } finally {
    inflight.delete(query);
  }
}

/** Friendly panel error: raw 429s become "showing last synced data". */
export function graphErrorMessage(err: unknown): string {
  if (err instanceof SubgraphRateLimitError) return `${err.message} — showing last synced data.`;
  return err instanceof Error ? err.message : String(err);
}

/**
 * Start a jittered, visibility-aware poll loop.
 * Returns a cleanup function. Initial call is staggered by `initialDelayMs`
 * so the three panels don't burst the proxy on page load.
 */
export function startSubgraphPoll(opts: {
  run: () => Promise<void>;
  baseIntervalMs?: number;
  initialDelayMs?: number;
}): () => void {
  const { run, baseIntervalMs = 60_000, initialDelayMs = 0 } = opts;
  let cancelled = false;
  let timer: ReturnType<typeof setTimeout> | null = null;

  const tick = async () => {
    if (cancelled) return;
    if (!document.hidden) {
      try {
        await run();
      } catch {
        // `run` surfaces errors via setState; never break the loop here.
      }
    }
    if (!cancelled) timer = setTimeout(tick, baseIntervalMs + Math.random() * 10_000);
  };

  timer = setTimeout(tick, initialDelayMs + Math.random() * 5_000);
  return () => {
    cancelled = true;
    if (timer) clearTimeout(timer);
  };
}
