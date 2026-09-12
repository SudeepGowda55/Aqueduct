// Aqueduct MCP server (stdio): the "compose 2+ Graph products" moment.
// Wraps the deployed exposure subgraph (Studio `ethonline` v0.2.0) as agent
// tools, so Claude/Cursor/Cline can answer "is this maker safe on both
// venues?" without writing GraphQL. The Studio query endpoint is public —
// no API key needed.
//
// Run: node server.js
// Speak JSON-RPC per line: {"jsonrpc":"2.0","id":1,"method":"tools/list"}
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1758739/ethonline/v0.2.0";

const TOOLS = [
  {
    name: "maker_exposure",
    description: "Current exposure for a maker: one row per strategy with venues, committed, wallet, exposureBps and status. The cross-venue view.",
    inputSchema: {
      type: "object",
      properties: { maker: { type: "string", description: "maker address (0x...)" } },
      required: ["maker"],
    },
  },
  {
    name: "exposure_history",
    description: "Exposure readings over time (from immutable ExposureSnapshots), oldest first. For charting 10% -> 40% -> 70% -> 90%.",
    inputSchema: {
      type: "object",
      properties: {
        maker: { type: "string", description: "maker address, optional — omit for all makers" },
        limit: { type: "number", description: "max snapshots (default 50)" },
      },
    },
  },
  {
    name: "cross_venue_positions",
    description: "Positions filling on BOTH SwapVM and Uniswap v4 (venues contains uniswap-v4). The killer cross-venue query as a tool.",
    inputSchema: {
      type: "object",
      properties: { maker: { type: "string", description: "maker address, optional" } },
    },
  },
  {
    name: "messari_swaps",
    description: "Recent swaps in Messari DEX-AMM shape (same field names as messari/subgraphs schema-dex-amm: pool { inputTokens } tokenIn/tokenOut amountIn/amountOut). Proves the standard query pattern works here too. USD fields are zero (no price feed on Base Sepolia).",
    inputSchema: {
      type: "object",
      properties: {
        pool: { type: "string", description: "v4 poolId hex, optional — omit for all pools" },
        limit: { type: "number", description: "max swaps (default 20)" },
      },
    },
  },
];

async function gql(query, variables = {}) {
  const res = await fetch(SUBGRAPH_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`subgraph HTTP ${res.status}`);
  const body = await res.json();
  if (body.errors) throw new Error(JSON.stringify(body.errors).slice(0, 300));
  return body.data;
}

async function handleCall(name, args = {}) {
  if (name === "maker_exposure") {
    return await gql(
      `query($maker: String!) {
        exposurePositions(where: { maker: $maker }) {
          strategyHash venues committedAmount makerWalletBalance
          exposureBps maxExposureBps haltExposureBps status isPausedByMaker updatedAt
        }
      }`,
      { maker: String(args.maker).toLowerCase() }
    );
  }
  if (name === "exposure_history") {
    const limit = Math.min(Number(args.limit) || 50, 200);
    const where = args.maker ? `(where: { maker: "${String(args.maker).toLowerCase()}" }, ` : "(";
    return await gql(
      `{ exposureSnapshots${where}first: ${limit}, orderBy: blockNumber, orderDirection: asc) {
        maker strategyHash exposureBps status blockNumber blockTimestamp
      } }`
    );
  }
  if (name === "cross_venue_positions") {
    const filter = args.maker ? `(where: { maker: "${String(args.maker).toLowerCase()}" })` : "";
    const data = await gql(
      `{ exposurePositions${filter} {
        strategyHash venues committedAmount exposureBps status
      } }`
    );
    const rows = data.exposurePositions ?? [];
    return { crossVenue: rows.filter((r) => (r.venues || []).includes("uniswap-v4")) };
  }
  if (name === "messari_swaps") {
    const limit = Math.min(Number(args.limit) || 20, 100);
    const where = args.pool ? `(where: { pool: "${String(args.pool).toLowerCase()}" }, ` : "(";
    return await gql(
      `{ swaps${where}first: ${limit}, orderBy: blockNumber, orderDirection: desc) {
        id pool { id name inputTokens { id symbol name decimals } }
        tokenIn { id symbol } amountIn amountInUSD
        tokenOut { id symbol } amountOut amountOutUSD
        blockNumber timestamp from to
      } }`
    );
  }
  throw new Error(`unknown tool: ${name}`);
}

function respond(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function respondError(id, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } }) + "\n");
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", async (chunk) => {
  buffer += chunk;
  const lines = buffer.split("\n");
  buffer = lines.pop();
  for (const line of lines) {
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    const { id, method, params } = msg;
    try {
      if (method === "initialize")
        respond(id, {
          protocolVersion: "2024-11-05",
          serverInfo: { name: "aqueduct-exposure", version: "1.0.0" },
          capabilities: { tools: {} },
        });
      else if (method === "tools/list") respond(id, { tools: TOOLS });
      else if (method === "tools/call")
        respond(id, {
          content: [{ type: "text", text: JSON.stringify(await handleCall(params.name, params.arguments), null, 2) }],
        });
      else if (method === "ping") respond(id, {});
      else respondError(id, `unknown method: ${method}`);
    } catch (e) {
      respondError(id, e.message);
    }
  }
});
