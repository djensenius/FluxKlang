# FaultLatch raise sites and the caller bound each needs

| Field | Value |
|---|---|
| Issue | #190 (slice FLP1, tracked in #523); roadmap #48, parent #64 |
| Status | Inventory only. Nothing in this document is a proof. #190 remains open |
| Source baseline | main at `ad8cc8a9` |
| Scope | Every `FaultLatch.raise` call in `Shared/`, and the bounded counters under the same kind of contract |

## 1. Status and scope

This document is documentation only. It changes no code and weakens no check. It
lists each production call to `FaultLatch.raise`, what one logical chain is for
that caller, and what the code does or does not establish about the lifetime
bound and the sequencing edge that `FaultLatch`'s own "Raise-context contract"
needs (`Shared/Audio/Kernel/Memory/FaultLatch.swift:123`). Every bound and every
edge is marked **UNPROVEN** unless a cited line (code, doc comment or test)
establishes it. A doc comment that states a requirement establishes the
requirement, not that any caller meets it.

No hosted run, audio, MIDI, OSC, WING, service or hardware was used. Statements
below come from reading the source at the baseline and from `grep`. This
document makes no claim about how the platform's audio, MIDI or network APIs
call back (cardinality, threads or serialization); section 7 lists what would
have to be gathered from authoritative sources.

Citations use `Path.swift:line` against the baseline. Source is not pasted.

## 2. The contract being inventoried

In my own words, from `FaultLatch.swift:123` (Raise-context contract), `:136`
(Saturation), `:132` (Test seams) and `:113` (Progress):

- Over the latch's whole lifetime, every `raise` call, on any scope, prepared or
  not, must belong to one global set of K < 2^39 logical chains. It is one
  condition for the whole latch, not one per scope or per generation.
- Within a chain, calls are non-reentrant, and each completed `raise` happens
  before the chain's next `raise` begins (its cap check).
- A chain may move between threads only through a real happens-before handoff
  (release/acquire, a lock, a join). A call from an unsynchronized or re-entered
  context starts a new chain.
- The reference model neither checks nor proves this. Callers that have not
  proved it are unsupported, and app hot-path integration must prove it or use a
  different design. The doc comment says the proof is open in #190.
- This is a functional precondition, separate from Progress (`:113`), which
  concerns lock-free and retry-free source code and is itself unqualified for
  target lowering.

Why the bound matters (`FaultLatch.swift:136`): a raise that passes its cap check
may still add after the count has saturated, so each chain can overshoot the cap
at most once. Cumulative overshoot is bounded by the number of chains, not by the
number of raisers at one moment. If chains are unbounded, stale admissions can
carry into the generation bits and corrupt the scope.

`unknownScopeFaults` (`FaultLatch.swift:405`, `:409`) is an aggregate counter
for `raise` calls on scopes that were never prepared (`:235` to `:240`). It
saturates at `unknownCap` and never resets: nothing clears it, apart from the
test seam `seedUnknownScopeFaultsForTesting` (`:441`). Its lifetime bound
is the same global K (`:405` to `:408`), and the doc comment says "A per-scope or
per-generation bound alone would not imply this lifetime bound". The counter is
per latch, not per scope, so it accumulates over every scope a caller got wrong,
for every component sharing the latch, for the latch's whole life. A per-scope
or per-generation argument therefore cannot cover it.

## 3. Production `raise` sites

`grep -rn '\.raise(' Shared` finds five lines: four calls to `FaultLatch.raise`,
each through `faultsRef._withUnsafeGuaranteedRef`, and one doc-comment mention at
`ReservedCapacityRing.swift:10`. No other production caller was found.
(`SysExAssembler` has a private method named `raise`; its body is the one call at
`SysExAssembler.swift:339`.)

| # | Call | Component |
|---|---|---|
| S1 | `Shared/Audio/Kernel/Events/SysExAssembler.swift:339` | `SysExAssembler.raise`, reached from `discard` and `extend` |
| S2 | `Shared/Audio/Kernel/Memory/FanInHandoff.swift:365` | `FanInHandoff.claimProducer` |
| S3 | `Shared/Audio/Kernel/Memory/DeferredRelease.swift:122` | `DeferredReleaseQueue.retire` |
| S4 | `Shared/Audio/Kernel/Memory/ReservedCapacityRing.swift:238` | `ReservedCapacityRing.refuse` |

