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

## Uniswap v4 contribution

This isn't "a hook we bolted on to also qualify for a second track." It's the load-bearing proof
of the whole project's central claim — that exposure-gated liquidity is a property of the
**strategy**, not of any one execution venue — and along the way it required solving a real,
non-obvious v4 problem generically enough that we extracted it into a reusable base contract.

**The hard v4 problem, solved for real:** `PoolManager`'s flash accounting only credits a
swapper's payment to the pool's real reserves *after* `PoolManager.swap()` returns — so a hook
that wants to synchronously hand back liquidity sourced from *outside* the pool (not the pool's own
curve) cannot `take()` the swapper's input inside `beforeSwap`; the manager isn't holding it yet.
`AquaV4Hook` solves this with a working-capital float: it mints itself ERC-6909 claims for the
swapper's input (legal, since claims are accounting entries, not a real-balance check), funds the
external leg — a real Aqua maker strategy, executed through its full exposure-gated SwapVM program
— from its own pre-seeded balance, settles the real output to the swapper, and later reconciles the
float via a permissionless `sweepClaims()`. Full mechanism:
[`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) lines 20–63 (contract-level doc) and
[lines 111–119](src/hooks/AquaV4Hook.sol#L111-L119) (`_fillFromExternalLiquidity` itself); the
shared claims/float/settle/sweep machinery it runs inside lives in
[`src/hooks/AsyncLiquidityHook.sol`](src/hooks/AsyncLiquidityHook.sol#L169-L194) (`_beforeSwap`).

**Extracted into a reusable base, not kept as a private detail:**
[`src/hooks/AsyncLiquidityHook.sol`](src/hooks/AsyncLiquidityHook.sol) implements that entire
claims → float → settle → sweep sequence as an `abstract contract` any hook can inherit — an
integrator implements exactly one method, `_fillFromExternalLiquidity`. We proved it's genuinely
generic, not secretly shaped around Aqua, with **two independent implementations against a real
`PoolManager`**:
- [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) — the real integration, live on Base
  Sepolia, proven in [`test/AquaV4Hook.t.sol`](test/AquaV4Hook.t.sol) (6 tests).
- [`test/mocks/FixedRateAsyncHook.sol`](test/mocks/FixedRateAsyncHook.sol) — a deliberately
  trivial fixed-rate hook sharing zero code or state with the first, proven in
  [`test/AsyncLiquidityHook.t.sol`](test/AsyncLiquidityHook.t.sol) (5 tests, including that
  `sweepClaims` — shared, untouched base-contract code — reconciles the float correctly for this
  completely different implementation too).

**Why it's not just "using a hook" — it's stress-testing what v4 hooks can safely do:**
`AquaV4Hook`'s pool carries *zero* liquidity of its own — every fill, in both directions, on real
Base Sepolia transactions, comes from external state the hook has no privileged access to bypass
(`Aqua.pull` only accepts calls from the exact registered `app`, so the *only* way to draw the
maker's funds is a real `swapVM.swap()` call, running the maker's *entire* program, exposure gate
included). [`test/CrossVenueConsistency.t.sol`](test/CrossVenueConsistency.t.sol) then proves this
external-liquidity-sourcing hook produces **bit-for-bit identical output** to a direct SwapVM call
under the identical exposure state — verified with real, non-simulated transactions on Base
Sepolia, not just in a test EVM.

**A second, independent v4 capability on top of the first — risk-adjusted dynamic fees:**
`AquaV4Hook`'s `beforeSwapReturnDelta` pricing override (above) is one v4 mechanism; this is a
different one, stacked on top rather than replacing it. Pools bound to this hook can opt in
(purely via the pool's own `PoolKey.fee` at initialization — `LPFeeLibrary.DYNAMIC_FEE_FLAG`
instead of a static value) to a swap fee that scales with the *same* maker's live `ExposureOracle`
reading that already drives `_exposureGate1D`'s SwapVM-side derate/halt — one real-time risk signal,
expressed through two completely different protocols' native mechanisms simultaneously. The fee is
a linear curve from 5 bps (unexposed) to 100 bps (approaching the same 90% halt line the gate
itself uses), applied two ways: a per-swap override returned from `beforeSwap`
(`LPFeeLibrary.OVERRIDE_FEE_FLAG`, mirroring `uniswap-hooks`'s own `BaseOverrideFee` pattern) that
actually reduces what the taker receives, and a persisted `updateDynamicLPFee` call via a
permissionless `refreshFee()` (mirroring `BaseDynamicFee`'s `_poke` pattern) so the pool's fee is
independently queryable via `StateLibrary.getSlot0` — no swap required. Static-fee pools bound to
the exact same hook source (including the one `CrossVenueConsistencyTest` proves bit-for-bit
identical to the direct SwapVM path) are completely unaffected — proven directly, not just
inferred, in [`test/DynamicFeeHook.t.sol`](test/DynamicFeeHook.t.sol) (6 tests). Live on Base
Sepolia: see [Live on Base Sepolia](#live-on-base-sepolia) below.

**Uniswap developer feedback:** [`FEEDBACK.md`](FEEDBACK.md) — the specific friction points above
(the flash-accounting settlement order, the missing reference pattern for synchronous
external-liquidity hooks, a `HookMiner` deployer gotcha, and a real bug of our own caught only by
independently reading on-chain storage after conflating the dynamic-fee override with persisted
fee state), submitted via the
[Uniswap Developer Feedback Form](https://developers.uniswap.org/hackathon-feedback).

## Live on Base Sepolia

Every contract below is really deployed and really exercised on Base Sepolia (chain id `84532`)
— not a local-only claim. Both the direct SwapVM path and the Uniswap v4 path were each verified
with a real, separately-submitted swap transaction (via `cast`) before being wired into the
frontend.

| Contract | Address |
|---|---|
| `Aqua` | [`0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461`](https://sepolia.basescan.org/address/0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461) |
| `ExposureOracle` | [`0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A`](https://sepolia.basescan.org/address/0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A) |
| `ExposureAwareAquaRouter` (SwapVM) | [`0x00449DD6DCD06327d0ae98f013CfFb7426658B21`](https://sepolia.basescan.org/address/0x00449DD6DCD06327d0ae98f013CfFb7426658B21) |
| `AquaV4Hook` (Strategy A pool, static fee — the bit-for-bit-identical-to-SwapVM pool) | [`0xc806b36637A58583458F00f431ff66b14667aA88`](https://sepolia.basescan.org/address/0xc806b36637A58583458F00f431ff66b14667aA88) |
| `AquaV4Hook` (Strategy A pool, risk-adjusted dynamic fee — see below) | [`0x0D2900ad215003D2b2aBBAa127b321c80e35eA88`](https://sepolia.basescan.org/address/0x0D2900ad215003D2b2aBBAa127b321c80e35eA88) |
| Strategy P — price + risk aware position (see below) | strategy hash `0xe3f9f24ede56f811c1201b8811f731d7d0f91b8bd2aea824b272ad201c0bcd88` |

Live off-chain links: dashboard [`aqueduct-protocol.vercel.app`](https://aqueduct-protocol.vercel.app/) ·
subgraph on [Subgraph Studio (`ethonline`, v0.3.0)](https://thegraph.com/studio/subgraph/ethonline) ·
[query endpoint](https://api.studio.thegraph.com/query/1758739/ethonline/v0.3.0).

### A real bug found during live testing, and how it was actually fixed

While demoing the maker-pause kill switch live, the *oracle* correctly recorded the pause and
emitted the right event, but a real swap against the then-live `ExposureAwareAquaRouter` still
went through. Root cause, confirmed with `cast run` against the actual failing transaction (not
inferred): `_exposureGate1D` — like every SwapVM instruction — is an **internal Solidity
function**, compiled directly into whichever router inherits it. It is never called externally.
`ExposureOracle.setPausedByMaker` had been added to the source and a *new oracle* deployed to pick
it up ([`script/AqueductRedeployOracle.s.sol`](script/AqueductRedeployOracle.s.sol)), but that
script reused the *existing* router — bytecode compiled before the pause check existed in source —
so `isPausedByMaker` was never actually invoked at runtime on that router, on either venue, even
though every Foundry test passed (tests always deploy a fresh router from current source, so they
could never have caught this).

An earlier attempt to verify the same fix was itself a false positive: it checked only whether a
call reverted, not *why* — the revert it saw was an unrelated insufficient-balance failure, not the
pause check. The actual fix
([`script/AqueductV2Redeploy.s.sol`](script/AqueductV2Redeploy.s.sol)) deploys a fresh router from
current source and re-ships every strategy under it (`Aqua.pull`/`push` are keyed by
`_balances[maker][app][strategyHash][token]`, so a new router address is a new `app` identity —
strategies are re-created, not migrated), then verifies the fix by decoding the **exact revert
selector** on both the direct SwapVM and Uniswap v4 paths — `bytes4(revertData) ==
ExposureGate.ExposureGateMakerPaused.selector`, not just success/failure — before unpausing and
confirming a real swap restores normally. Both the script's own on-chain assertions and an
independent post-deploy `cast call` (see the commit history / broadcast artifacts under
[`broadcast/AqueductV2Redeploy.s.sol/`](broadcast/AqueductV2Redeploy.s.sol/)) confirm the pause now
genuinely halts both venues.

The v4 side deliberately does **not** deploy its own `PoolManager` or swap router — it uses
Uniswap's own real Base Sepolia deployment ([`PoolManager` at `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408),
[`PoolSwapTest` at `0x8B5bcC363ddE2614281aD875bad385E0A785D3B9`](https://sepolia.basescan.org/address/0x8B5bcC363ddE2614281aD875bad385E0A785D3B9))
— confirmed verified on BaseScan (contract names, constructor args, and transaction history all
cross-checked) before a single real transaction was sent through them. Only `AquaV4Hook` itself is
freshly deployed, since it has to be: it's this project's own contract, CREATE2-mined to encode
the right permission flags in its address the way every v4 hook must.

`ExposureOracle.setPausedByMaker` (the maker's own emergency kill switch, see [Threat
model](#threat-model) below) was added in two stages on Base Sepolia:
[`script/AqueductRedeployOracle.s.sol`](script/AqueductRedeployOracle.s.sol) first redeployed only
the oracle to add the flag/storage, which is why the pause bug above wasn't caught immediately —
and [`script/AqueductV2Redeploy.s.sol`](script/AqueductV2Redeploy.s.sol) then redeployed the
*router* too, which is the piece that actually had to change since the pause check compiles into
it. `AquaV2Redeploy` also re-shipped Strategies A/B/C under the new router and shipped a new
composed position (see below); its on-chain verification re-pushed a safe reading, ran one real
swap on each venue, then proved the pause genuinely halts a fill with the exact expected
selector before immediately unpausing — the maker's strategies are live and usable, not left stuck
halted.

### Strategy P — a sophisticated position stacking three instructions

Alongside the plain exposure-gated strategies, one maker program on Base Sepolia composes three
SwapVM instructions in sequence: `_xycSwapXD` (prices the swap) → `_oraclePriceAdjuster1D`
(1inch's own instruction, pointed at a real, independently-verified Chainlink ETH/USD feed at
[`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`](https://sepolia.basescan.org/address/0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1)
— only ever *improves* the taker's price toward the oracle, capped at a max +3% adjustment) →
`_exposureGate1D` (the same risk gate as every other strategy here). The composition order matters:
the derate/halt applies *on top of* whatever the price adjuster already did, so a favorable oracle
reading can never be used to bypass a halt. See
[`test/SophisticatedPosition.t.sol`](test/SophisticatedPosition.t.sol) for the exact-formula proof
this mirrors, and [`script/AqueductV2Redeploy.s.sol`](script/AqueductV2Redeploy.s.sol) for the real
Base Sepolia shipment (strategy hash
`0xe3f9f24ede56f811c1201b8811f731d7d0f91b8bd2aea824b272ad201c0bcd88`).

### The dynamic-fee pool — the same maker, the same oracle, a second Uniswap mechanism

A second, additional v4 pool ([`script/AqueductV3DynamicFee.s.sol`](script/AqueductV3DynamicFee.s.sol))
binds a fresh `AquaV4Hook` to the *exact same* already-shipped Strategy A order and oracle, but
initializes the pool with `LPFeeLibrary.DYNAMIC_FEE_FLAG` instead of a static fee — the existing
Strategy A pool above is completely untouched. Verified for real on Base Sepolia: at 10% exposure
the fee is 1555 pips (of the 500–10,000 pip range), and raising exposure to 70% raised it to 7888
pips, both matching the exact predicted formula (`require`-checked in the script, not just logged),
and `refreshFee()` independently persisted the fee with zero swaps involved — confirmed afterward
by reading the pool's raw storage via `extsload` directly (poolId
`0x7bf07bfabe7eb1773eb3be5a319ddbaa59db133427d56e0508ad6c42958d047a`), the same
"don't trust your own script's report, verify the real outcome" discipline that caught the
maker-pause bug above. See [`test/DynamicFeeHook.t.sol`](test/DynamicFeeHook.t.sol) for the local
proof and [`FEEDBACK.md`](FEEDBACK.md) for a real bug this uncovered in our own first version of
the verification script.

## Where to look

| What | File |
|---|---|
| The opcode itself, with the monotonicity argument spelled out | [`src/opcodes/ExposureGate.sol`](src/opcodes/ExposureGate.sol) |
| The on-chain oracle the opcode reads | [`src/oracle/ExposureOracle.sol`](src/oracle/ExposureOracle.sol) / [`IExposureOracle.sol`](src/oracle/IExposureOracle.sol) |
| Stock `AquaOpcodes` + the new instruction appended at the end (index 35), every existing index preserved | [`src/opcodes/ExposureAquaOpcodes.sol`](src/opcodes/ExposureAquaOpcodes.sol) |
| The deployable router wiring it together | [`src/routers/ExposureAwareAquaRouter.sol`](src/routers/ExposureAwareAquaRouter.sol) |
| Proof of the safety claim: 15 tests incl. two 257-run fuzz properties and a malicious-oracle narrative | [`test/ExposureGate.t.sol`](test/ExposureGate.t.sol) |
| Stateful-fuzz invariant suite: a handler drives random pushes/pauses/swaps for 128,000 calls, checked against ghost accounting per token | [`test/ExposureGateInvariant.t.sol`](test/ExposureGateInvariant.t.sol) |
| The composed price-adjuster + exposure-gate position ("Strategy P"), with the exact-formula proof both bounds hold from either direction | [`test/SophisticatedPosition.t.sol`](test/SophisticatedPosition.t.sol) |
| The real fix for the maker-pause bug: fresh router, re-shipped strategies, new sophisticated position, exact-selector fix verification | [`script/AqueductV2Redeploy.s.sol`](script/AqueductV2Redeploy.s.sol) |
| The risk-adjusted dynamic-fee capability: per-swap fee override + persisted `updateDynamicLPFee`, both driven by the same exposure oracle | [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) — [`_riskFeePips` (L121–129)](src/hooks/AquaV4Hook.sol#L121-L129), [`_applyFee` (L131–140)](src/hooks/AquaV4Hook.sol#L131-L140), [`refreshFee` (L142–153)](src/hooks/AquaV4Hook.sol#L142-L153) |
| Proof the dynamic fee is opt-in per pool (a static-fee pool bound to the same hook code is untouched) and matches the exact predicted formula at every exposure level | [`test/DynamicFeeHook.t.sol`](test/DynamicFeeHook.t.sol) |
| The real Base Sepolia deployment of the dynamic-fee pool, verified against exact `require`d formulas and independently re-checked via raw storage reads | [`script/AqueductV3DynamicFee.s.sol`](script/AqueductV3DynamicFee.s.sol) |
| End-to-end demo as real broadcast transactions on a local chain | [`script/AqueductDemo.s.sol`](script/AqueductDemo.s.sol) |
| The Uniswap v4 hook that sources swaps from the same exposure-gated maker strategy | [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) |
| Proof the hook actually moves real tokens through a real `PoolManager`, and that the exposure gate halts a v4 swap too | [`test/AquaV4Hook.t.sol`](test/AquaV4Hook.t.sol) |
| The reusable v4 base contract extracted from `AquaV4Hook`: claims/float/settle/sweep for any hook sourcing fills from external liquidity | [`src/hooks/AsyncLiquidityHook.sol`](src/hooks/AsyncLiquidityHook.sol) |
| A second, independent (non-Aqua) implementation of that base, proving it's genuinely generic | [`test/mocks/FixedRateAsyncHook.sol`](test/mocks/FixedRateAsyncHook.sol) / [`test/AsyncLiquidityHook.t.sol`](test/AsyncLiquidityHook.t.sol) |
| Real Uniswap v4 developer feedback from building this (submitted via their feedback form) | [`FEEDBACK.md`](FEEDBACK.md) |
| Proof the SAME maker's exposure policy produces bit-for-bit identical fills whether the swap runs through SwapVM directly or through the Uniswap v4 pool | [`test/CrossVenueConsistency.t.sol`](test/CrossVenueConsistency.t.sol) |
| Proof of the "multiplier effect" thesis itself: one maker's aggregate exposure across several Aqua strategies gates all of them identically, even a strategy that looks safe in isolation | [`test/MultiStrategyExposure.t.sol`](test/MultiStrategyExposure.t.sol) |
| The full chain connected end to end: multiple strategies → aggregate exposure → oracle → SwapVM (derated/halt), same reading → Uniswap v4 (same result) | [`test/EndToEndAggregateExposure.t.sol`](test/EndToEndAggregateExposure.t.sol) |
| Proof of the maker's own emergency kill switch: a third, independent security layer on top of keeper authorization and gate monotonicity | [`test/MakerEmergencyPause.t.sol`](test/MakerEmergencyPause.t.sol) |
| The Graph subgraph aggregating a maker's committed Aqua balances | [`subgraph/`](subgraph/) |
| The keeper that reads the subgraph and posts to `ExposureOracle` | [`keeper/pushExposure.ts`](keeper/pushExposure.ts) |
| The Next.js dashboard: exposure gauge, cross-venue proof panel, ungated-vs-gated comparison, both swap paths, risk policy, emergency halt, keeper control | [`frontend/`](frontend/) |
| One-off script that redeployed `ExposureOracle` to pick up the maker-pause feature, reusing everything else unaffected | [`script/AqueductRedeployOracle.s.sol`](script/AqueductRedeployOracle.s.sol) |
| A live, on-chain rehearsal of the pitch demo's 5-scene script against real deployed Base Sepolia bytecode | [`script/NarrativeDemo.s.sol`](script/NarrativeDemo.s.sol) |

`NarrativeDemo.s.sol` was dry-run–verified first, then broadcast for real once a concrete reason
appeared to want live multi-strategy data: The Graph track's rules disqualify mocked/local-only
datasets, so a genuine multi-strategy aggregate needed to actually exist on-chain for the subgraph
to index. It shipped two real padding strategies (`B`, `C`, matching the $400/$300/$200-style
narrative) alongside the existing `A`, plus a freshly-matched pair (`E` direct-only, `F` v4-only,
with a second `AquaV4Hook` + pool) purely to make Scene 3's cross-venue equality bit-exact rather
than merely close. `AggregateExposurePanel.tsx` below now reads real committed amounts for A/B/C
via `deployment.json`'s `strategies` array — no placeholders needed anymore.

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

49 tests across ten suites, all passing:

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

**`ExposureGateInvariant.t.sol`** (2 invariants, 128,000 calls each) — where the property-fuzz
tests above check one call with random inputs, this runs long random *sequences* of
ship/push-exposure/pause/swap (Foundry's stateful invariant fuzzing) and, on every single swap
attempt, asserts the real result matches exactly what the gate's own formula predicts from
whatever state that specific call happens to land on — proving the fail-closed guarantee survives
arbitrary interleavings of state changes, not just isolated calls. A second invariant
independently cross-checks Aqua's own committed-balance bookkeeping against ghost accounting
tracked outside the contract, across the same random runs.

**`SophisticatedPosition.t.sol`** (5 tests) — a maker program composing *three* SwapVM
instructions, not one: `_xycSwapXD` → `_oraclePriceAdjuster1D` → `_exposureGate1D`. The middle
instruction is 1inch's own `OraclePriceAdjuster` — already shipped in `swap-vm`, but never wired
into stock `AquaOpcodes` until this project. Composed together, a taker's fill is bounded from
*both* directions by two independent, opposite-facing oracles: the price adjuster can only ever
improve the fill toward a real Chainlink feed (capped), and the exposure gate can only ever worsen
it toward the maker's real risk (capped the other way) — and neither can override the other's
direction. Proven exactly: a favorable price genuinely improves the fill up to its cap, an
absurd/malicious price is still capped at exactly the same bound, and even the *most* favorable
possible price cannot bypass a halt.

**`AsyncLiquidityHook.t.sol`** (5 tests) — see [Uniswap v4 contribution](#uniswap-v4-contribution)
above: proves the reusable base contract works correctly for a completely independent, non-Aqua
implementation against a real `PoolManager`, including that `sweepClaims` (shared, untouched base
code) reconciles the float correctly.

**`DynamicFeeHook.t.sol`** (6 tests) — the second, independent v4 capability: a fee floor at 0%
exposure matching the exact predicted formula; the fee scaling with exposure below the gate's own
derate threshold; the fee compounding *on top of* the gate's derate once exposure enters that band
(not replacing it); the fee saturating at its documented ceiling approaching halt; `refreshFee()`
persisting the current fee with zero swaps involved (checked via `StateLibrary.getSlot0`); and a
second pool bound to the same hook source but a static fee, proven byte-for-byte unaffected.

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
cleanly (`cd keeper && npm install && npx tsc --noEmit`). Both are also **live**: the subgraph is
deployed to [Subgraph Studio as `ethonline`](https://thegraph.com/studio/subgraph/ethonline) (v0.3.0, Base Sepolia — query it in the Studio
Playground or at `https://api.studio.thegraph.com/query/1758739/ethonline/v0.3.0`), and the keeper
has run for real against it (pushed exposure for maker `0x5067…`, [tx mined on Base Sepolia](https://sepolia.basescan.org/tx/0x19550d3f6e2162f901f39eab8d00657aab6eae6e0ce5111907898625441b9cac);
re-run any time with `SUBGRAPH_URL=… RPC_URL=… ORACLE_ADDRESS=… KEEPER_PRIVATE_KEY=… npm start`
from `keeper/`).

### ExposurePosition: one entity joining two contracts plus v4 swaps

On top of the balance bookkeeping above, the subgraph maintains **one `ExposurePosition` per
(maker, strategyHash)**, joined from three event sources:

- **Aqua** (`Shipped`/`Pushed`/`Pulled`/`Docked`) → `committedAmount` (re-summed across apps from
  live `StrategyBalance` rows) and `makerWalletBalance` via a live `balanceOf()` eth-call on every
  touch — wallet balance is not an event, so it is read, not indexed.
- **ExposureOracle** (`ExposureUpdated`/`MakerPauseUpdated`) → `exposureBps`, `isPausedByMaker`,
  and derived `status` (`SAFE` / `DERATED` / `HALTED` / `PAUSED` against hardcoded 50% / 90%
  thresholds — every live strategy uses them, so no program-byte decoding). Maker-level events fan
  out to every position via an internal `Maker.positionIds` index, and each fan-out writes an
  immutable **`ExposureSnapshot`** — exposure-over-time (10% → 40% → 70% → 90%) is one ordered query.
- **Uniswap v4 PoolManager** (`Swap`) → confirms the `uniswap-v4` venue. The hook-bound pools are
  hardcoded as poolId → strategy in `strategyForPool()`; all other pools are ignored. No
  factory/discovery events exist, so this mapping is intentionally manual — **and it goes stale
  whenever the router or hook is redeployed**, since a new router is a new `app` identity (new
  `strategyHash`) and a new hook is a new pool (new poolId). After
  [`script/AqueductV2Redeploy.s.sol`](script/AqueductV2Redeploy.s.sol) and
  [`script/AqueductV3DynamicFee.s.sol`](script/AqueductV3DynamicFee.s.sol) (see [Live on Base
  Sepolia](#live-on-base-sepolia) above), the mapping now includes both new Strategy A pools —
  poolId `0x54e7faa821dfc1832bcf0f16aa0e8545c5f142e9a9c6e9962b05f2dec3948b76` (static-fee) and
  poolId `0x7bf07bfabe7eb1773eb3be5a319ddbaa59db133427d56e0508ad6c42958d047a` (dynamic-fee), both →
  strategy hash `0x0581e5d8783c51f4d45d190a41fee043d7859b8998373296acfc618baa0e64e7` — both
  independently confirmed by decoding the real `Initialize` events emitted on `PoolManager` in
  each redeploy's own broadcast transaction, not just computed offline.

### A trimmed Messari DEX-AMM layer — building on a standardized schema

On top of the project's own custom schema, the subgraph also populates a trimmed subset of
[Messari's real DEX-AMM standardized schema](https://github.com/messari/subgraphs/blob/master/schema-dex-amm.graphql)
(`Token`, `LiquidityPool`, `Swap` — same entity and field names) from the same
`PoolManager.Swap` events already being indexed, so the exact query pattern that works against any
real Messari-standardized DEX subgraph also returns real results here:
```graphql
{ liquidityPools { inputTokens { symbol } swaps { tokenIn { symbol } amountIn amountOut } } }
```
USD-denominated fields (`amountInUSD`, `cumulativeVolumeUSD`, etc.) are left at zero and documented
as such rather than faked, since there is no USD price oracle on Base Sepolia. Also exposed as an
MCP tool (`messari_swaps` in [`mcp/server.js`](mcp/server.js)). See
[`subgraph/schema.graphql`](subgraph/schema.graphql) and
[`subgraph/src/mapping.ts`](subgraph/src/mapping.ts) (`ensureMessariToken`, `ensureMessariPool`,
the Messari-shape block in `handlePoolSwap`).

The killer query — one `exposurePositions(where: {maker: ...})` returning the SwapVM *and* Uniswap
v4 view of the same position, with `venues: ["swapvm", "uniswap-v4"]` on Strategies A and F:

```graphql
{
  exposurePositions(where: { maker: "0x5067591c365d7d69d76b725c2d9af7b9437132be" }) {
    strategyHash venues committedAmount makerWalletBalance
    exposureBps maxExposureBps haltExposureBps status isPausedByMaker updatedAt
  }
}
```

The dashboard's `GraphExposurePanel.tsx` runs exactly this (plus an `exposureSnapshots` history
query) straight from the deployed endpoint — current exposure table, cross-venue badges, and an
exposure-history sparkline with zero RPC calls.

The same endpoint is wrapped as an MCP server (`mcp/server.js`, zero dependencies) with three
agent tools — `maker_exposure`, `exposure_history`, `cross_venue_positions` — so Claude/Cursor can
answer "is this maker safe on both venues?" over stdio with no GraphQL hand-written. Run with
`node mcp/server.js` and point any MCP client at it; the Studio query endpoint is public, so no
API key is needed. That is the "compose 2+ Graph products" box checked: custom subgraph +
Subgraph-MCP pattern on top.

### Why Graph? (and the composability diagram)

Without an indexer, every question above is a bespoke off-chain pipeline: track four Aqua events
across N strategies, track two oracle events per maker, watch two v4 pools, join them on
(maker, strategyHash), keep wallet balances fresh, and persist history for charts. That is five
integrations with five failure modes — or **one shared schema**:

```
Aqua events ──┐
              ├─► ExposurePosition (maker, strategy) ──► dashboard / keeper / MCP
Oracle events ┤         ▲
v4 Swaps ─────┘         └── ExposureSnapshot (history)
```

The schema is the API contract: the keeper, the frontend panel, and any future agent all read the
same entities instead of reimplementing the join. Adding Strategy D is zero subgraph changes — ship
it on-chain and the position appears. Adding a third venue is one poolId row, not a new service.
That is the composability story: **the join is written once, in the open, and every consumer
reuses it.** (Deliberately out of scope: a Substreams streaming version — the polling
keeper + indexed snapshots already meet the demo's freshness needs. The MCP layer above was
chosen instead as the cheaper second composed product.)

## Frontend

A Next.js dashboard (`frontend/`) drives everything above from a browser instead of the terminal —
**no local setup required**: it's hosted at
[`aqueduct-protocol.vercel.app`](https://aqueduct-protocol.vercel.app/) and reads
`frontend/public/deployment.json`, which is committed and already points at the real Base Sepolia
deployment above. Just open that link with a wallet (MetaMask or similar) switched to Base Sepolia
(chain id `84532`) — get free testnet ETH from a Base Sepolia faucet first if you don't have any.

To run it locally instead (e.g. to hack on it):

```shell
cd frontend
npm install
npm run dev
```

then open `http://localhost:3000` the same way. The
read-only dashboard data (exposure gauge, keeper panel) uses Base's own public RPC
(`https://sepolia.base.org`) so it works even before a wallet connects; it never uses a personal
Alchemy/Infura key client-side, since that file ships to every visitor's browser. It shows:

- **A live exposure gauge** — polls `ExposureOracle.exposureOf(maker)` every few seconds and
  color-codes the maker's current band (safe / derated / halted).
- **An aggregate-exposure panel** — Scene 1 of the pitch made literal: shows every Aqua strategy
  this maker has *actually* shipped — real Strategy A/B/C, read live via `Aqua.safeBalances`, not
  invented for the UI — the maker's real wallet balance, and the resulting committed/wallet ratio,
  right next to — and explicitly distinguished from — the real gating exposure this deployment's
  `ExposureOracle` currently reports (`AggregateExposurePanel.tsx`). It reads however many
  strategies `deployment.json`'s `strategies` array actually lists (currently three, real, on
  Base Sepolia) and pads any unfilled slots as `— not shipped` rather than faking data, so it
  stays honest if that number ever changes (see `test/MultiStrategyExposure.t.sol` for the
  on-chain proof this panel's numbers generalize to).
- **A "same strategy, same risk, different venue" panel** — the Uniswap track story in one
  screen: the maker address, Aqua strategy hash, and live exposure, feeding into a side-by-side
  SwapVM/Uniswap v4 numeric comparison computed from the shared strategy's live reserves (not just
  a qualitative "both safe" label) — an "EXACT MATCH — BIT-EXACT" badge appears the moment the two
  numbers agree, which is always, because they're the identical computation performed twice
  (`CrossVenueProofPanel.tsx`, backed by `test/CrossVenueConsistency.t.sol`'s on-chain proof real
  swaps on both venues produce bit-exact equal `amountOut`, not just a UI coincidence).
- **Two swap panels**, side by side, backed by the same maker strategy: one calls
  `SwapVM.swap(...)` directly, the other calls Uniswap v4's `PoolSwapTest.swap(...)` through
  `AquaV4Hook`. Both work from a plain connected wallet, no deployed contract required as taker.
- **A Strategy P panel** — swaps through the three-instruction composed position (price adjuster +
  exposure gate), and shows the live Chainlink ETH/USD reading `_oraclePriceAdjuster1D` is actually
  reading right now, not a static number (`SophisticatedPositionPanel.tsx`).
- **A dynamic-fee pool panel** — the second Uniswap v4 capability made visible: shows the
  *predicted* fee (computed client-side from the same live `ExposureOracle` reading the contract
  itself reads) next to the *persisted* on-chain fee (read directly off `PoolManager`'s own storage
  via `extsload`, the same mechanism `StateLibrary.getSlot0` uses), a button that calls the
  permissionless `refreshFee()` for real, and a swap that settles net of the fee
  (`DynamicFeePoolPanel.tsx`).
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
- **A Graph-powered exposure panel** — every number on it comes from the deployed subgraph's
  GraphQL endpoint, zero RPC calls: a per-strategy exposure table (venues, committed amount,
  wallet balance, status), which positions fill on both venues, and an exposure-history sparkline
  from indexed `ExposureSnapshot`s (`GraphExposurePanel.tsx`; see [The Graph
  pipeline](#the-graph-pipeline) above for the schema behind it).
- **A maker emergency-halt panel** — the third security layer from the [threat
  model](#threat-model) above, wired to a real signed transaction from the demo maker's own key
  (the same non-secret, derivable-by-anyone pattern the keeper panel below already uses); live on
  this deployment (`EmergencyPausePanel.tsx`). Falls back to an explicit "not live on this
  deployment" state rather than failing silently if pointed at an older `ExposureOracle` that
  predates this function.
- **A keeper panel** — the real subgraph + keeper (see [The Graph pipeline](#the-graph-pipeline)
  above) can push a live exposure reading, but nothing runs it continuously as a background daemon
  yet, so this panel lets you push a reading yourself on demand and immediately feel every panel
  above react to it, exactly like a real keeper run would.
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
