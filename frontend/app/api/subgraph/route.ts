// Server-side Subgraph proxy with rate-limit hardening.
//
// Why: the three Graph panels used to fetch
// https://api.studio.thegraph.com/query/1758739/ethonline/v0.4.0
// directly from every browser every 15s. N visitors x 3 panels x 4/min
// trips Studio's per-second quota -> HTTP 429 on all panels.
//
// This route collapses that storm:
// - per-instance TTL cache (30s) + in-flight dedup: all visitors in one
//   window share a single upstream request
// - Retry-After aware retries on 429/5xx with backoff + jitter
// - stale-while-revalidate: on 429 after retries, serve last-good data
//   with `_stale: true` (200) instead of failing the panel
export const dynamic = "force-dynamic";

const SUBGRAPH_URL =
  process.env.AQUA_SUBGRAPH_URL ??
  "https://api.studio.thegraph.com/query/1758739/ethonline/v0.4.0";

const TTL_MS = Number(process.env.GRAPH_CACHE_TTL_MS ?? 30_000);
const MAX_RETRIES = 2;
const UPSTREAM_TIMEOUT_MS = 15_000;

type CacheEntry = { expiresAt: number; data: unknown };
const cache = new Map<string, CacheEntry>();
const inflight = new Map<string, Promise<unknown>>();

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function retryAfterMs(res: Response): number {
  const v = res.headers.get("retry-after");
  if (!v) return NaN;
  const secs = Number(v);
  if (Number.isFinite(secs)) return secs * 1000;
  const dateMs = Date.parse(v);
  return Number.isFinite(dateMs) ? Math.max(0, dateMs - Date.now()) : NaN;
}

function backoffMs(attempt: number, retryAfter: number): number {
  if (Number.isFinite(retryAfter) && retryAfter > 0) return retryAfter;
  return Math.round(800 * 2 ** attempt * (0.75 + Math.random() * 0.5));
}

async function postUpstream(query: string): Promise<Record<string, unknown>> {
  let lastErr: Error & { status?: number };
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), UPSTREAM_TIMEOUT_MS);
    try {
      const res = await fetch(SUBGRAPH_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ query }),
        signal: ctrl.signal,
      });
      if (res.status === 429 || (res.status >= 500 && res.status < 600)) {
        const text = await res.text().catch(() => "");
        lastErr = new Error(`subgraph HTTP ${res.status}: ${text.slice(0, 200)}`) as typeof lastErr;
        lastErr.status = res.status;
        if (attempt < MAX_RETRIES) {
          await sleep(backoffMs(attempt, retryAfterMs(res)));
          continue;
        }
        throw lastErr;
      }
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        lastErr = new Error(`subgraph HTTP ${res.status}: ${text.slice(0, 200)}`) as typeof lastErr;
        lastErr.status = res.status;
        throw lastErr;
      }
      const body = (await res.json()) as { data?: unknown; errors?: unknown };
      if (body.errors) throw new Error(JSON.stringify(body.errors).slice(0, 300));
      return (body.data ?? {}) as Record<string, unknown>;
    } catch (e) {
      if (e instanceof Error && e.name === "AbortError") {
        lastErr = new Error("subgraph timeout after 15000ms") as typeof lastErr;
        lastErr.status = 504;
      } else {
        lastErr = e as typeof lastErr;
      }
      const s = lastErr.status;
      const retryable = s === undefined || s === 429 || s === 504 || (s >= 500 && s < 600);
      if (!retryable || attempt >= MAX_RETRIES) throw lastErr!;
      await sleep(backoffMs(attempt, NaN));
    } finally {
      clearTimeout(t);
    }
  }
  throw lastErr!;
}

export async function POST(req: Request) {
  let query: unknown;
  try {
    query = ((await req.json()) as { query?: unknown }).query;
  } catch {
    return Response.json({ ok: false, error: "invalid JSON body" }, { status: 400 });
  }
  if (typeof query !== "string" || query.length === 0 || query.length > 8000) {
    return Response.json({ ok: false, error: "bad query" }, { status: 400 });
  }

  const hit = cache.get(query);
  const fresh = hit && Date.now() <= hit.expiresAt ? hit : null;
  if (fresh) {
    return Response.json(
      { data: fresh.data },
      { headers: { "X-Cache": "HIT", "Cache-Control": "public, s-maxage=30, stale-while-revalidate=120" } }
    );
  }
  if (inflight.has(query)) {
    const data = await inflight.get(query)!;
    return Response.json(
      { data },
      { headers: { "X-Cache": "COALESCED", "Cache-Control": "public, s-maxage=30, stale-while-revalidate=120" } }
    );
  }

  const task = (async () => {
    try {
      const data = await postUpstream(query);
      cache.set(query, { expiresAt: Date.now() + TTL_MS, data });
      return { data, stale: false as const };
    } catch (e) {
      const status = (e as { status?: number }).status;
      if ((status === 429 || status === 504 || (status !== undefined && status >= 500 && status < 600)) && hit) {
        return { data: hit.data, stale: true as const, warning: String((e as Error).message ?? e) };
      }
      throw e;
    }
  })();
  inflight.set(query, task.then((r) => r.data));
  try {
    const result = await task;
    if (result.stale) {
      return Response.json(
        { data: result.data, _stale: true, _warning: `serving cached data: ${result.warning}` },
        { headers: { "X-Cache": "STALE", "Cache-Control": "public, s-maxage=30, stale-while-revalidate=120" } }
      );
    }
    return Response.json(
      { data: result.data },
      { headers: { "X-Cache": hit ? "REVALIDATED" : "MISS", "Cache-Control": "public, s-maxage=30, stale-while-revalidate=120" } }
    );
  } catch (e) {
    const status = (e as { status?: number }).status;
    const http = status === 429 ? 429 : 500;
    const headers: Record<string, string> = { "Cache-Control": "public, s-maxage=10" };
    if (status === 429) headers["Retry-After"] = "30";
    return Response.json({ ok: false, error: String((e as Error).message ?? e) }, { status: http, headers });
  } finally {
    inflight.delete(query);
  }
}