Common to all four: none of them checks that its scope is prepared. The scope is
a constructor argument, the doc comment says it "should" be prepared in the
latch, and an unprepared scope lands in `unknownScopeFaults`
(`SysExAssembler.swift:39` to `:41`, `FanInHandoff.swift:288` to `:290`,
`DeferredRelease.swift:76` to `:78`, `ReservedCapacityRing.swift:103` to `:104`).
Who prepares the scopes is the code that builds the `FaultLatch` and its
components; no production code does (section 6), so "who prepares it" is not
established beyond the doc comments naming "the caller".

For every site the lifetime bound and the sequencing edge are **UNPROVEN**, and
no code or test establishes either for a real caller. The only test of a
lifetime chain bound is a reduced-width model of `FanInRefusalCounter`, not of any
`raise` caller (section 4). The cap-race tests
(`RealtimeHandoffTests+Faults.swift:448`, `RealtimeHandoffTests+FaultsStress.swift:171`)
cover only a two-raiser overshoot of `countCap` on one scope, which is not a
lifetime bound. The "evidence a proof needs" column says what would
change that.

### 3.1 S1: `SysExAssembler` (`SysExAssembler.swift:339`)

| Item | Finding |
|---|---|
| Type and method | `SysExAssembler.raise(_:_:_:)` (`:337`), called by `discard` (`:331` to `:334`) and directly by `extend` (`:270`) |
| Call paths | Abort on a new start or complete over an open message (`:258`); end or continue while idle (`:270`); overflow (`:299`, `:300`); pool or ring refusal in `deliver` (`:313`, `:321`) |
| Scope | `FaultScope(handoff: scopeBase, target: source)` (`:338`); `scopeBase` is an init argument, `source` is checked below `sources` first (`:179`) |
| Who prepares the scope | "the caller must prepare those scopes in `faults`" (`:39` to `:41`); no production caller exists |
| Kinds | `.sysexAborted` (`:258`, `:270`), `.sysexOverflow` (`:300`, `:313`, `:321`) |
| Calling role | Producer side: `accept` "must be called from exactly one context at a time (the MIDI receive path; #81 must verify or serialise it" (`:28` to `:30`). Which thread that is: not established |
| One chain is | The serialized sequence of `accept` calls, if the "one context at a time" requirement holds. One `accept` can raise more than once in sequence (abort then overflow, `:258` then `:300`), still within one call |
| Chains over the latch's lifetime | **none** established by code. `:28` to `:30` requires one context at a time but does not bound how many contexts take that role over the latch's life |
| Edge, completed raise to next admission | **none** established. The doc requires one context at a time; it does not name a happens-before handoff between successive contexts |
| Can the scope be unprepared | Yes: not checked (`:39` to `:41`). Its raises then add to `unknownScopeFaults` |
| Verdict | **UNPROVEN** |
| Evidence a proof needs | The real MIDI receive path that calls `accept` (#81), shown to be one chain or a bounded set; the handoff, if the calling context ever changes; the scope table prepared in the latch the assembler uses |

### 3.2 S2: `FanInHandoff.claimProducer` (`FanInHandoff.swift:365`)

| Item | Finding |
|---|---|
| Type and method | `FanInHandoff.claimProducer(frame:)` (`:350`), after counting a refusal at `:363` |
| Scope | `producerSlotsScope`, an init argument (`:291`), which must differ from `criticalScope` (`:166` to `:169`, init guard) |
| Who prepares the scope | "both of which the caller prepares in `faults`" (`:166`); no production caller exists |
| Kind | `.producerSlotsExhausted` (`:365`), only when no lane is claimable (`:178`) |
| Calling role | "Any producer context" (`:348`); "any thread may call `claimProducer`" (`:196`) |
| One chain is | One non-reentrant, happens-before ordered sequence of `claimProducer` calls (`:194` to `:196`). Each thread, or context not ordered with another, that can call it is a separate chain |
| Chains over the latch's lifetime | **none**. `:130` to `:131` says that nothing else bounds K: not the lane count, not the number of threads at one moment, not `FaultLatch` |
| Edge, completed raise to next admission | **none** established. The raise is the last step before `claimProducer` returns `nil`; ordering to the next call is the caller's, and nothing states it |
| Can the scope be unprepared | Yes: not checked (`:288` to `:290`) |
| Verdict | **UNPROVEN** |
| Evidence a proof needs | Every real caller of `claimProducer`, with a finite count of chains over the latch's life (including threads that come and go, if any), and the ordering between a refused claim and that chain's next claim |

### 3.3 S3: `DeferredReleaseQueue.retire` (`DeferredRelease.swift:122`)

| Item | Finding |
|---|---|
| Type and method | `DeferredReleaseQueue.retire(_:frame:)` (`:117`), on a refused ring push (`:120`) |
| Scope | `scope`, an init argument "not checked against `faults`" (`:77` to `:78`) |
| Who prepares the scope | Not established; no production caller exists |
| Kind | `.retireBacklog` (`:122`), an unreserved retire past capacity (`:33` to `:34`; method doc `:113` to `:114`) |
| Calling role | "one render thread may call `retire`" (`:44`); "Every user of a shared queue ... must use that same render/control thread pair. This is documented, not enforced" (`:45` to `:47`). Reached through `RetiringExchange` (`RetiringExchange.swift:184`) and `PreparedPlanSlot.beginCycle` (`PreparedPlanSlot.swift:82` to `:85`, which names that thread "a raise chain") |
| One chain is | The render thread's `retire` calls on this queue, if one render thread is the only caller. Whether render is one thread, or one chain, for the real engine: not established |
| Chains over the latch's lifetime | **none** established by code. `:44` to `:47` is a role requirement. `PreparedPlanSlot.swift:84` to `:85` says a latch shared with other components must count every chain that can raise on it, and that "That proof is open in #190" |
| Edge, completed raise to next admission | **none** established. `retire` returns the status after raising |
| Can the scope be unprepared | Yes (`:77` to `:78`) |
| Verdict | **UNPROVEN** |
| Evidence a proof needs | The real render caller of `beginCycle` or `retire`, its serialization, and every other component whose raises share this latch |

### 3.4 S4: `ReservedCapacityRing.refuse` (`ReservedCapacityRing.swift:238`)

| Item | Finding |
|---|---|
| Type and method | `ReservedCapacityRing.refuse` (`:229`), from `tryPush` (`:159`) when a critical event meets full capacity |
| Scope | `scope`, an init argument "should be prepared in `faults`" (`:103` to `:104`). Inside `FanInHandoff` every lane gets the handoff's `criticalScope` (`FanInHandoff.swift:314` to `:315`), so all lanes of one handoff raise on one scope |
| Who prepares the scope | Not established; no production caller exists |
| Kind | `.criticalExhausted` (`:238`) |
| Calling role | "Producer only" (`:156`, `:228`); inside a handoff, "The token's producer only" (`FanInHandoff.swift:388`). Which thread: not established |
| One chain is | One producer's sequence of critical `tryPush` calls on its lane. Under `FanInHandoff`, each lane has its own producer, so the chain count follows the producer contexts over the latch's life. A stale or foreign token holder is refused by the token check before it reaches the ring (`FanInHandoff.swift:395` to `:398`), so it adds no S4 chain |
| Chains over the latch's lifetime | **none** established by code. The warning at `FanInHandoff.swift:195` to `:196` is about the refusal counters' callers; it does not cover these valid-token pushes. Candidate bound for one fixed handoff: one chain per lane (the handoff's lane count), because the lane handover (next row) lets successive holders of a lane continue one chain. It holds only if every holder stops pushing before it releases its token and no copy of the token is used concurrently (`FanInHandoff.swift:230` to `:233`). The code states that as a caller contract: a push that starts after the release is refused by the token check (`:395` to `:398`), but a push already past that check, or a concurrent copy of the token, is not stopped. A bound across several handoffs, or other raise sites, on one latch is not established |
| Edge, completed raise to next admission | Within one token: **none** established. The `refuse` path returns `.refused(.criticalExhausted)` after the raise; the order to the producer's next push is the producer's own. Between successive holders of one lane the code has a handover edge (`FanInHandoff.swift:207` to `:213`): A's pushes happen before its releasing compare-exchange `claimed` to `retiring`, the consumer's acquiring load sees `retiring` before it pops, and its releasing store of `free` is read by B's acquiring claim, so A's producer-side writes happen before B's first push. That orders A's last raise before B's first push only if A stopped pushing before it released the token (`:230` to `:233`). A push that starts after the release is refused (`:395` to `:398`), but a push already past the token check is not stopped |
| Can the scope be unprepared | Yes (`:103` to `:104`, `:236`) |
| Verdict | **UNPROVEN** |
| Evidence a proof needs | The set of producers that can ever hold a lane, over the latch's life, with ordering between a token's successive pushes and between successive holders of one lane |

## 4. Bounded counters under the same contract, not `raise` calls

`FanInRefusalCounter` (`FanInHandoff.swift:133`) has a documented caller contract
of the same shape (`:123` to `:131`): at most K < 2^39 logical chains over the
counter's lifetime, non-reentrant, each completed `bump` before the chain's next,
migration only through happens-before. Its `bump` (`:148`) is not a `raise`.
`FaultLatch` does not report it, and the doc comment says so: "The invalid-token
paths raise no `FaultLatch` fault, so the latch neither limits nor reports them;
a failed claim does raise `.producerSlotsExhausted`, but the count's bound does
not rely on it" (`FanInHandoff.swift:197` to `:199`).

`FanInHandoff` owns two:

| Counter | Bumped at | Triggered by |
|---|---|---|
| `refusedClaims` (`:284`) | `:363` | `claimProducer` finding no lane. The same path then raises S2, so one chain is the same sequence of calls, but the counter's bound is its own argument |
| `refusedNotOwner` (`:283`) | `:382`, `:397` | `releaseProducer` and `tryPush` refusals for a token that does not own its lane. No fault is raised on these paths (`:369` to `:371`, `:392`). Any thread holding any token, stale or foreign, can reach them (`:196`) |

Both are **UNPROVEN** for the same reasons as section 3: the chain bound for real
callers is open (`:132` says #190 must prove it before any hot use). The only
test evidence found is a reduced-width model and its negative control
(`FluxKlangTests/RealtimeHandoffTests+FanInIdentity.swift:444`, `:461`). Those
exercise the algorithm over narrow counters with a chosen number of chains. They
do not show that any real caller's chains are bounded.

Other users found by grep for `FanInRefusalCounter` in `Shared/`:

- `KernelAdmissionRefusals` (`Shared/Audio/Kernel/Events/ProducerAdmission.swift:56`):
  one counter per lane and kind (`:68`, allocated at `:76`) and `foreign` (`:69`).
  Its doc says each counter keeps `FanInRefusalCounter`'s caller contract (`:51` to
  `:55`). `record` (`:85`) bumps at `:93` and `:94`. It is
  producer-side, so the chain bound for its callers is as open as for the
  handoff's counters. The design brief did not list it; it is a counter under
  the same contract and is therefore inventoried here.

Other doc comments in `Shared/` that mention the contract (grep for
`logical chains` and `chain bound`):

- `FanInHandoff.swift:132`, `:195`, `:199`, `:233` (above);
- `FaultLatch.swift:124` (the contract itself);
- `Shared/Audio/Kernel/Processors/OfflineAudioRoutingProcessor.swift:5` to `:7`:
  "No publication, retirement, FaultLatch or engine ACK is wired. Actual hot
  integration still requires #190's K < 2^39 lifetime/HB, nonreentrant logical
  chains, including separate M5 refusal counters."

`ReservedCapacityRing`'s own refusal counters (`refusedGeneral`, `refusedCritical`,
`ReservedCapacityRing.swift:95` to `:96`) are not `FanInRefusalCounter`s: they are
single-writer stores (`bump`, `:250`), under the ring's producer-only role, and are not part of
the K contract. They are mentioned only so the inventory does not suggest a third
counter family under it.

## 5. Paths the issue names that have no `raise` site

For each, what a later change would have to prove if it added a raise: the
global K bound for the new raiser (its chains over the latch's life), and the
sequencing edge between a completed raise and that chain's next admission.

| Path | Why it has no `raise` today | Source |
|---|---|---|
| Kernel-cycle recovery | The cycle reads the latch (`isLatched`) and acknowledges (`acknowledge`); it observes and acknowledges, and its comments say it adds no raise site | `KernelCycle.swift:331` (`isLatched`), `:372` (`acknowledge` inside `acknowledgeCritical`), `:179` ("the cycle adds no `FaultLatch.raise` site"); `KernelAckRequests.swift:53` to `:57` (control observes, then requests; render reads `isLatched`) |
| Stale-clock reporting | Reported in `KernelCycleResult.resync` and telemetry, not on the latch. `FaultKind.staleClock` exists, but is not raised | `KernelCycle.swift:178` to `:179`; `KernelCycleTelemetry.swift:8` to `:10` |
| Invalid-token paths in `FanInHandoff` | Refused with `.refused(.notOwner)` and counted; "no fault is raised" | `FanInHandoff.swift:369` to `:371`, `:392`, `:197` to `:199` |
| Invalid or unknown scope | `raise` itself returns `.refused(.slotOutOfRange)` and counts in `unknownScopeFaults`; this is a result of S1 to S4, not a separate caller | `FaultLatch.swift:235` to `:240` |
| `PreparedPlanSlot` and `RetiringExchange` | They reach `raise` only through `DeferredReleaseQueue.retire` (S3) | `PreparedPlanSlot.swift:82` to `:85`; `RetiringExchange.swift:75`, `:184`, and the `beginCycle` doc at `:143` |

Notes:

- `KernelCycle` reads one latch scope (`events.criticalScope`) and acknowledges
  through a ticket; whether the cycle's reads and the raisers' writes are ordered
  is the subject of the happens-before argument at `KernelAckRequests.swift:52`
  to `:65`, whose "formal model-check" is tracked in #190 (`:52`;
  `KernelCycle.swift:165`). That argument orders an acknowledgement after a
  raise; it is not a bound on raise chains, and this document does not rely on it.
- `KernelCycle.swift:173` to `:174` records a residual for #190: `FaultLatch.acknowledge`
  is a shared API and is not type-restricted for critical scopes. That is an
  acknowledge-side obligation, not a raise-chain one, and is outside this
  inventory.

## 6. Unknown-scope aggregate

What increments `unknownScopeFaults`: a `raise` on a scope that is not in the
latch's prepared table, in the `guard let index` branch (`FaultLatch.swift:235` to
`:240`), by one relaxed add while the value is below `unknownCap`. Its callers
are S1 to S4.

