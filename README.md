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

Put simply: **every failure mode in this system fails closed.** A wrong oracle reading, a stale
one, a stopped keeper, a maker who no longer trusts the feed — every one of them ends in a smaller
fill or no fill at all, never in a taker getting more than the maker's own program already
authorized. See [Threat model](#threat-model) below for the full breakdown, scenario by scenario.

## Three core innovations

Everything in this repo supports exactly three pieces, not a pile of loosely related features:

**① `ExposureGate1D`** — a new SwapVM primitive.
Converts an off-chain exposure reading into a one-way liquidity constraint: it can only ever
derate or halt a fill, never improve one. [`src/opcodes/ExposureGate.sol`](src/opcodes/ExposureGate.sol).

**② The Aqueduct Exposure Oracle** — a cross-strategy, cross-protocol risk layer.
Determines how much liquidity a maker can safely expose right now, aggregated across *every*
Aqua strategy they've shipped, not just the one being swapped against.
[`src/oracle/ExposureOracle.sol`](src/oracle/ExposureOracle.sol) (on-chain landing pad) +
[`subgraph/`](subgraph/) and [`keeper/pushExposure.ts`](keeper/pushExposure.ts) (off-chain
aggregation).

**③ `AquaV4Hook`** — venue-independent execution.
Makes the exact same Aqua liquidity, under the exact same exposure constraint, available through
a Uniswap v4 pool — proving the risk policy travels with the *liquidity strategy*, not with any
one execution venue. [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol).

## Live on Base Sepolia

Every contract below is really deployed and really exercised on Base Sepolia (chain id `84532`)
— not a local-only claim. Both the direct SwapVM path and the Uniswap v4 path were each verified
with a real, separately-submitted swap transaction (via `cast`) before being wired into the
frontend.

| Contract | Address |
|---|---|
| `Aqua` | [`0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461`](https://sepolia.basescan.org/address/0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461) |
| `ExposureOracle` | [`0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A`](https://sepolia.basescan.org/address/0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A) |
| `ExposureAwareAquaRouter` (SwapVM) | [`0xC008DD3D1293543d5FA7AD6eED285eD45E3d7cCc`](https://sepolia.basescan.org/address/0xC008DD3D1293543d5FA7AD6eED285eD45E3d7cCc) |
| `AquaV4Hook` | [`0xE115c49376c960B29D0bD77bF8C226a9562EAa88`](https://sepolia.basescan.org/address/0xE115c49376c960B29D0bD77bF8C226a9562EAa88) |

The v4 side deliberately does **not** deploy its own `PoolManager` or swap router — it uses
Uniswap's own real Base Sepolia deployment ([`PoolManager` at `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408),
[`PoolSwapTest` at `0x8B5bcC363ddE2614281aD875bad385E0A785D3B9`](https://sepolia.basescan.org/address/0x8B5bcC363ddE2614281aD875bad385E0A785D3B9))
— confirmed verified on BaseScan (contract names, constructor args, and transaction history all
cross-checked) before a single real transaction was sent through them. Only `AquaV4Hook` itself is
freshly deployed, since it has to be: it's this project's own contract, CREATE2-mined to encode
the right permission flags in its address the way every v4 hook must.

`ExposureOracle.setPausedByMaker` (the maker's own emergency kill switch, see [Threat
model](#threat-model) below) was added after the *original* Base Sepolia deployment, so this
`ExposureOracle` address is a redeploy that picked it up
([`script/AqueductRedeployOracle.s.sol`](script/AqueductRedeployOracle.s.sol) — reuses the
unaffected `Aqua`/`ExposureAwareAquaRouter`/tokens/maker/keeper as-is, and only deploys what
actually depends on the new oracle code: the oracle itself, a new order/strategy pointing at it,
and a fresh `AquaV4Hook` + pool bound to that new order). The redeploy's own on-chain verification
pushed a safe reading, ran one real swap on each venue, then proved the pause genuinely halts a
fill (`ExposureGateMakerPaused`) before immediately unpausing — the maker's strategy is live and
usable, not left stuck halted.

## Where to look

| What | File |
|---|---|
| The opcode itself, with the monotonicity argument spelled out | [`src/opcodes/ExposureGate.sol`](src/opcodes/ExposureGate.sol) |
| The on-chain oracle the opcode reads | [`src/oracle/ExposureOracle.sol`](src/oracle/ExposureOracle.sol) / [`IExposureOracle.sol`](src/oracle/IExposureOracle.sol) |
| Stock `AquaOpcodes` + the new instruction appended at the end (index 35), every existing index preserved | [`src/opcodes/ExposureAquaOpcodes.sol`](src/opcodes/ExposureAquaOpcodes.sol) |
| The deployable router wiring it together | [`src/routers/ExposureAwareAquaRouter.sol`](src/routers/ExposureAwareAquaRouter.sol) |
| Proof of the safety claim: 15 tests incl. two 257-run fuzz properties and a malicious-oracle narrative | [`test/ExposureGate.t.sol`](test/ExposureGate.t.sol) |
| End-to-end demo as real broadcast transactions on a local chain | [`script/AqueductDemo.s.sol`](script/AqueductDemo.s.sol) |
| The Uniswap v4 hook that sources swaps from the same exposure-gated maker strategy | [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) |
| Proof the hook actually moves real tokens through a real `PoolManager`, and that the exposure gate halts a v4 swap too | [`test/AquaV4Hook.t.sol`](test/AquaV4Hook.t.sol) |
| Proof the SAME maker's exposure policy produces bit-for-bit identical fills whether the swap runs through SwapVM directly or through the Uniswap v4 pool | [`test/CrossVenueConsistency.t.sol`](test/CrossVenueConsistency.t.sol) |
| Proof of the "multiplier effect" thesis itself: one maker's aggregate exposure across several Aqua strategies gates all of them identically, even a strategy that looks safe in isolation | [`test/MultiStrategyExposure.t.sol`](test/MultiStrategyExposure.t.sol) |
| The full chain connected end to end: multiple strategies → aggregate exposure → oracle → SwapVM (derated/halt), same reading → Uniswap v4 (same result) | [`test/EndToEndAggregateExposure.t.sol`](test/EndToEndAggregateExposure.t.sol) |
| Proof of the maker's own emergency kill switch: a third, independent security layer on top of keeper authorization and gate monotonicity | [`test/MakerEmergencyPause.t.sol`](test/MakerEmergencyPause.t.sol) |
| The Graph subgraph aggregating a maker's committed Aqua balances | [`subgraph/`](subgraph/) |
| The keeper that reads the subgraph and posts to `ExposureOracle` | [`keeper/pushExposure.ts`](keeper/pushExposure.ts) |
| The Next.js dashboard: exposure gauge, cross-venue proof panel, ungated-vs-gated comparison, both swap paths, risk policy, emergency halt, keeper control | [`frontend/`](frontend/) |
| One-off script that redeployed `ExposureOracle` to pick up the maker-pause feature, reusing everything else unaffected | [`script/AqueductRedeployOracle.s.sol`](script/AqueductRedeployOracle.s.sol) |

`lib/swap-vm` and `lib/aqua` are the real, unmodified 1inch repositories, and `lib/uniswap-hooks`
(which itself bundles a matching `v4-core`/`v4-periphery`) is OpenZeppelin's real, current Uniswap
v4 hooks utility library — all pulled in as dependencies, not reimplemented or mocked.

`_exposureGate1D` is appended to stock `AquaOpcodes`'s instruction table at index 35 —
**appended, not inserted or substituted** — so every existing SwapVM opcode keeps the exact index
it already has (see [`ExposureAquaOpcodes.sol`](src/opcodes/ExposureAquaOpcodes.sol)):

```
existing SwapVM opcodes            ExposureGate1D
        0 ... 34             +          #35
```

And here's exactly where a maker invokes it — building a program is just appending instructions,
the new one is not privileged or special-cased anywhere else in the pipeline (from
[`script/AqueductDemo.s.sol`](script/AqueductDemo.s.sol)):

```solidity
bytes memory program = bytes.concat(
    p.build(XYCSwap._xycSwapXD),                       // stock instruction: prices the swap
    p.build(                                            // #35: reads live exposure, derates/halts
        ExposureGate._exposureGate1D,
        ExposureGateArgsBuilder.build(address(oracle), MAX_EXPOSURE_BPS, HALT_EXPOSURE_BPS, 0)
    )
);
```

A 1inch reviewer should be able to see, from that snippet alone, that this extends SwapVM's actual
instruction pipeline rather than building an adjacent system that only vaguely resembles it.

## Why Aqua/SwapVM get redeployed fresh (on Base Sepolia, not just locally)

1inch's own repos ship no real mainnet or testnet Aqua/SwapVM deployment addresses — see
[`lib/aqua/config/constants.json`](lib/aqua/config/constants.json) and
[`lib/swap-vm/config/constants.json`](lib/swap-vm/config/constants.json), both zero-address
placeholders for local anvil (chain id `31337`). The track's own rules anticipate this directly:
*"Official Aqua/SwapVM contracts must be used (redeployments of a modified SwapVM contract is
allowed)"* and *"local forks are ok."* There is no live deployment to fork against, so both demo
scripts deploy fresh, unmodified-Aqua + modified-SwapVM instances themselves — locally on anvil
for the automated test suite (fast, free, deterministic), and for real on Base Sepolia for the
actual submission (see [Live on Base Sepolia](#live-on-base-sepolia) above). Uniswap's v4 core
*is* really deployed on Base Sepolia already, though, so that side of the demo uses Uniswap's own
`PoolManager` rather than redeploying it too.

## Run the tests

```shell
forge install   # pulls in swap-vm, aqua, and uniswap-hooks as dependencies
forge test -vv
```

31 tests across six suites, all passing:

**`ExposureGate.t.sol`** (15 tests) — the opcode itself, called directly through SwapVM:
- pass-through below the exposure threshold (exact equality with an ungated baseline), including
  the sharp edge exactly *at* the no-op threshold
- exact derate math at the midpoint between max and halt, both exact-in and exact-out, plus the
  sharp edges one bps above the no-op threshold and one bps below the halt threshold, and at both
  dust-sized and near-pool-depth swap amounts
- hard revert at and above the halt threshold
- stale-oracle revert
- a standalone narrative test walking a single maker through 0% → 70% → 90% (halt) → 100% (the
  absolute maximum `ExposureOracle` will accept) → a stale 0% reading, asserting at each step that
  the fill never improves versus the previous step and that neither an extreme nor a stale reading
  can ever be used to fill *better* than an honest, fresh, 0%-exposure quote
- **two 257-run property tests**: across the full exposure/amount input space, a gated exact-in
  fill never exceeds the ungated baseline's output, and a gated exact-out fill never requires
  less input than the baseline. This is what actually proves the monotonicity claim above, not
  just the example cases.

**`AquaV4Hook.t.sol`** (6 tests) — the same maker strategy, now sourcing a real Uniswap v4 pool:
- a real `PoolManager.swap()` in both directions, moving real ERC-20 balances, with the output
  traced back to the maker's Aqua balance shrinking by exactly the amount the taker received
- the exposure gate halting a **v4 swap**, not just a direct SwapVM call, with the revert bubbling
  up through `PoolManager`'s own `Hooks.sol` wrapping intact
- **a stale oracle reading halting a v4 swap too** — the direct-path stale test
  (`ExposureGate.t.sol`) doesn't by itself prove the v4 path enforces the same staleness check;
  this one does, with its own isolated hook/pool/strategy since the shared one in `setUp` doesn't
  have staleness enabled
- exact-output swaps rejected (out of scope, see below)
- direct third-party liquidity addition rejected (this hook is the pool's sole liquidity source)

**`CrossVenueConsistency.t.sol`** (3 tests) — the central cross-track claim, proven directly
rather than argued: one maker, two isolated strategies (identical program, identical initial
balances, distinguished only by a `Controls._salt` no-op so their `strategyHash`es differ) reading
the same `ExposureOracle` entry, swapped once each — one through SwapVM directly, one through the
v4 pool. At 10% and 70% exposure the two venues' `amountOut` are asserted **exactly equal**, not
just both-nonzero or approximately close; at 90% (the halt threshold) both revert with the same
`ExposureGateExceedsHaltThreshold`, the v4 side wrapped in `PoolManager`'s `CustomRevert.WrappedError`
as expected. This is what actually backs the "safety guarantee protects both paths" claim in the
opening paragraph above, rather than leaving it as an assertion about the code's structure.

Two extra assertions close the obvious follow-up question — *couldn't this equality just be an
artifact of how the test happens to be set up?* — rather than leaving it as a claim to take on
faith: `setUp` independently verifies, byte-for-byte, that the two strategies' program data is
identical except for the single trailing salt byte Aqua's own immutability check forces to differ
(not just "the doc comment says so"), and separately asserts `hook.swapVM() == swapVM` — i.e. the
v4 path doesn't run a second copy of the pricing/gating logic, it calls into the literal same
`ExposureAwareAquaRouter` instance the direct path calls. The equality is a consequence of that
shared code path, not a coincidence of two similarly-configured strategies.

**`MultiStrategyExposure.t.sol`** (2 tests) — the actual thesis of this whole project, not just
the opcode's local math: one maker wallet ships THREE Aqua strategies ($400/$300/$200) against a
single real $1,000 wallet balance (Aqua's balances are allowance-style commitments, not custody --
nothing on-chain stops this). The smallest strategy alone only ever claims 20% of the wallet and
would look perfectly safe judged in isolation; it is halted anyway once the maker's *aggregate*
exposure (900/1000 = 90%, exactly the sum-across-strategies computation `keeper/pushExposure.ts`
performs for real) is pushed to the shared oracle entry, because the gate reads a maker-level
number, not a per-strategy one. A second test then docks strategies one at a time and shows the
remaining strategy's fill genuinely recovers -- 70% (derated, strictly worse than an ungated
same-depth pool) then 40% (a pure no-op, exactly matching what an ungated strategy holding A's own
actual remaining reserves would have produced) -- proving the recovery direction, not just the
halt.

**`EndToEndAggregateExposure.t.sol`** (1 test) — the connected chain the two tests above only
prove one link of each: three real Aqua strategies ($400/$300/$200) combine into one aggregate
exposure number, that number is pushed to the one `ExposureOracle` entry both venues read, and the
SAME Aqua strategy ($400) backs BOTH a direct SwapVM integration and a real Uniswap v4 pool at the
same time. At 90% aggregate, both venues halt; docking a strategy down to 70% derates both; docking
again down to 40% is a pure no-op on both. Because the two venues here share ONE pool (the point is
literally that one strategy backs both), a swap on one shifts the reserves the other prices
against next — so instead of asserting bit-exact equality between the two (already proven
elsewhere for isolated pools), each venue's actual output is checked against what
`_exposureGate1D`'s own documented formula predicts from THAT venue's own live reserves at the
moment it swaps, closing the loop: aggregation → oracle → SwapVM, and separately, the same oracle
reading → Uniswap v4, both exactly on-formula.

**`MakerEmergencyPause.t.sol`** (4 tests) — the maker's own kill switch
(`ExposureOracle.setPausedByMaker`), a third security layer independent of the other two (keeper
authorization, gate monotonicity — see [Threat model](#threat-model)): pausing halts every fill
against that oracle entry even at 0% exposure with a perfectly fresh reading, unpausing restores
normal gating exactly, and an attacker calling `setPausedByMaker` only ever pauses *their own*
(nonexistent) strategy — `msg.sender`-scoped by construction, so there is no code path for pausing
someone else's.

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

## Threat model

Answers to the questions a judge is most likely to actually ask, written down explicitly rather
than left implicit in the code.

### The one sentence that covers all of it: every failure mode fails closed

Not "fails safely" or "degrades gracefully" — **fails closed**: every single thing that can go
wrong below ends in either a strictly smaller fill or no fill at all, never in a taker getting more
than the maker's own unsigned SwapVM program already authorized. That's the one property every row
in this table shares, and it's why none of them need to be trusted individually — the worst any of
them can do is deny a trade, never approve a bad one.

| Failure mode | Trigger | Fails closed by | Proven by |
|---|---|---|---|
| Unauthorized write | A non-keeper address calls `pushExposure` | Reverts — no write path exists at all | `onlyKeeper` modifier, `ExposureOracle.sol` |
| Wrong or malicious reading | Compromised keeper key, buggy Graph pipeline, garbage data | Can only derate or halt vs. the unsigned baseline, never improve it | `test_MaliciousOracle_CanOnlyEverMakeFillMoreConservative`, two 257-run fuzz properties |
| Stale reading | `block.timestamp > updatedAt + maxStaleness` | Hard revert — no fill, treated exactly like a dangerous reading | `ExposureGateOracleStale`, `test_Reverts_WhenOracleReadingStale` (direct) / `_V4Path` (v4) |
| Keeper stops entirely | No new pushes, ever | Same staleness revert kicks in automatically once `maxStaleness` elapses — not "the old value keeps working forever" | same tests as above |
| Maker distrusts the feed itself | Maker calls `setPausedByMaker(true)` | Halts immediately, with no staleness wait and no keeper cooperation needed | `test/MakerEmergencyPause.t.sol` |
| Exposure at or above the halt threshold | `exposureBps >= haltExposureBps` | Hard revert, regardless of venue | `ExposureGateExceedsHaltThreshold`, proven identical on SwapVM and Uniswap v4 in `test/CrossVenueConsistency.t.sol` |
| Exposure between max and halt | `maxExposureBps < exposureBps < haltExposureBps` | Not a failure, but the same principle: linear derate, strictly worse for the taker, never better | `test_Derate_*`, `test/EndToEndAggregateExposure.t.sol` |
| One maker over-committed across several strategies | `Σ committed > wallet balance` (Aqua allows this — see below) | The *aggregate* fails closed identically for every strategy that maker has shipped, even one that looks safe in isolation | `test/MultiStrategyExposure.t.sol`, `test/EndToEndAggregateExposure.t.sol` |

### Where does liquidity come from, where is risk calculated, and where does Uniswap fit?

Three separate questions with three separate, non-overlapping answers:

- **Liquidity** comes from Aqua — a maker's real wallet balance, made available via allowance-style
  commitments (`Aqua.ship`/`Aqua.pull`), the same as any other Aqua strategy.
- **Risk** is calculated by `ExposureOracle` → `_exposureGate1D` — entirely at the Aqua/SwapVM
  layer, fed by the off-chain Graph pipeline above.
- **Uniswap v4 is an execution venue**, nothing more. `AquaV4Hook` has no liquidity of its own; it
  sources every fill live from the same Aqua strategy and is gated by the same exposure check. It
  is not a separate system that happens to sit next to Aqua — it's another way to reach the exact
  same risk-priced liquidity.

That's also the direct answer to *"why isn't this just a normal Uniswap v4 hook?"* — a normal hook
bakes its logic into one pool. Here the risk constraint travels with the **Aqua strategy**, not
with any one pool:

```
   risk policy
        │
  Aqua strategy / SwapVM program
        │
        ├──────────────┬──────────────
        │              │              │
     SwapVM        Uniswap v4    (any future venue)
```

rather than:

```
  Uniswap pool
        │
   hard-coded hook logic  (dies with this one pool)
```

The same policy that gates a direct SwapVM swap today can gate a completely different venue
tomorrow, because the check never left the liquidity layer.

### Three independent layers, stacked, not just one

The table above is *what* fails closed and *how*; this is *why* it's structured as three
independent layers rather than one big check:

1. **Authorization** (keeps bad writes out) — only the `keeper` address on `ExposureOracle` can
   call `pushExposure` at all. An attacker without that key has no write path whatsoever, full stop.
2. **Monotonicity** (limits the damage of a bad-but-authorized write) — even if layer 1 is
   compromised, `_exposureGate1D`'s own math means the worst a wrong reading can do is fail closed:
   derate or halt, never improve a fill beyond what the maker's unsigned program already allowed.
   This is the property that lets the system say "we don't have to trust the oracle to trust the
   fill boundary."
3. **The maker's own override** (needs neither of the above to work) — `setPausedByMaker` is
   checked before the reading is even read, so it fails closed on the maker's own say-so alone, with
   no dependency on the keeper's key being intact or a stale timestamp catching up in time. Kept
   deliberately minimal: one `bool` per maker, `msg.sender`-scoped, no owner/admin override sitting
   on top of it.

Each layer covers a scenario the one below it doesn't: authorization stops a stranger, monotonicity
bounds a compromised keeper, and the maker's own switch covers the case where they simply don't
trust the pipeline right now, for whatever reason, and don't want to wait for staleness to catch up.

### Why we didn't bolt on a third protocol

Beyond the Graph (the data pipeline, not a swap venue), we deliberately did not integrate a third
DeFi protocol (Aave, Morpho, Curve, etc.) on top of 1inch + Uniswap. Those two already establish
the actual claim — *venue-independent, exposure-gated liquidity* — completely. A third, likely
half-finished integration would dilute that story rather than strengthen it. The scope this project
optimizes for is depth of proof on one thesis, not breadth of protocol logos.

## Run the on-chain demo

The [Base Sepolia deployment](#live-on-base-sepolia) above is exactly the output of running these
two scripts for real, in order, against Base Sepolia:

```shell
forge script script/AqueductDemo.s.sol \
  --rpc-url <base sepolia rpc> \
  --private-key <funded base sepolia account> \
  --broadcast --slow -vvvv
forge script script/AqueductV4Demo.s.sol \
  --rpc-url <base sepolia rpc> \
  --private-key <the same funded account> \
  --broadcast --slow -vvvv
```

(`--slow` sends each transaction and waits for it to confirm before sending the next, rather than
firing them off concurrently — some RPC providers report a transaction's nonce as available slightly
before it's actually safe to build the next one on top of, and `--slow` avoids that race. Omit it
against a local anvil node, where it doesn't matter.)

To run the same thing locally instead (no real testnet ETH needed, resets every time):

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

Locally, `AqueductV4Demo.s.sol` deploys its own `PoolManager`/`PoolSwapTest` (via `vm.deployCode`,
since no real v4 deployment exists on anvil); on Base Sepolia it uses Uniswap's real ones instead
(see above) — the script picks based on `block.chainid`.

Either way, this deploys real contracts and ships real maker liquidity into Aqua as genuine, mined
transactions (not `forge test` pranks — verifiable independently with `cast receipt` against the
tx hashes forge writes to `broadcast/*/<chain id>/run-latest.json`), then runs three scenarios as
the maker's reported exposure climbs:

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

`script/AqueductDemoContinue.s.sol` is a one-off, not part of the normal flow: the Base Sepolia
run above hit a nonce-tracking mismatch against the RPC provider partway through (after the first
6 contracts had already deployed successfully), and rather than fight forge's cached broadcast
state against it, that script just picks up from the 6 already-deployed addresses and finishes
the rest as a fresh broadcast. Kept as a record of what actually happened, not a general-purpose
tool — the address constants inside it are specific to this one deployment.

`script/AqueductRedeployOracle.s.sol` is a second one-off: `ExposureOracle.setPausedByMaker`
(the maker's emergency kill switch, added per the project review's threat-model feedback) was
written after the deployment above, so this script redeploys just the oracle -- and everything
that has to change alongside it (a new order pointing at the new oracle, since orders are
immutable once shipped; a new `AquaV4Hook` + pool bound to that new order, since a hook's order is
immutable too) -- while reusing `Aqua`, `ExposureAwareAquaRouter`, both `TokenMock`s, and the
maker/keeper addresses completely unchanged. Its own on-chain verification pushed a safe reading,
ran one real swap through each venue, then proved the pause genuinely halts a fill before
immediately undoing it, so the live strategy was never left stuck halted for the next visitor.

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
cleanly (`cd keeper && npm install && npx tsc --noEmit`). What's *not* done is deploying the
subgraph to a live indexer (Graph Studio or a local `graph-node`) and running the keeper
continuously somewhere — genuine off-chain infrastructure, not something this environment stands
up on its own. There *is* now a real Aqua deployment to index, though (see
[Live on Base Sepolia](#live-on-base-sepolia)): `subgraph/subgraph.yaml` still has its
`network`/`address`/`startBlock` fields as placeholders, and this is exactly the piece left for
whoever picks up the Graph side to fill in with `network: base-sepolia`, the real `Aqua` address
above, and its actual deployment block, before running `graph deploy`.

## Frontend

A Next.js dashboard (`frontend/`) drives everything above from a browser instead of the terminal —
no local setup required, since it reads `frontend/public/deployment.json`, which is committed and
already points at the real Base Sepolia deployment above:

```shell
cd frontend
npm install
npm run dev
```

Open `http://localhost:3000` with a wallet (MetaMask or similar) switched to Base Sepolia (chain
id `84532`) — get free testnet ETH from a Base Sepolia faucet first if you don't have any. The
read-only dashboard data (exposure gauge, keeper panel) uses Base's own public RPC
(`https://sepolia.base.org`) so it works even before a wallet connects; it never uses a personal
Alchemy/Infura key client-side, since that file ships to every visitor's browser. It shows:

- **A live exposure gauge** — polls `ExposureOracle.exposureOf(maker)` every few seconds and
  color-codes the maker's current band (safe / derated / halted).
- **A "same strategy, same risk, different venue" panel** — the Uniswap track story in one
  screen: the maker address, Aqua strategy hash, and live exposure, feeding into a side-by-side
  SwapVM/Uniswap v4 status that always shows the identical band for both, because both venues read
  the identical oracle entry through the identical opcode (`CrossVenueProofPanel.tsx`, backed by
  `test/CrossVenueConsistency.t.sol`'s on-chain proof that this isn't a UI coincidence).
- **Two swap panels**, side by side, backed by the same maker strategy: one calls
  `SwapVM.swap(...)` directly, the other calls Uniswap v4's `PoolSwapTest.swap(...)` through
  `AquaV4Hook`. Both work from a plain connected wallet, no deployed contract required as taker.
- **An ungated-vs-gated comparison panel** — types an amount once and shows it priced two ways
  from the maker's *live* pool reserves: what the constant-product curve alone would give up (no
  exposure gate at all) next to what it actually gives up right now, plus the resulting liquidity
  reduction percentage and a dollar-style "$X committed / $Y in wallet = Z% exposure" breakdown
  (`BaselineComparisonPanel.tsx`). Works from public reads alone — no wallet or token balance
  needed to see the comparison, only to actually swap.
- **A risk policy panel** — makes `maxExposureBps`/`haltExposureBps` visible as the
  maker-configurable arguments they actually are (`ExposureGateArgsBuilder.build`), not hackathon
  constants, showing this deployment's chosen thresholds alongside two illustrative alternative
  profiles (`RiskPolicyPanel.tsx`).
- **A maker emergency-halt panel** — the third security layer from the [threat
  model](#threat-model) above, wired to a real signed transaction from the demo maker's own key
  (the same non-secret, derivable-by-anyone pattern the keeper panel below already uses); live on
  this deployment (`EmergencyPausePanel.tsx`). Falls back to an explicit "not live on this
  deployment" state rather than failing silently if pointed at an older `ExposureOracle` that
  predates this function.
- **A keeper panel** — since there's no live subgraph deployment to drive `ExposureOracle`
  automatically (see below), this lets you push an exposure reading yourself and immediately feel
  every panel above react to it.
- **An activity log** with real transaction hashes for everything above.

Three implementation details worth calling out because they took real verification, not
assumption, to get right:

- **The direct SwapVM panel needs no taker contract.** `TakerTraitsLib.build`'s packed bytes
  never actually embed the `taker` address for the flag combination used here (`isExactIn` +
  `useTransferFromAndAquaPush`, everything else at its empty/zero default) — SwapVM reads the
  real taker as `msg.sender` at call time instead. That makes `takerTraitsAndData` a *fixed*
  22-byte constant regardless of which wallet connects (`0x00000000000000000000000000000000000000000041`,
  in `frontend/lib/constants.ts`) — confirmed by literally calling `TakerTraitsLib.build` with
  those exact args in a throwaway Foundry test and diffing the output, not derived by hand from
  reading the packing logic alone. A plain wallet with zero deployed contracts was used to swap
  directly against `SwapVM` and separately against the v4 pool via `cast send` -- on local anvil
  first, then for real on Base Sepolia -- before either flow was wired into the UI, to confirm
  both work for a bare wallet before relying on them.
- **The Uniswap panel reads amountOut from balance deltas, not the call's return value.**
  `PoolSwapTest.swap` returns a `BalanceDelta`, but ethers can only recover a state-changing
  call's return value by replaying it separately from the actual sent transaction — fragile and
  unnecessary here. The frontend just diffs the wallet's `tokenOut` balance before and after,
  which is simpler and exactly as accurate.
- **The ungated baseline is computed client-side, not via a second on-chain call.** There's only
  one strategy shipped on-chain (the gated one) — no separate ungated deployment to call for
  comparison. `frontend/lib/xyc.ts` instead mirrors `XYCSwap.sol`'s exact-in formula
  (`amountOut = amountIn * balanceOut / (balanceIn + amountIn)`, floor division, byte-for-byte the
  same as the Solidity) and `ExposureGate.sol`'s derate formula, both applied to a live
  `Aqua.safeBalances` read of the *actual current* reserves — so "ungated" here means "what this
  exact pool, right now, would give up with no gate," not a rough approximation, and it works from
  public reads alone before a wallet even connects.

## The idea behind it (full project context)

1inch Aqua's whole premise is that the same wallet balance can back multiple strategies across
multiple venues at once (the "multiplier effect", proven directly in
[`test/MultiStrategyExposure.t.sol`](test/MultiStrategyExposure.t.sol) — a strategy that looks 20%
safe in isolation still halts once the maker's *aggregate* commitment crosses the threshold).
Nothing on-chain today knows a maker's *true* uncommitted exposure across all of those venues
simultaneously. `_exposureGate1D` is the missing primitive that lets a maker's own SwapVM program
price that risk in — monotonic by construction, so a wrong or malicious reading can only ever make
it more conservative, and backed by a maker-held kill switch as a third, independent layer on top
— fed by a live, standardized, cross-protocol view of their positions (The Graph pipeline above).
`AquaV4Hook` then proves that same risk-priced liquidity isn't locked to SwapVM: it can back a
Uniswap v4 pool just as safely, byte-for-byte the identical outcome as the direct path
([`test/CrossVenueConsistency.t.sol`](test/CrossVenueConsistency.t.sol)), because the exposure
check lives at the Aqua layer itself, not in whichever front-end calls it.
[`test/EndToEndAggregateExposure.t.sol`](test/EndToEndAggregateExposure.t.sol) connects both halves
in one run: three real strategies aggregate into one exposure number, that number gates a real
SwapVM fill, and the identical number gates the identical strategy's real Uniswap v4 fill too.

We identified a specific risk created by Aqua's multiplier effect, introduced a new SwapVM
primitive to control it, mathematically constrained the oracle so it can only ever make liquidity
safer, and proved that the exact same safety policy holds when that Aqua liquidity is executed
through Uniswap v4 instead of directly. Every failure mode along the way — a bad reading, a stale
one, a stopped keeper, a maker who no longer trusts the feed — **fails closed**, never open. That's
the whole thesis — everything else in this repo exists to prove it, not to extend it.
