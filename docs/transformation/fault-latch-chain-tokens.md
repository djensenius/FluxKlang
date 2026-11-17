# FaultLatch chain tokens

| Field | Value |
|---|---|
| Issue | #190 (slice FLP3); roadmap #48, parent #64 |
| Status | Reference model and tests. S1 (`SysExAssembler`) migrated in FLP4, S3 (`DeferredReleaseQueue.retire`) in FLP5, S2 (`FanInHandoff.claimProducer`) in FLP6; S4 not yet. #190 remains open |
| Source baseline | main at `66d15f01` |
| Code | `Shared/Audio/Kernel/Memory/FaultLatch+Chains.swift` |
| Tests | `FluxKlangTests/RealtimeHandoffTests+FaultChains.swift`, `FluxKlangTests/RealtimeHandoffTests+FaultChainsStress.swift` |

## 1. Status and scope

[FLP1](fault-latch-raise-sites.md) lists the four production raise sites (S1 to
S4) and the counters (C), and its section 8 lists what a proof must produce.
[FLP2](fault-latch-platform-callbacks.md) found that the platform documents no
chain bound and no callback-to-callback happens-before (HB) edge for audio
render or CoreMIDI receive. So a caller cannot get the Raise-context contract
(`FaultLatch.swift:123` to `:130`) from the platform.

This slice adds a mechanism that makes the contract hold by construction for
every raise routed through it, without relying on any platform guarantee. It
changes no existing file under `Shared/` (`FaultLatch.swift` stays at 500 lines)
and wires nothing into SysEx, fan-in, retire, ring, admission, AU, MIDI, OSC or
WING. Each site is a later slice (section 7).

## 2. The model

| Type | Role | Where it runs |
|---|---|---|
| `FaultChainAuthority` | Builds and privately owns one `FaultLatch`, its only chain budget and the contended flag. Forwards `pending`, `observe`, `acknowledge`, `unknownScopeFaults` | Created and minted on control |
| `FaultChain` | One logical chain: an `Atomic<UInt64>` slot that holds the chain's id, or 0 while a context holds its token | Minted on control; `take`/`put` on any context |
| `FaultChainToken` | `~Copyable`, explicitly not `Sendable`; carries the authority identity and chain id. Its initializer is `fileprivate` (synthesized from `fileprivate` fields) | Exists only between `take` and `put` |

Hot-path use by one callback:

1. `chain.take()`: one acquiring exchange of the slot with 0. It returns the
   token only if the old value was the chain's id.
2. `authority.raise(&token, scope, kind, frame:)`: refuses a token of another
   authority with `.refused(.notOwner)` and changes nothing. Otherwise it is
   exactly `FaultLatch.raise` (same status, record, count, kind, first frame,
   unknown-scope count).
3. `chain.put(token)`: one releasing store of the id. A token of another chain
   or authority is refused with `.refused(.notOwner)` and consumed.
4. If `take()` returned `nil`, the context must not raise on the counted path. It
   calls `authority.raiseContended()` instead (section 5).

One budget per latch. The latch is a `private let` built inside the authority's
initializer. No API takes an existing `FaultLatch`, and none returns the
authority's latch. So no second minting authority can exist for that latch, and
`FaultLatch.raise` on it is reachable only through `raise(_:_:_:frame:)`. This
needed no change to `FaultLatch.swift`. A stored budget inside `FaultLatch` was
rejected because the file is at its 500-line cap, and because a budget there
would still leave `raise` callable without a token.

Bounded minting. `mintChain()` takes a control-side `Mutex`, checks
`minted < chainBudget`, increments and allocates a `FaultChain`. Nothing ever
decrements `minted`. Dropping a chain or a token returns no unit, and a refusal
is final. Authority identities come from one process-wide
`FanInIdentityAllocator` (reused from `FanInHandoff.swift`), read only in
`init`, after the budget check and latch build, so a refused preparation
consumes none. It issues 1 through `UInt64.max` and then refuses preparation for
good (`.identitiesExhausted`); it never wraps, so no identity is reissued and a
retained token cannot match a later authority, at a reused address or not. An
internal initializer takes another allocator so tests can reach the bound;
production uses only the process allocator, and identities are unique per
allocator.

Batch minting and ownership checks (FLP7a, groundwork for FLP7b's per-lane S4
chains). `mintChains(count:)` is all or nothing: under one lock it checks
`1 <= count <= chainBudget - minted`, then adds `count`, and allocates the
chains (consecutive ids) after the lock; a refusal returns `nil` and spends
nothing. `mintChain()` is `mintChains(count: 1)?.first`. Both are control-side
only (`Mutex`, allocation). `issued(_:)` is `true` only for a chain this
authority minted (exact within one identity allocator; production uses only
the process allocator), and `isObservation(_:)` only for an observation of its latch
(`FaultObservation.isObservation(of:)`), so callers can check ownership without
the latch being exposed.