Which constructors take a scope "that should be prepared":

- `SysExAssembler.init(... faults:scopeBase:)` (`SysExAssembler.swift:136`); the
  scopes are `(scopeBase, source)` for each source (`:39` to `:41`).
- `FanInHandoff.init(... faults:criticalScope:producerSlotsScope:)`
  (`FanInHandoff.swift:291`; doc `:288` to `:290`).
- `DeferredReleaseQueue.init(policy:faults:scope:)` (`DeferredRelease.swift:79`;
  doc `:76` to `:78`: not checked against `faults`).
- `ReservedCapacityRing.init(policy:faults:scope:)` (`ReservedCapacityRing.swift:105`
  and `:111`; doc `:103` to `:104`).

What happens when the scope is not prepared: the raise is refused with
`.refused(.slotOutOfRange)` (the return value is discarded at every site,
`_ = faultsRef...`), nothing latches, and the count goes to the aggregate
(`FaultLatch.swift:230` to `:240`). A critical fault that was meant to latch is
therefore not latched. `ReservedCapacityRing.swift:236` notes that this stays
"visible through `unknownScopeFaults`"; nothing reads that counter in production
(`grep -rn unknownScopeFaults Shared` finds only its definition and these doc
comments).

The obligation: the global K bound covers every raiser of the latch. Every site
in section 3 that shares one latch counts toward the same K, along with every
chain that raises on an unprepared scope. The latch holds one bound for all of
them. A proof for one site does not cover the others.

