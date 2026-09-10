# Aqueduct — Exposure-Gated Aqua Liquidity

Built for ETHGlobal, spanning the **1inch: Build an Aqua App** and **Uniswap Hook** tracks, plus
**The Graph** for the off-chain data pipeline.

Aqueduct adds a new SwapVM instruction, `_exposureGate1D`, that derates or halts a maker's fill
based on their *live cross-protocol exposure* — read from an on-chain oracle (`ExposureOracle`)
fed by an off-chain Graph subgraph that aggregates the maker's committed balances across every
Aqua strategy they've shipped. A Uniswap v4 hook (`AquaV4Hook`) then sources a v4 pool's swaps
directly from that same exposure-gated maker strategy, so the same safety guarantee protects both
a direct SwapVM swap and a swap routed through Uniswap.

The opcode is **monotonic by construction**: it can only shrink a taker's fill, or halt it
entirely via revert. There is no code path in which it can enlarge a fill beyond what the
preceding swap-computing instruction already produced. That means a stale, wrong, or even
maliciously-signed oracle reading can only ever make a maker quote *more conservatively* than its
unsigned SwapVM program already authorized — never trade beyond it. This is the direct structural
mirror of SwapVM's own `OraclePriceAdjuster` instruction, which is one-directional in the opposite
sense (only ever improves the taker's price, never worsens it).

## Where to look

| What | File |
|---|---|
| The opcode itself, with the monotonicity argument spelled out | [`src/opcodes/ExposureGate.sol`](src/opcodes/ExposureGate.sol) |
| The on-chain oracle the opcode reads | [`src/oracle/ExposureOracle.sol`](src/oracle/ExposureOracle.sol) / [`IExposureOracle.sol`](src/oracle/IExposureOracle.sol) |
| Stock `AquaOpcodes` + the new instruction appended at the end (index 35), every existing index preserved | [`src/opcodes/ExposureAquaOpcodes.sol`](src/opcodes/ExposureAquaOpcodes.sol) |
| The deployable router wiring it together | [`src/routers/ExposureAwareAquaRouter.sol`](src/routers/ExposureAwareAquaRouter.sol) |
| Proof of the safety claim: 8 tests incl. two 257-run fuzz properties | [`test/ExposureGate.t.sol`](test/ExposureGate.t.sol) |
| End-to-end demo as real broadcast transactions on a local chain | [`script/AqueductDemo.s.sol`](script/AqueductDemo.s.sol) |
| The Uniswap v4 hook that sources swaps from the same exposure-gated maker strategy | [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) |
| Proof the hook actually moves real tokens through a real `PoolManager`, and that the exposure gate halts a v4 swap too | [`test/AquaV4Hook.t.sol`](test/AquaV4Hook.t.sol) |
| The Graph subgraph aggregating a maker's committed Aqua balances | [`subgraph/`](subgraph/) |
| The keeper that reads the subgraph and posts to `ExposureOracle` | [`keeper/pushExposure.ts`](keeper/pushExposure.ts) |
| The Next.js dashboard: live exposure gauge, both swap paths, keeper control | [`frontend/`](frontend/) |

`lib/swap-vm` and `lib/aqua` are the real, unmodified 1inch repositories, and `lib/uniswap-hooks`
(which itself bundles a matching `v4-core`/`v4-periphery`) is OpenZeppelin's real, current Uniswap
v4 hooks utility library — all pulled in as dependencies, not reimplemented or mocked.

## Why a local chain, not a mainnet fork

1inch's own repos ship no real mainnet or testnet Aqua/SwapVM deployment addresses — see
[`lib/aqua/config/constants.json`](lib/aqua/config/constants.json) and
[`lib/swap-vm/config/constants.json`](lib/swap-vm/config/constants.json), both zero-address
placeholders for local anvil (chain id `31337`). The track's own rules anticipate this directly:
*"Official Aqua/SwapVM contracts must be used (redeployments of a modified SwapVM contract is
allowed)"* and *"local forks are ok."* So the demo deploys fresh, unmodified-Aqua +
modified-SwapVM instances onto a local anvil node and drives them with real signed transactions —
there is no live deployment to fork against.

## Run the tests

```shell
forge install   # pulls in swap-vm, aqua, and uniswap-hooks as dependencies
forge test -vv
```

13 tests across two suites, all passing:

**`ExposureGate.t.sol`** (8 tests) — the opcode itself, called directly through SwapVM:
- pass-through below the exposure threshold (exact equality with an ungated baseline)
- exact derate math at the midpoint between max and halt, both exact-in and exact-out
- hard revert at and above the halt threshold
- stale-oracle revert
- **two 257-run property tests**: across the full exposure/amount input space, a gated exact-in
  fill never exceeds the ungated baseline's output, and a gated exact-out fill never requires
  less input than the baseline. This is what actually proves the monotonicity claim above, not
  just the example cases.