## 3. Why the Raise-context contract holds

Scope of the argument: every `FaultLatch.raise` on an authority's latch, which
by section 2 means every `raise(_:_:_:frame:)` with an accepted token.

- **K bound over the lifetime, including unknown scopes.** Every such raise
  holds a token, every token belongs to one minted chain, and at most
  `chainBudget <= maximumChainBudget = 2^16` chains are ever minted. Unprepared
  scopes go through the same token path, so `unknownScopeFaults` raises belong
  to the same K. K <= 2^16 < 2^39 for the whole latch, not per scope or per
  generation. Contended fallbacks do not call `FaultLatch.raise` and add no chain.
- **One holder per chain.** Invariant (one-way): the slot holds the id only
  when no token of the chain exists, and at most one token exists. The converse
  does not hold: a dropped token, or one consumed by a refused `put`, leaves
  the slot empty with no token. The invariant holds initially
  (slot = id, no token). `take` makes a token only from the exchange that read
  the id and wrote 0, and the exchange is a read-modify-write, so two takes
  cannot both read the id without a `put` between them. Tokens cannot be copied.
  `put` stores the id only for the chain's own token, which it consumes.
- **Non-reentrancy.** A raise needs `inout` access to the chain's only token,
  and two mechanisms together stop re-entry. Swift's exclusivity rule stops a
  holder re-entering on its own token: statically for locals and `inout`
  parameters, by a runtime trap for globals and class properties. A re-entered
  context that does not hold the token is stopped by the slot: its `take()`
  returns nil, so it falls back to `raiseContended()`, which fails closed. A
  dropped token is never re-created; the chain then stays empty (fail closed).
- **Happens-before between successive raises.** Within one holder, raises are
  sequenced. Between holders: the last raise of holder A is sequenced before A's
  releasing `put` store. The next successful `take` is an acquiring exchange
  that reads the id; the only writes of the id after the previous take are that
  holder's `put`, and the exchange reads the latest value in the slot's
  modification order, so it reads A's store. Release/acquire gives the edge, so
  A's last raise happens before B's first, whatever thread B runs on.
- **Fresh contexts.** A fresh, unsynchronized context cannot start a chain on
  the hot path. It either takes an existing chain (and inherits the HB edge
  above) or falls back. Minting is control-side, and K counts every chain ever
  minted, whether or not it raises.
- **Thread migration.** The token is not `Sendable`. Moving it to another
  thread other than through its slot needs either a region transfer
  (`sending`), whose mechanism (for example task creation) supplies its own HB
  edge, or an unsafe escape (section 6). The slot is the supported path.

Saturation then follows from the existing argument (`FaultLatch.swift:136`):
each chain overshoots a scope's cap at most once, so overshoot is at most
2^16, far inside the 2^39 headroom, and likewise for `unknownScopeFaults`.

K_max = 2^16. Any value below 2^39 satisfies the contract. 2^16 keeps a margin
of 2^23 below the headroom. It bounds the memory a runaway minting loop can take
(one small object per chain), and leaves room for chains per site × callback
instance × restart generation for a session. A site that would exceed its
budget must fail closed (section 5), never recycle.

## 4. RT properties

- `take`: one atomic exchange. `put`: one comparison of two words and one atomic
  store. `raise`: one comparison, then `FaultLatch.raise` (one load, at most one
  add and one 128-bit store). `raiseContended`: one atomic store. No locks, no
  allocation, no retry loop, no blocking at the source level.
- `isLatched`: `FaultLatch.isLatched` (one acquiring load), then one acquiring
  load of the flag (section 5 gives the order).
- `issued`, `isObservation`: one identity comparison; no locks, no allocation.
- Minting (`mintChain`, `mintChains`), `pending`, `observe` and `acknowledge`
  take a `Mutex` and stay on control. Minting also allocates.
- Not checked here: `@_noAllocation`/`@_noLocks` on these paths, ARC
  retain/release on the class references at `-Onone`, and target lowering of
  the atomics. As for `FaultLatch` (Progress), they stay unqualified for #64.

## 5. Contended fallback

`raiseContended()` stores `true` into a sticky flag with release ordering. It
cannot overflow, repeating it changes nothing, and it never touches counted
records or `unknownScopeFaults`. It carries no scope, kind, frame or count: the
signal kept is "some fault happened on this latch while its chain was held".