Which sites share a latch in the code today: no production code constructs a
`FaultLatch`. `grep -rn 'FaultLatch(' Shared FluxKlang FluxKlangMac` finds no
call; the constructor calls are in tests (for example
`FluxKlangTests/RealtimeHandoffTests+Faults.swift:21`, `:56`, `:78`). So no site
shares a latch in production code today; the question is open for any later
wiring. What the types allow: `FanInHandoff` hands one latch to every lane's
`ReservedCapacityRing` (`FanInHandoff.swift:314`), so S2 and S4 share it inside
one handoff; `DeferredReleaseQueue` may be shared by several exchanges
(`DeferredRelease.swift:45`); and `KernelCycleParts.faults` is one latch
(`KernelCycleTelemetry.swift:130`).

## 7. Callers that do not exist yet

Which of these production code constructs or feeds today:

| Caller | Present in production code? | Source |
|---|---|---|
| Audio-unit or engine render callback (`AURenderBlock`, `AUAudioUnit`, `AVAudioEngine`) | None found. `grep -rlE 'AudioUnit\|AVAudio\|CoreAudio\|AURender\|MIDIEventList\|MIDIReceive\|MIDIInputPort' Shared FluxKlang FluxKlangMac` lists four files (`Shared/MIDI/CoreMIDIInput.swift`, `Shared/Permissions/PermissionProbe.swift`, `Shared/Rig/Identity/RigIdentityMatcher.swift`, `Shared/Diagnostics/Snapshot/NeutralSnapshot+Routes.swift`); none references the kernel types. I did not read the last three beyond that grep |
| CoreMIDI input | `Shared/MIDI/CoreMIDIInput.swift:50` creates an input port with a block. The block extracts control changes and hops to the main actor (`:54` to `:58`). It does not feed `SysExAssembler`, `FanInHandoff` or any kernel type |
| OSC receive | `Shared/OSC/` is a codec, scheduling and protocol layer. No file under `Shared/OSC`, `Shared/WING`, `Shared/MIDI` or `Shared/Assistant` references `FaultLatch`, `FanInHandoff`, `SysExAssembler`, `KernelCycle` or `DeferredReleaseQueue` (grep) |
| WING | `Shared/WING/WingTransport.swift` matched a socket pattern. It does not reference the kernel types (same grep) |

