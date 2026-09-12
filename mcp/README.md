# Aqueduct exposure MCP server

A minimal (zero-dependency, stdio JSON-RPC) MCP server that wraps the deployed
[exposure subgraph](https://api.studio.thegraph.com/query/1758739/ethonline/v0.4.0) as agent
tools — so Claude, Cursor, or any other MCP client can answer "is this maker safe on both
venues?" without anyone hand-writing GraphQL.

This is the project's second composed Graph product: the custom `ethonline` subgraph, plus this
MCP layer built on top of it. See the main [README's Graph section](../README.md#the-graph-pipeline)
for the full composability story.

## Tools

| Tool | What it returns |
|---|---|
| `maker_exposure` | Every `ExposurePosition` for a maker — venues, committed amount, wallet balance, exposure %, status. |
| `exposure_history` | Ordered `ExposureSnapshot` readings over time, for charting 10% → 40% → 70% → 90%. |
| `cross_venue_positions` | Only the positions that fill on *both* SwapVM and Uniswap v4 (`venues` includes `"uniswap-v4"`) — the killer cross-venue query, as a tool. |
| `messari_swaps` | Recent `Swap` rows in Messari DEX-AMM shape (`pool { inputTokens }`, `tokenIn/amountIn`, `tokenOut/amountOut`) — the standards-leverage proof as a tool. |
| `liquidity_pools` | All indexed v4 pools with live token symbols + per-pool indexed swap counts — so an agent can discover poolIds before filtering `messari_swaps`. |
| `maker_safety_verdict` | Reasoned verdict (`SAFE`/`DERATED`/`HALTED`/`PAUSED`/`UNKNOWN`) with exposure %, cross-venue coverage, and latest swap — answers "is this maker safe on both venues?" directly. |

## Run it

```shell
node server.js
```

No install step, no API key — `server.js` has zero npm dependencies and the Studio query
endpoint it queries is public. Speak newline-delimited JSON-RPC on stdin/stdout, e.g.:

```shell
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node server.js
```

or point any MCP-compatible client (Claude Desktop, Cursor, etc.) at
`node <path-to-this-folder>/server.js` as a stdio MCP server.