| Observer | Effect of the flag |
|---|---|
| `authority.hasContendedFault` | `true` from the first fallback on, forever |
| `authority.isLatched(scope)` | `true` for every scope, prepared or not, once the flag is set |
| `authority.pending`, `authority.observe` | Counted records only; they never show the flag. Control must check `hasContendedFault` too |
| `authority.acknowledge` | Re-arms counted records only and never clears the flag; `isLatched` stays `true` |
| `authority.unknownScopeFaults` | Unaffected |

Read order in `isLatched`: the counted latch first, the flag last. With the flag
first, a reader could see the flag clear, then another context sets it and
acknowledges the counted record, then the reader sees the re-armed count and
reports a scope faulted throughout as clear. Counted first fixes that: the
counted load is acquiring and the acknowledge compare-exchange is
acquire-release, so a counted read that sees the re-arm (or a later raise's
read-modify-write in its release sequence) synchronizes with it. A flag store
sequenced before that acknowledge then happens before the flag load, which is
acquiring and cannot move above the counted load, so it reads `true`. This
covers a flag set by the acknowledging context, or by one that happens before
it; a flag set concurrently with the acknowledge by an unrelated context is a
fault the reader may linearize after its call.

Only replacing the authority (and its latch) while quiescent clears the flag, as
for a saturated scope. That keeps every existing fail-closed rule: nothing that
was latched becomes unlatched, and the fallback can only add latched state.
Callers must read faults through the authority. A component that keeps reading
a bare `FaultLatch` would not see the flag; no such component can hold the
authority's latch, because it is never handed out.