Callback cardinality, thread stability and serialization for these APIs have NOT
been established from authoritative evidence in this document. Nothing here
asserts what Apple documents. The evidence to gather is authoritative: platform
documentation or an explicit platform contract, cited by source, and the caller
and lifecycle proofs built on it. A runtime test on the target is supplemental
only. It can look for a counterexample, but a finite run is not evidence of
serialization, of thread stability or of a chain bound. For each API:

1. Whether one `AURenderBlock` (or the engine's render callback) can be called
   concurrently with itself, and whether successive calls can come from different
   threads; whether the render thread can change across a stop and start, a
   sample-rate or format change, or a render-resource reallocation.
2. For CoreMIDI: whether one input port's receive block can be called
   concurrently with itself, whether it runs on one thread for the port's life,
   and what happens across `MIDIPortDisconnectSource`, a source change or a
   client notification. Also whether a MIDI event list for SysEx7 reaches the
   single "MIDI receive path" that `SysExAssembler.swift:28` to `:30` assumes.
3. For OSC and WING network receive: the queue or thread on which a connection's
   handler runs, whether handlers for one connection are serialized, and the
   effect of reconnection on that.
4. For each: how a context that is handed off between threads gets a real
   happens-before edge to the next call (queue, lock, join, atomic pair) rather
   than relying on timing.
5. A finite, countable bound on the number of distinct chains (threads or
   unsynchronized contexts) that can raise on one latch over its whole life,
   with the counting rule for restarts.

Slice FLP2 records the authoritative platform evidence for questions 1 to 5 in
[`fault-latch-platform-callbacks.md`](fault-latch-platform-callbacks.md). It
establishes no chain bound or ordering edge for any caller.

Until this is gathered, none of these callers is assumed to be one chain, or to
be serialized.

## 8. What a proof must produce

Unchecked items for #190, by site (S1 to S4, section 3; C = the counters in
section 4):