**`AquaV4Hook.t.sol`** (5 tests) — the same maker strategy, now sourcing a real Uniswap v4 pool:
- a real `PoolManager.swap()` in both directions, moving real ERC-20 balances, with the output
  traced back to the maker's Aqua balance shrinking by exactly the amount the taker received
- the exposure gate halting a **v4 swap**, not just a direct SwapVM call, with the revert bubbling
  up through `PoolManager`'s own `Hooks.sol` wrapping intact
- exact-output swaps rejected (out of scope, see below)
- direct third-party liquidity addition rejected (this hook is the pool's sole liquidity source)

Two real engineering constraints surfaced while building the hook, both documented in code where
they're handled rather than glossed over here:
- **A genuine solc version conflict**: `v4-core`'s `PoolManager.sol` pins exactly `0.8.26`, while
  swap-vm/aqua pin exactly `0.8.30` — no single file can import both. `foundry.toml` leaves solc
  version auto-detection on (each file compiles at whatever its own pragma demands) instead of
  forcing one version project-wide, and `test/utils/PoolManagerDeployer.sol` exists solely to get
  `PoolManager` compiled into a deployable artifact without pulling it into swap-vm's compilation
  graph — the test then deploys it via `vm.deployCode` by artifact name, never by source import.
- **v4's flash-accounting settlement order**: a swapper's payment lands in `PoolManager` only
  *after* `PoolManager.swap()` returns to the top-level router — never inside the hook's own
  `beforeSwap`/`afterSwap` callbacks. So a hook that wants to synchronously hand the taker real,
  Aqua-sourced output (rather than deferring the whole fill, as OpenZeppelin's own `BaseAsyncSwap`
  does) has to fund the input leg from its own working-capital float rather than the swapper's
  not-yet-arrived payment, and reconcile that float later via `sweepClaims` once real reserves
  accumulate. This is explained in full in `AquaV4Hook.sol`'s contract-level comment.

## Run the on-chain demo

```shell
anvil                                                          # terminal 1
forge script script/AqueductDemo.s.sol \                       # terminal 2
  --rpc-url http://127.0.0.1:8545 \
  --private-key <any funded anvil account, e.g. account (0) from anvil's own startup log> \
  --broadcast -vvvv
forge script script/AqueductV4Demo.s.sol \                     # same terminal, right after
  --rpc-url http://127.0.0.1:8545 \
  --private-key <the same funded anvil account> \
  --broadcast -vvvv
```

This deploys real contracts and ships real maker liquidity into Aqua as genuine, mined
transactions (not `forge test` pranks — verifiable independently with `cast receipt` against the
tx hashes forge writes to `broadcast/*/31337/run-latest.json`), then runs three scenarios as the
maker's reported exposure climbs:

1. **10% exposure** (below the 50% max) → normal AMM fill, gate is a no-op
2. **70% exposure** (between 50% max and 90% halt) → derated fill: same `amountIn`, strictly less
   `amountOut` than scenario 1's pool-implied price — the taker gets worse execution, never better
3. **90% exposure** (at the halt threshold) → the swap reverts outright with
   `ExposureGateExceedsHaltThreshold`, no fill at all

Scenario 3 is deliberately run as a plain call against the live chain state rather than a
broadcast transaction — forge's broadcast pre-flight replays the whole batch before sending
anything and aborts the *entire* run the moment one call is predicted to revert, which would have
silently prevented scenarios 1 and 2 from ever being sent for real. The revert is exactly as real
either way: it executes against the actual deployed contracts and actual on-chain state from the
prior broadcast transactions.

`AquaDemo.s.sol` then writes every address (plus the maker's SwapVM order) to
`frontend/public/deployment.json`; `AqueductV4Demo.s.sol` reads that file back, wires up a real
Uniswap v4 pool + hook backed by the same maker strategy, and updates the same JSON with the v4
addresses — that's what the frontend below reads. They're two separate `forge script` invocations
so the 1inch-only demo stays runnable and legible entirely on its own, and so the v4 script can
just read back what the first one deployed instead of re-deriving it — see
`AqueductV4Demo.s.sol`'s own doc comment for the full reasoning, including a stale-cache issue
that came up (and was resolved) while wiring this up.

## The Graph pipeline

`ExposureOracle` needs *something* to feed it a maker's exposure. That something is a subgraph
(`subgraph/`) plus a keeper script (`keeper/pushExposure.ts`):

- The subgraph indexes Aqua's own `Shipped`/`Pushed`/`Pulled`/`Docked` events into per-`(maker,
  app, strategyHash, token)` `StrategyBalance` entities — mirroring exactly what
  `Aqua.rawBalances(...)` would return on-chain at the same block. `Docked` doesn't list which
  tokens it closes, so `handleDocked` consults a `Strategy.tokens` list built up incrementally in
  `handlePushed` to close every one of them correctly.
- The keeper queries every active `StrategyBalance` for a maker, sums committed amounts per token
  across *every* strategy they've shipped (the "multiplier effect" this whole project is about),
  and compares that sum against a **live** `balanceOf` read of the maker's actual wallet — because
  Aqua's balances are allowance-style commitments, not custody; the real tokens sit in the maker's
  wallet the whole time (`Aqua.pull` calls `transferFrom(maker, ...)` directly). The worse of the
  two tokens' ratios becomes the `exposureBps` pushed to `ExposureOracle.pushExposure`.

Both pieces are complete, real code — the subgraph compiles cleanly to WASM via `graph build`
(`cd subgraph && npm install && npm run codegen && npx graph build`), and the keeper type-checks
cleanly (`cd keeper && npm install && npx tsc --noEmit`). What's *not* done, because it requires
infrastructure this environment doesn't have, is deploying the subgraph to a live indexer (Graph
Studio or a local `graph-node`) against a real Aqua deployment — there isn't one yet (see above).
`subgraph/subgraph.yaml` has the placeholder address/network clearly marked for exactly that step.

## Frontend

A Next.js dashboard (`frontend/`) drives everything above from a browser instead of the terminal:

```shell
cd frontend
npm install
npm run dev    # after the two forge scripts above have written deployment.json
```

Open `http://localhost:3000` with a wallet (MetaMask or similar) pointed at
`http://127.0.0.1:8545`, chain id `31337`. It shows:

- **A live exposure gauge** — polls `ExposureOracle.exposureOf(maker)` every few seconds and
  color-codes the maker's current band (safe / derated / halted).
- **Two swap panels**, side by side, backed by the same maker strategy: one calls
  `SwapVM.swap(...)` directly, the other calls Uniswap v4's `PoolSwapTest.swap(...)` through
  `AquaV4Hook`. Both work from a plain connected wallet, no deployed contract required as taker.
- **A keeper panel** — since there's no live subgraph deployment to drive `ExposureOracle`
  automatically (see below), this lets you push an exposure reading yourself and immediately feel
  both swap panels react to it.
- **An activity log** with real transaction hashes for everything above.

Two implementation details worth calling out because they took real verification, not
assumption, to get right:

- **The direct SwapVM panel needs no taker contract.** `TakerTraitsLib.build`'s packed bytes
  never actually embed the `taker` address for the flag combination used here (`isExactIn` +
  `useTransferFromAndAquaPush`, everything else at its empty/zero default) — SwapVM reads the
  real taker as `msg.sender` at call time instead. That makes `takerTraitsAndData` a *fixed*
  22-byte constant regardless of which wallet connects (`0x00000000000000000000000000000000000000000041`,
  in `frontend/lib/constants.ts`) — confirmed by literally calling `TakerTraitsLib.build` with
  those exact args in a throwaway Foundry test and diffing the output, not derived by hand from
  reading the packing logic alone. A plain anvil account with zero deployed contracts was used to
  swap directly against `SwapVM` and separately against the v4 pool via `cast send` before any of
  this was wired into the UI, to confirm both flows work for a bare wallet before relying on them.
- **The Uniswap panel reads amountOut from balance deltas, not the call's return value.**
  `PoolSwapTest.swap` returns a `BalanceDelta`, but ethers can only recover a state-changing
  call's return value by replaying it separately from the actual sent transaction — fragile and
  unnecessary here. The frontend just diffs the wallet's `tokenOut` balance before and after,
  which is simpler and exactly as accurate.

## The idea behind it (full project context)

1inch Aqua's whole premise is that the same wallet balance can back multiple strategies across
multiple venues at once (the "multiplier effect"). Nothing on-chain today knows a maker's *true*
uncommitted exposure across all of those venues simultaneously. `_exposureGate1D` is the missing
primitive that lets a maker's own SwapVM program price that risk in — fed by a live, standardized,
cross-protocol view of their positions (The Graph pipeline above) — and `AquaV4Hook` shows that
same risk-priced liquidity isn't locked to SwapVM: it can back a Uniswap v4 pool just as safely,
because the exposure check lives at the Aqua layer itself, not in whichever front-end calls it.