Budget exhaustion uses the same rule: a context that cannot get a chain (no
mint left, or its chain's token was lost) has no counted path and must fall back.

## 6. What this does not prove

- No real caller is identified. S1, S3 and S2 are migrated (FLP4, FLP5 and FLP6,
  section 7) but still have no real caller (#81; a render caller; the producers
  that claim fan-in lanes); S4 still calls `FaultLatch.raise` directly on the
  latch it is given, outside this model.
- `FaultLatch.raise` is still callable on any latch not built by an authority.
  Nothing yet stops new code from doing that; a lint tripwire is a follow-up.
- Unsafe escapes of a token (`nonisolated(unsafe)`, `@unchecked Sendable`
  boxes, unsafe pointers) and builds that turn off exclusivity checking are out
  of the model.
- The contended fallback loses scope, kind, frame and count, and the flag is not
  acknowledgeable. An acknowledgeable variant would need its own epoch protocol.
- C (`FanInRefusalCounter` users) are not `raise` calls and get nothing here.
  The same pattern could own a counter's chains, but that is not built.
- Restart counting per site (how many chains each callback generation mints) is
  the site's job; this slice only bounds the total.
- The tests exercise the reference model on the test host. They are not
  real-time certification and say nothing about a real callback.

## 7. FLP1 section 8 and the migration plan

Each site migrates in its own slice. The common steps: the site receives a
`FaultChainAuthority` and the `FaultChain`(s) minted for it at preparation;
each call takes the token at entry and puts it back before return; a failed take
uses `raiseContended()` and must not raise on the counted path; observers of the
site's scopes read `authority.isLatched` and `hasContendedFault`.

Liveness trap: a token that is not put back on some return path (early return,
error, refusal branch) empties its chain forever, and every later raise on that
chain latches through `raiseContended()`. That fails closed but loses all
counted detail from then on. Each site-migration slice (S1 to S4, and C if it
adopts the model) must therefore include a test that every return path puts the
token back.

| FLP1 §8 item | This slice | Still needed (UNPROVEN until then) |
|---|---|---|
| S1 `SysExAssembler` | **Migrated (FLP4)**: `init` takes a `FaultChainAuthority` and mints one chain per assembler, last, after every pure check and the output claim (`.chainBudgetExhausted`); `accept` takes the token after its pure guards, holds it for the whole call (two raises in one call stay on one token) and puts it back on every path; a failed take changes no assembler state, calls `raiseContended()`, counts `contendedChunkCount` and returns `.refused(.notOwner)`. K <= `chainBudget` per authority by construction; per-assembler happens-before edge via the slot. Tests: `RealtimeHandoffTests+SysExChains.swift`, `SysExChainingStress` | Real caller still #81. Successive calling contexts share the assembler's one chain, ordered by its slot, so no per-generation minting is needed. A SysEx authority cannot share the kernel cycle's latch (the authority never hands its latch out), so SysEx faults live on their own authority |
| S2 `claimProducer` | **Migrated (FLP6)**: `FanInHandoff.init` takes a separate claim `FaultChainAuthority` (`claimFaults`) for `producerSlotsScope` and mints one chain per handoff after every other check that can throw, before the identity is reserved (`.chainBudgetExhausted`). The lanes keep `faults` for S4. The claim authority is separate because its sticky contended fault latches every scope and would latch `criticalScope` on `faults`. Unlike the common steps above, only a refused claim takes the token: it raises `.producerSlotsExhausted` once and puts the token back. A successful claim never touches it. A failed take (refused claims overlapping, legal because any thread may claim) calls `raiseContended()` and counts `contendedClaimCount`. The claim still returns `nil` and still counts in `refusedClaimCount`. K <= `chainBudget` per claim authority by construction; per-handoff happens-before edge between refused claims via the slot. Tests: `RealtimeHandoffTests+FanInClaimChains.swift`, `FanInClaimChainingStress` | Real callers of `claimProducer`. Every producer context shares the handoff's one claim chain, so no per-context minting is needed; the refusal counter's own bound (C) is unchanged |
| S3 `retire` via `beginCycle` | **Migrated (FLP5)**: `DeferredReleaseQueue.init` takes a `FaultChainAuthority` and mints one chain per queue, last, after the policy checks and the ring (`.chainBudgetExhausted`); `retire` takes the token first, holds it across the push and the `.retireBacklog` raise and puts it back on every path; a failed take pushes nothing, calls `raiseContended()`, counts `contendedRetireCount` and returns `.refused(.notOwner)` with the +1 left with the caller. `RetiringExchange` and `PreparedPlanSlot` treat it as a refused retire (stall, retry next cycle; fail closed at the cost of a stall). K <= `chainBudget` per authority by construction; per-queue happens-before edge via the slot. Tests: `RealtimeHandoffTests+RetireChains.swift`, `RetireChainingStress` | A real render caller (FLP2: one chain per render block and generation). Every exchange or slot sharing a queue shares its one chain, so the token is held per `retire`, not per cycle |
| S4 `ReservedCapacityRing.refuse` | Mechanism only | One chain per lane, taken by each lane holder, so the slot's edge orders successive holders' raises; whether that can replace the "stop pushing before release" caller contract is for that slice to show |
| Global K over one latch, incl. unknown scopes | **Discharged by construction for raises through one authority**: K <= `chainBudget` <= 2^16 | Holds for the app only once every raiser on that latch goes through the authority, and each site's chains fit its budget |
| C counters | Not discharged | A bound per counter lifetime, through a similar authority or a site proof |
| A real caller per item | Not discharged | Each site slice, with FLP2's platform evidence |
| A check that fails if the bound or edge breaks | Reference model: tests plus mutation checks (section 8) | The same on each real caller |

## 8. Tests

Nested suites `FaultChaining` and `FaultChainingStress` under the existing root
`RealtimeHandoffTests` (no new root suite). They cover: budget range at
preparation; mint refusal at the budget, final even after tokens and chains are
dropped; one budget per authority; foreign tokens refused by `raise` and `put`
with no side effect; authority identities stop at `UInt64.max` and refuse
preparation for good without wrapping, and a refused preparation consumes no
identity (seeded allocators); take/put round trip and an empty slot while held; raise
parity with a plain `FaultLatch` (status, records, `unknownScopeFaults`,
observe and acknowledge); the contended flag's semantics (section 5); and a
bounded `Thread` stress where every attempt is either one counted raise or one
fallback, holders never overlap, and a plain counter touched only by token
holders matches the counted total. The kernel mirror's TSan filter
(`Stress`) includes the stress test.

FLP6 adds `FanInClaimChaining` and `FanInClaimChainingStress`
(`RealtimeHandoffTests+FanInClaimChains.swift`). They cover:
- one claim chain minted per handoff;
- a spent claim budget refuses `init` without taking an identity;
- a contended refusal returns `nil`, counts as refused and contended, and latches
  only the contended fault;
- successful claims never take the token;
- every refusal puts the token back;
- record and acknowledge parity with a plain `FaultLatch`, including an unprepared
  scope;
- a `Thread` stress of overlapping refused claims where counted plus contended equals
  refused.

FLP7a adds, in `FaultChaining` and `FaultChainingStress`: `batchMintIsAllOrNothing`,
`batchMintRejectsNonPositiveCount`, `batchMintIdsAreConsecutiveAndOwned`,
`issuedRejectsForeignChain`, `isObservationRejectsTwinAuthority`, and the stress
test `concurrentBatchMintsNeverOvershootBudget` (racing batch mints never
overshoot the budget, and the grants are exactly ids `1...mintedChains`).
`ReservedRingValidation.validateRefusesExactlyWhatInitRefuses` pins
`ReservedCapacityRing.validate(_:)`, the ring init's pure policy checks that
FLP7b can run before minting, to the init's refusals.