- [ ] S1: a finite bound on contexts that call `SysExAssembler.accept` over the
  latch's life, and the ordering between one context's completed raise and its
  next `accept`.
- [ ] S2: a finite bound on contexts that call `claimProducer`, and ordering
  from a refused claim's raise to that chain's next claim.
- [ ] S3: the render caller of `DeferredReleaseQueue.retire` (via
  `RetiringExchange` and `PreparedPlanSlot.beginCycle`) shown to be one chain or
  a bounded set, and its ordering.
- [ ] S4: the set of producers that can hold a lane over the latch's life,
  their pushes ordered, and a hand-over ordering for successive holders of a lane
  (the code's edge at `FanInHandoff.swift:207` to `:213` holds only if each holder
  stops pushing before it releases its token).
- [ ] Global: the sum over every raiser that shares one latch, including raisers
  on unprepared scopes (`unknownScopeFaults`), is below 2^39.
- [ ] C: the same bound for each `FanInRefusalCounter` user (`refusedClaims`,
  `refusedNotOwner`, `KernelAdmissionRefusals` counters), over each counter's
  own lifetime.
- [ ] A real caller for each of the above, identified from authoritative
  evidence (section 7), not assumed.
- [ ] A check, test or model that fails if the bound or an edge is broken, on the
  real caller, not only a reduced-width model. It supplements the proofs above and
  never replaces them.

The rule: callers that have not proved the contract stay out of hot-path
integration. If the bound cannot be established for a real caller, the counter or
record algorithm must be revised and revalidated. It must not be weakened (for
example by dropping a cap check, widening a bound without argument, or treating
the doc comment as the proof), and #64's acceptance is not waived.
