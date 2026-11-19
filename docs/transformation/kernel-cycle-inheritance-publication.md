# Kernel cycle inheritance publication contract (#843)

Part of #715 (E5d review prerequisite), #64 and roadmap #48.
**Independently reviewed contract, with P1a/P1b implementation status below.** This records the ratified
compatibility direction and exact remaining proof obligations, not implemented
staging, overlap, claim transfer or reclamation machinery. #715, #64, #190,
#191 and #48 remain open. Source baseline: `80313d383a9e58ba9a35c32aa28e0701c31732de`.

## 1. Implemented flow and actual consumer

1. [`KernelCycle.prepare`][prepare] checks shape, wiring and ownership, including
   the shared admission-refusal table over a retired ownership. It captures the
   claim state without claiming. [`KernelCycleCandidate`][candidate] captures these
   checks, parts, pulses and capacities, then creates acknowledgement requests
   and reserves three readmission backings (raw slots, head and pending-by-kind
   counters), constructs the private block buffer and prepares the execution
   owner (watermark, decider, selected/default refusal table and telemetry
   backing) before claiming.
   [`KernelCycle.init(binding:)`][cycle-init] consumes that candidate and calls
   `claimForCycle` before constructing the readmission object and initializing
   its reserved slots. It adopts the same prepared block and execution owner
   after a successful claim, without replacement component allocations. The
   cycle supplies its own completed readmission to the decider during execution.
   The implementation order, not the older “last in init” claim comment, governs.
2. [`NoteOwnership.claimForCycle`][claim] acquires exactly the observed claim
   word by compare-exchange. Only success reads inherited loss and carry.
   [`releaseCycleClaim`][release] writes both while holding the matching claim,
   then release-publishes the next free word. They describe one retirement, not
   independently sampled retirements. Initial word zero has empty inheritance.
3. [`KernelCarryReadmission.init`][readmission-init] immediately consumes the
   canonical [`KernelCarryPlan`][planner]. Planning metadata, event/weight slots,
   head, pending-by-kind counts and pending total are initialized before return.
   Cycle getters expose immutable inherited values; report plan fields are fixed.
4. The concrete concurrent consumer is the **reference-model integration test**
   [`prepareAndPoll`][poll], used by
   `renderReadmitsWhileControlPreparesAndPolls`. Control retries construction
   until retirement permits it, places the completed cycle in `CycleSlots`,
   then polls unresolved loss and the carry report. [`CycleSlots`][slots] uses
   a mutex for publication to the test's render worker. This is not a proposed
   render-side primitive. Construction-call search at this baseline finds test
   callers, not an activated application `KernelCycle` authority.
5. That poll requires unresolved stateful loss and pending count not to increase,
   delivered count not to decrease, and returns as soon as
   `receiverStateMayBeStale` is false. Exposing unbound zeros could therefore
   report reconciliation complete before inheritance arrives; installing a
   nonempty carry later could also regress pending from zero to a positive count.
6. [`unresolvedRetirementLoss`][unresolved] subtracts weighted resolution from
   immutable **immediate-predecessor** loss. Control must inspect every hop.
   [`report` and `resolved()`][report] acquire-load individual counters; the
   loads may span different render moments. They are **not a coherent
   multi-counter snapshot**, nor is a loss/report pair one snapshot.
7. [`KernelCycle.retire()`][retire] records pending note-off tombstones, counts
   own loss, records own carry then remaining re-carried events, and releases
   the claim. Repeated retire and later run do nothing. Host synchronization is
   already required to hand a constructed cycle to render; the claim atomic
   alone does not publish the subsequently initialized cycle ([ownership][ownership]).

## 2. Compatibility boundary and identities (future constraints)

Unbound staging MUST remain outside the ready `KernelCycle` and its report,
loss, resolution and render interfaces. No placeholder ready cycle, default
zero report, mutable inherited getter or pending-state API is authorized.
Before readiness, a consumer has no replacement to inspect; it may keep the
previous cycle's report but cannot treat it as the next hop's result.

Staging reserves private storage; it does not claim the predecessor, drain
fan-in, access render-owned notes/tombstones, retire a cycle or grant render
authority. In a future overlap design a candidate may exist while the predecessor runs, but it may not
bind until a successful matching claim is possible under the existing rules.
The canonical planner is complete; this is not another planning algorithm.

The required binding identity is the tuple:

- the **exact retained `NoteOwnership` instance/lifetime**, not a scope count,
  copied word, reused address or matching numeric generation alone;
- its exact expected free claim word `e`, and successful held word `h = e + 1`;
- the exclusive staged candidate/storage lifetime receiving that claim.

For a predecessor held at `p`, its matching retirement releases `e = p + 1`;
the successor's successful compare-exchange is `e -> e + 1`. Word zero is the
never-used case; fresh claims require zero. Odd words refuse as
`predecessorNotRetired`; a lost expected-state race cannot silently follow a
later retirement (`claimRaced` when free again). Wear-out must not wrap.
Staging must not manufacture a claim state or turn an early odd-word observation
into permission to claim any later free word.

Exactly one binding is attributable to that successful claim and candidate
lifetime. Only its exclusive binder may initialize inheritance. Duplicate,
stale, foreign and losing installations must change neither the winner's
metadata/counters nor ownership state; they must never release the winner's
claim. Equal payloads do not make a duplicate authorized.

**Current provenance status (P1a; P1 remains unresolved):** `CycleClaimState` and
`CycleClaim` privately retain the exact originating ownership, and equality includes
instance identity ([declarations][ownership]). Foreign snapshots receive a typed
refusal before claim CAS/inheritance reads; both release overloads ignore foreign
claims before inheritance writes/CAS. Claims remain copyable under the existing
exclusive-release caller contract, not a one-shot staged-installation protocol.
Immediate cycle construction/retirement keeps the claim and immutable report
metadata retained after retirement; added ARC/lifetime retention is not RT proof.
P1b below supplies a serialized control-only one-shot binder, not asynchronous
staging custody. P1's remainder and P2-P5 remain unresolved, including publication,
concurrent transfer/cancel arbitration and reader/teardown quiescence.

### Implemented P1b: control-only candidate (#851)

The existing constructor was already structurally one-shot; this is a new API
and lifetime boundary, not a duplicate-adoption bug fix. The legacy initializer
keeps its labels and typed `PreparationError`, creates exactly one candidate and
delegates to the actual designated `init(binding:)`: one cycle, one claim attempt.

The internal final reference candidate is deliberately non-Sendable. All calls
through all aliases, including destruction, must be strictly serialized on control.
Independent candidates arbitrate only through the existing ownership CAS. There
is no same-candidate concurrency promise, actor, render lock or new identity counter.

| Candidate state | Bind | Cancel / destruction |
| --- | --- | --- |
| Pending | Remove payload and mark consumed **before** the exact-snapshot claim CAS. Only success reads inheritance and finishes the ready cycle. | First cancel returns true, clears payload on control; abandonment releases only unclaimed storage. |
| Cancelled | Typed `.candidateCancelled`, no claim attempt. | Further cancel returns false. |
| Consumed (success or refusal) | Typed `.candidateConsumed`, no claim attempt or refreshed retry. | Cancel returns false; cannot revoke, retire or destroy a cycle. No payload or cycle back-reference remains. |

Preparation retains validated parts (including the selected telemetry, admission
table and start mode), copied pulses, capacities, the exact originating free
snapshot, and allocated acknowledgement requests. Validation and identity issuance
order is unchanged. Held ownership still refuses preparation: **no predecessor-overlap
staging**. No inheritance, reports, events or render authority are exposed by a candidate.
The module-internal extraction helper has only the designated initializer as its
consumer; there is no payload-adopting cycle initializer or claim exposure.

A refused first bind destroys extracted storage synchronously on control and is
terminal. Held replacement losers report `.predecessorNotRetired`; losers first
bound after the winner retired report `.claimRaced`. Fresh stale snapshots preserve
`.alreadyUsed`. Only a genuinely new preparation can capture a later free state.
No recoverable failure is added after a successful claim: a refused carry plan
still constructs a ready cycle with its immutable refusal report. Ready cycles
store no candidate; retirement and final control teardown retain their existing rules.

[`CycleCandidate` tests][candidate-tests] cover captured inputs/equal-word owners,
alias cancel/consume, independent losers on both sides of retirement, fresh stale
refusal, empty/nonempty/refused plans, partial carry progress and successor binding.
Weak observers cover pending retention, cancel, abandonment, unsuccessful binding,
terminal aliases and ready/retired cycle retention until final control release.
These are serialized control-lifetime tests, not a render teardown/quiescence proof.

Costs: legacy construction has one additional candidate object lifetime (no
assumption of optimizer removal), control-side ARC and value copies. Cancelled or
abandoned preparations spend acknowledgement identities. Aggregate pending
retention is unbounded. Reference `MemoryLayout` is not heap footprint. No extra
inherited-carry copy, claim-layout change or candidate property in the ready cycle
is required. No deadline, general RT, quiescence, runtime adoption or app-completion
claim follows. The prior #841/#769 ScratchHarness start-deadline failure followed
by an unchanged diagnostic retry remains disclosed and unresolved.

## 3. Transition and ownership table

Names below describe obligations, **not new API cases**. “Transfer T” means the
single future handoff decision transferring custody from control to the exclusive
binder/lifecycle owner. It is distinct from “publication P” of the ready cycle.
The binder's execution context and concrete arbitration remain to be reviewed.

| State / transition | Storage and claim owner | Reader / cancellation outcome |
| --- | --- | --- |
| Private staging | Control owns reserved, unexposed storage; no predecessor claim | No ready/report access. Control may cancel and destroy only its own initialized storage. |
| Transfer T contested | Control or binder, never both, must win custody | Cancellation winning before T prevents binding; T winning forbids control cleanup, even before P. |
| Transferred, unbound | Exclusive binder has custody, no claim or render rights | Still no ready access. Claim refusal leaves predecessor/winner untouched; return of storage requires a proved custody handback. |
| Binding claimed | Binder owns the successful matching claim and private initialization | No ready exposure. Cancellation is only a request to the lifecycle owner, not claim revocation. |
| Fully initialized, unpublished | Same owner; metadata sealed, all consumable slots initialized | No counter interpretation by outside readers; cannot discard a held claim just because P has not occurred. |
| Ready publication P | Lifecycle owner retains storage; render gets exclusive run/retire authority after synchronization | Control/other permitted readers acquire ready metadata before reports. No further inheritance installation. |
| Running / retiring | Single render consumer; existing claim and retirement rules | Reports retain existing per-counter semantics. Cancellation cannot destroy or reset render storage. |
| Retired, still referenced | Claim released by render; lifecycle owner retains old storage | No further render work; report readers may remain. Retirement alone is not destruction permission. |
| Quiescent / destroyed | Control receives proved exclusive teardown custody | Deinitialize exactly initialized slots once, then free once; no render final destruction. |

No current path implements T, its cancellation arbitration, storage handback,
or a quiescence receipt. **P2** is the exact single-winner transfer/cancel
linearization and storage-lifetime proof. **P3** is the teardown proof covering
render completion and all report readers, not just the ownership claim word.
Neither #191 nor this contract supplies a reclamation implementation for this.

## 4. Required publication edges

All edges must refer to the same identity/lifetime from section 2.

1. **Existing retirement edge:** predecessor tombstone/loss/carry writes are
   sequenced before `releaseCycleClaim`'s releasing compare-exchange. Successor
   `claimForCycle`'s acquiring compare-exchange reads that released even word
   before copying loss/carry. A failed claim must not read/install inheritance.
2. **Future staging custody edge T:** control reservation and component
   initialization happen-before binder access through an explicit release/acquire
   transfer (or a proved stronger synchronization). Only its winner may bind.
   A cancellation flag or wall-clock order is not this edge.
3. **Future ready edge P:** successful claim, full-value inherited copies,
   planning, slot initialization and all fixed report metadata are sequenced
   before release-publication of readiness. Every receiving report reader and
   render consumer must acquire that publication, directly or through a proved
   transitive handoff, before accessing them. The initializing owner uses its
   own sequenced initialization, not an unsynchronized read by another worker.
4. **Existing progress edges:** after P, render's releasing counter updates pair
   with report/resolution acquiring loads. Metadata remains immutable for the
   entire ready lifetime. Pending only decreases; resolution/delivered only
   grow. Acquiring one progress counter is not a substitute for acquiring P,
   especially when it still contains its initial zero.
5. **Future destruction edge:** final render use/retire and final reader use must
   precede control teardown through a proved ownership/quiescence handback.
   Retirement's release publishes inheritance to the next claimant; it does
   not prove all references to the retired cycle have disappeared.

**P4:** name the concrete ready publication location, readers and synchronization
in the future implementation, including a binder-to-control edge if binding
moves away from control. Prove metadata cannot be reached through any alias
before P and no writer can replace it afterward. The existing test mutex
demonstrates current test handoff only, not a native render implementation.

## 5. Capacity, initialization and refusal

Use validated block capacity `B` (`1...4096`) and reserve readmission capacity
`R = min(256, B)` on control **before T**, independent of unknown inherited count.
The future path must reserve enough for every possible plan at that capacity;
reserving zero because inheritance is not yet known is invalid.

For a prefix-initialized slot representation, distinguish:

| Quantity | Required meaning |
| --- | --- |
| `R` | Reserved backing capacity; never a count of initialized objects. |
| `N` | Final canonical plan count, `0 <= N <= R`; not known during staging. |
| `I` | Actually initialized slots; starts at zero, advances only after each initialization, equals `N` before P. |
| `D` | Slots deinitialized by the teardown owner; exactly `I` once at destruction, not `R`, pending count or remaining head distance. |

Consumption does not deinitialize slots: event/weight values remain initialized
until control teardown even when pending becomes zero. Track each other reserved
component's initialized extent separately. If a future representation initializes
fillers, those objects count in its `I`/`D`; it must not pretend they are raw space.
The [inline carry][carry] and plan already initialize all 256 entries including fillers;
their logical counts are not raw-pointer initialization counts.

The control-only #856 prerequisite now reserves exactly three backings after
candidate validation and acknowledgement issuance: raw slots `[R]` (event, weight,
superseded together), initialized head `[1] = 0`, and pending-by-kind `[3] = 0`.
The non-Sendable, move-only reservation belongs to the noncopyable pending
candidate payload. Terminal extraction still precedes the sole existing claim
CAS; a loser privately destroys its reservation at `I = 0`, with no snapshot
refresh, retry or revocation. Successful binding consumes that owner into
readmission, uses the unchanged canonical fixed planner, initializes each slot
then increments `I`, and seals `I = N` before returning ready.

Consumption, supersession and retirement leave `I` unchanged. The single owner
deinitializes exactly `I` slots and frees them, separately deinitializing/freeing
the always-initialized head and three counters. There is no pointer accessor,
cleanup callback, destructor receipt or new destruction authority. Read-only
diagnostics expose reserved/initialized counts and an opaque equatable
three-allocation fingerprint (private address representation). Candidate
diagnostics exist only while pending; ready cycle/readmission diagnostics are
sealed. Equality demonstrates reuse only while allocations are live, not global
lifetime/ABA identity. Runtime extent/reuse/lifetime tests complement independent
source review of initialize-then-increment and exact-I teardown: trivial slots
cannot expose per-slot runtime destruction counts.

Every existing cycle constructor, including reference prepare/publish/poll, uses
this path; no application activation is claimed. The standalone readmission
initializer delegates while preserving `min(256, max(1, blockCapacity))`, including
out-of-candidate-range values. Empty and overflow-refused plans remain ready with
`N = I = 0`; capacity cuts remain successful. Reports, inheritance and loss
semantics are unchanged.

The #862 slice also prepares the existing private `KernelBlockBuffer` after
validation and acknowledgement issuance, before the sole ownership-claim CAS.
Its object, event backing `[B]`, merge scratch `[B]` and used count `[1] = 0`
belong to the pending move-only payload. The designated binding initializer is
the sole terminal-extraction consumer and adopts that same block after claim,
without constructing another block/backing; no payload remains in the candidate.
Cancellation, abandonment and claim loss release only private storage; consumed
aliases cannot reset or retain the winner's block. Exact-snapshot refusal,
terminal losers and legacy construction remain unchanged.

The block keeps its existing BitwiseCopyable entries/scratch and deallocation,
not readmission's initialized-prefix invariant. Each pending candidate now
retains another block object plus approximately `2 * B * entry stride + Int stride`
backing, excluding allocator overhead. Candidate endpoint/lifecycle tests at
1/256/4096 complement source proof of placement, sole extraction, alias freedom
and cleanup; behavioral tests alone cannot prove allocation placement or frees.
The concrete consumer remains reference `renderReadmitsWhileControlPreparesAndPolls`
/ `prepareAndPoll`, not an activated application render path.

This is only the partial control-only P5 reservation prerequisite, not T/P,
asynchronous transfer or P5 completion. With the #867 source-stage change below,
only inheritance-dependent readmission remains explicit component construction
after claim; its object/atomics and Swift/SDK costs remain unqualified.
Increased pending-candidate and empty-standalone storage (`R`, formerly
`max(1, planned)` after planning), and unbounded aggregate candidate retention,
are explicitly accepted. No global budget or allocation-free whole-bind claim.
No realtime, deadline, quiescence or retirement/install-gap improvement is claimed.
The original #856 local Release 184/122/13 discrepancy remains UNKNOWN; #841/#769
deadline failures and unchanged diagnostic retries remain unresolved evidence.

### Cohesive preclaim execution boundary (#867, source stage only)

Baseline for this change: `66a8f4e60e68816fae5508917a6350a4591387e5` (#864).
This section describes source placement and obligations, **not executed tests,
independent approval, allocation measurements or runtime qualification**.

[`KernelCycleExecutionStorage`][execution] is one noncopyable, non-Sendable
owner, kept in the candidate's noncopyable payload and then in one ready
cycle's private stored property. Its type is module-internal only to cross the
candidate/cycle file boundary. Neither candidate nor cycle exposes the owner,
its components or an owning pointer. Only the existing selected refusal-table
API and value telemetry getters remain public within the module.

The owner constructs the existing watermark and decider, selects the supplied
refusal table by reference (or constructs its existing default counters), and
initializes one private telemetry value with the just-issued acknowledgement
identity. It holds the watermark/decider objects for their full lifetime; their
existing destructors still own their backing. The owner's destructor frees its
BitwiseCopyable telemetry backing. No teardown hook, new raw pointer API,
capability, asynchronous custody or cleanup authority is added.

Ordering and adoption trace:

1. `KernelCycle.prepare` still checks shape, wiring and ownership in the same
   order, retaining the exact originating ownership/snapshot. Held predecessors
   refuse here; preparation still starts after retirement.
2. Candidate initialization issues `KernelAckRequests` next, then prepares its
   reservation, existing block and execution owner. The new work reads captured
   policy/start/pulses/identity and immutable lane/scope/parameter dimensions.
   It retains ownership, tombstones and ramps, but does not read their mutable
   contents, drain events, take safety flags, inspect inheritance, count
   refusals, raise faults or publish telemetry. The default table only allocates
   existing `FanInRefusalCounter` values; it mints no caller identities/chains.
3. `consumeForBinding` has exactly one call site, in `init(binding:)`. It removes
   the payload and marks the candidate terminal **before** the single exact
   claim CAS. Cancel/abandon destroys pending private storage on control.
   Failed claim destroys extracted storage there too; no refresh, recovery,
   retry or claim revocation occurs. Cancelled/consumed and all ownership
   refusal outcomes retain their precedence.
4. Successful claim acquires predecessor retirement and copies its inheritance.
   The cycle adopts the same prepared block and moves the execution owner
   intact. Its only remaining explicit component constructor is the unchanged
   `KernelCarryReadmission(carry:reservation:)`. It initializes exact prefix
   `I = N` within `R` and fixed report metadata, including empty/overflow-refused
   plans. Swift object/atomic/metadata costs have not disappeared.
5. The decider no longer stores readmission. Its sole `decide` caller passes
   `(block: block, readmission: carryReadmission)` from the owning ready cycle.
   Every merge/readmit/supersession uses that completed object. There is no
   optional installation, placeholder report, unbound-ready object, second
   binder or fallback. Takeover, flush, safety, acknowledgement and carry order
   are unchanged.
6. Only a fully initialized cycle returns to the caller. The existing
   `prepareAndPoll` then publishes through test-only `CycleSlots` and polls as
   before: retirement release -> exact claim acquire -> complete initialization
   -> existing test publication/acquisition. Nothing adds pre-ready reporting.
   Consumed candidates retain no execution owner and cannot reset telemetry,
   gate/ramp offsets or takeover bits, revoke claims or affect a successor.
   Render retirement and final control teardown keep their existing contracts.

**Accepted pending-retention tradeoff, not a heap bound.** In addition to the
already prepared block and readmission reservation:

| Component | Existing dimensions now retained while pending |
| --- | --- |
| Watermark | `L` initialized `Bool` lane flags (`1...64` lanes), one `Int` flushing count, one `UInt64` append-refusal count. |
| Decider ramp offsets | `P` initialized `Int64` offsets (`1...65,536` parameters): 8 bytes to **524,288 bytes (512 KiB)**. Shared ramp slots/values remain in `RampSlots`, not copied or read. |
| Decider takeover | `S * 32` initialized `UInt64` words (`1...256` scopes; 16 channels * 128 notes/scope): 256 bytes to **65,536 bytes (64 KiB)**, plus one `Int` scope cursor. |
| Decider gate | One initialized captured `ClockPulseGate` value; no separate gate identity. |
| Default refusal table | `3 * L` initialized `FanInRefusalCounter` values plus one foreign counter (`3...192` lane counters). A supplied table is retained unchanged, not reset/copied. |
| Telemetry | One initialized `KernelCycleTelemetry` value with this cycle's acknowledgement identity. |

Object headers, ARC retention, allocator overhead, inline cycle atomics and
Swift/SDK costs are additional and unmeasured here. Aggregate pending candidates
remain unbounded. No global admission cap, complete operation allocation bound,
allocation-free ready binding, shortened retirement gap, RT/deadline, app/host
activation or iOS-runtime claim follows.

[`CycleExecutionStorage` focused tests][execution-tests] exercise:

- captured start/gate/quota/output/table and untouched queued events, notes,
  active ramp, tombstone, safety request, fault state and prior telemetry;
- fresh default versus supplied refusal-table identity and producer progress;
- cancel/abandon retained-reference endpoints and terminal claim losers under
  fresh/replacing starts on both sides of retirement;
- consumed aliases and independent cancellation after execution progress,
  takeover-bit suppression, continued ramp/gate/telemetry and successor state;
- the owning cycle's empty/nonempty/overflow-refused readmission, immutable
  initialized extent, partial/full delivery and loss resolution;
- actual first/last lane, scope, note and ramp execution at minimum/maximum
  dimensions, and ready/retired final control-release endpoints.

These tests do not prove preclaim placement, absence of mutable reads, exclusive
adoption or exact raw frees. Independent source review must check those separately.
The existing candidate/reservation/follow-up, carry, ordering/ack/takeover,
readmission and actual `renderReadmitsWhileControlPreparesAndPolls` tests are
unchanged, as are allocation/source scans and FaultLatch authority tripwires.

**Source-stage closure only:** changed-Swift strict lint is permitted; compilation,
mirrors, native/Xcode/TSan/application/hardware/iOS execution is not. Coordinator
must register the new test extension under the existing audited
`RealtimeHandoffTests` root, add its canonical mirror test row and native target
source row, and regenerate the project after the separately serialized persistence
and MIDI registrations. Kernel source inclusion follows the existing source tree.
Independent review and fresh shared-machine/atomic-lock authorization must precede
canonical focused Debug/optimized Release evidence with the actual audit machinery.
Later exact-head hosted Apple/lint/full-kernel Debug/Release/three-run TSan and
native Mac gates remain mandatory. No source claim or receipt closes #190,
#64/#48, #856's UNKNOWN discrepancy or #841/#769's unresolved deadline records.

Before P, seal inherited loss, the full carry including `ownCount` and
`droppedForCapacity`, plan refusal/count/invalid/cut/superseded/drop metadata,
slot events/weights, head zero, pending-by-kind, pending total `N`, and zero
progress/resolution counters. Empty inheritance is a bound value, not “unbound.”

- Invalid shape/wiring, unavailable reservation budget or unavailable custody
  must refuse/defer **before claim** with no ready cycle and no predecessor
  mutation. No render allocation fallback, growth or final destruction is allowed.
  Reservation refusal must be observable to its control owner, not a fake empty
  report. This does not claim Swift allocation failure is recoverable today.
- A capacity cut is a successful plan: keep earliest survivors, count cut by
  kind, preserve survivor weights. A surviving ramp completion overflow refuses
  the **plan**, not the cycle/claim: publish a fully initialized ready report with
  `.frameOverflow`, zero planned/cut/superseded, retained invalid/drop counts and
  unresolved loss. Check overflow before cut, after invalid removal/supersession.
- A claim loser installs nothing; its private storage remains accounted for.
  After T, control cannot reclaim it until custody is explicitly returned.
- Once a claim succeeds, cancellation or any newly introduced setup failure
  cannot abandon/revoke it or destroy its storage. The lifecycle owner owes
  completion and eventual legal retirement/teardown, or an explicitly retained,
  fail-closed unresolved outcome. No timeout grants cleanup authority.

**P5:** give the future control-side reservation/admission budget, bound the
number of simultaneous candidates and retained failed/cancelled transfers, and
prove all post-claim initialization fits reserved storage without a new fallible
allocation. Per-candidate `R` is not a global memory bound. No numeric global
budget or guaranteed recovery is ratified here.

The [fixed-planner evidence][carry-doc] remains unchanged: a plan is **14,416
bytes**, with substantial generated stack and whole-buffer copies (observed
55,872-byte consumer and 55,712-byte constructor application-frame chains).
These exclude other frames and are not portable stack bounds or deadline
guarantees. Allocation-free planning is not allocation-free cycle construction.

## 6. Acceptance traces and test mapping

These are source-inspected existing tests plus **minimal future tests required**,
not executed results for #843. New tests must exercise the actual future
publication/custody path, not add a parallel planner or weaken ready consumers.

| Trace / required outcome | Existing coverage | Minimal future addition |
| --- | --- | --- |
| A. Reader before T, during claim/copy/slot initialization and before P sees no ready replacement; after acquiring P sees complete metadata. Nonempty pending never starts at a placeholder zero; empty inheritance can legitimately reconcile immediately. | [`renderReadmitsWhileControlPreparesAndPolls` / `prepareAndPoll`][poll]; [`fixedPlanEmptySingletonAndCapacityEndpoints`][planning-tests]; [`retirementWithNothingPendingHandsOverAZeroLoss`][empty-test]. | Deterministically pause each boundary with both empty and nonempty inheritance; preserve the poll unchanged after ready acquisition. Assert no pre-P report access, no false completion, stable inherited values and monotonic individual counters after P. Add targeted concurrent/TSan coverage later, without claiming snapshot coherence. |
| B. Capacity 1/256; cut versus overflow beyond the cut; superseded overflow is irrelevant. Reservation refusal is distinct from either plan outcome. | [`fixedPlanChecksOverflowBeyondCutButNotSupersededOverflow` and `fixedPlanWeightsResolveOnlySurvivorsAndCutsCountByKind`][planning-tests]. | Feed those fixtures through binding; verify reserved `R`, initialized `I`, sealed report and unresolved loss, including `N = 0` on plan refusal. Force control reservation refusal: no claim, no ready report, cleanup only of private initialized storage. No new algorithm tests needed. |
| C. One matching claim installs exactly once. A duplicate cannot reset counters or replace payloads; a stale expected word cannot follow a later retirement; foreign ownership with the same numeric word cannot bind. | [`followUpClaimFromStaleStateIsRefusedAsRacedOnlyWhenWordIsFree` and wear-out tests][claim-tests]; [`retirementCarryHandoffStaleReleaseNeverOverwritesTheCarry`][stale-test]. These test existing claims/releases, not staged foreign-install rejection. | One identity-qualified installation test with duplicate before/after progress, stale candidate, distinct ownership with equal words, and no-wrap endpoint. Check winner metadata/claim unchanged after each rejection. |
| D. Two candidates race for the same predecessor lifetime; exactly one claim and one P, loser cannot release winner or later retry into a different retirement. | [`freshClaimRacingAClaimRunRetireIsRefused`][race-tests]; existing replacement stale-state test above. | Deterministic two-candidate schedule on both sides of retirement, including winner retiring before loser resumes. Check one installation, loser storage custody and explicit fresh-attempt requirement. |
| E. Cancel before T, racing T, after T before claim, mid-binding, before P, and after P. | No staged cancellation/custody coverage exists. Existing constructors do not expose these states. | Single-owner schedule matrix: pre-T cleanup only, transfer winner prevents cleanup, refused-claim custody handback, held-claim retention/retirement, final reader delayed past retire. Instrument `I`/`D` and free counts: no uninitialized/double destruction or render final release. Repeated retained cancellations must hit reservation backpressure, not unbounded growth. Requires P2/P3/P5 first. |
| F. Two hops: weighted resolution clears only delivered/superseded weight; re-carried/cut/refused state stays lost per hop. Full payload/frame/tie order and ordered data controls survive. | [`fixedPlanReplacementAndTwoHopEmissionsPreservePerHopLoss`][planning-tests]; [`readmissionKeepsRepeatedDataStepsAcrossTwoHops`][bounds-tests]. | Run the same replacement fixtures through ready publication at each hop; poll each hop rather than accumulate or overwrite inheritance. |
| G. Carry dispatch while flushing, takeover releases before carried events, acknowledgement isolation across replacement. | [`carryDeliveredWhileReplacementFlushes`][gap-tests]; [`readmissionRunsBehindTheTakeoverRelease`][readmission-tests]; [`forgedOrForeignSampleNeverApproves`][ack-tests]. | Substitute the future binding path for replacement construction in these scenarios; preserve watermark, release cursor, cycle-specific ticket/epoch and telemetry checks unchanged. |
| H. Retire/install between callbacks permits zero gap; delayed installation allows longer gaps without dropping due carry. | [`carriedEventsDispatchLateAfterAnyGap`][gap-tests] uses 0, 1, 8 and 1,000 callbacks. | Publication-delay schedule proving no unready cycle runs; retain the existing gap fixtures. These finite examples do not establish an unconditional gap bound. |

The old #715 “at least one callback” wording is stale: the gap may be zero or
arbitrarily longer. Without host bounds on installation latency and callback
spacing, there is no unconditional finite callback bound ([current contract][gap-source]).
This document neither removes the gap nor completes E5d overlap acceptance.

## 7. Review disposition and limits

**Independent review: APPROVE (original documentation-only contract).** P1a/P1b
are partial reference-model progress, not approval of overlap. P1 remainder and
P2–P5 remain unresolved: asynchronous transfer/cancel arbitration; quiescent
control destruction; concrete ready publication/alias isolation; and bounded
reservation/retention with no post-claim allocation failure path. Until these
are discharged by a separately scoped design/implementation, staging must not
be presented as safe, implemented or eligible for runtime integration.

Completion of #843 is an independently reviewed contract **or an exact returned
unresolved obligation**, not executable overlap delivery. No new pending-state
API may be selected without ratification. Fresh Copilot review and coordinator
exact-head hosted gates still precede normal landing; this document supplies
neither their results nor implementation approval.

No native callback/cardinality proof follows from #190's reference-model chain
bounds. #191 activation/reclamation remains gated. No hardware, UI, native
callbacks, concurrent replanning, full overlap, #769 harness changes, workload
or threshold changes are authorized. Existing claim, retirement, weighted loss,
flush, takeover and acknowledgement behavior is preserved.

## Source references

[prepare]: ../../Shared/Audio/Kernel/Events/KernelCycle+Preparation.swift#L49-L106
[candidate]: ../../Shared/Audio/Kernel/Events/KernelCycleCandidate.swift
[candidate-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleCandidate.swift
[execution]: ../../Shared/Audio/Kernel/Events/KernelCycleExecutionStorage.swift
[execution-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleExecutionStorage.swift
[cycle-init]: ../../Shared/Audio/Kernel/Events/KernelCycle.swift#L269-L336
[ownership]: ../../Shared/Audio/Kernel/Events/NoteOwnership.swift#L70-L142
[claim]: ../../Shared/Audio/Kernel/Events/NoteOwnership.swift#L180-L209
[release]: ../../Shared/Audio/Kernel/Events/NoteOwnership.swift#L217-L237
[retire]: ../../Shared/Audio/Kernel/Events/KernelCycle.swift#L398-L421
[planner]: ../../Shared/Audio/Kernel/Events/KernelCarryPlan.swift
[carry]: ../../Shared/Audio/Kernel/Events/KernelRetirementCarry.swift
[readmission-init]: ../../Shared/Audio/Kernel/Events/KernelCarryReadmission.swift#L104-L165
[report]: ../../Shared/Audio/Kernel/Events/KernelCarryReadmission.swift#L158-L175
[unresolved]: ../../Shared/Audio/Kernel/Events/KernelCycle+Readmission.swift
[poll]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleReadmissionBounds.swift#L323-L434
[slots]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleStress.swift#L77-L83
[carry-doc]: ../kernel-carry-plan.md
[planning-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleCarryPlanning.swift#L9-L156
[empty-test]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleRetirement.swift#L134-L155
[claim-tests]: ../../FluxKlangTests/KernelCycleFollowUpTests+WearOut.swift
[stale-test]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleRetirement.swift#L446-L466
[race-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCyclePreparationEdges.swift#L70-L96
[bounds-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleReadmissionBounds.swift#L115-L149
[gap-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleTakeoverGap.swift#L55-L108
[readmission-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleReadmission.swift#L354-L377
[ack-tests]: ../../FluxKlangTests/RealtimeHandoffTests+KernelCycleOrderingAcknowledge.swift#L121-L170
[gap-source]: ../../Shared/Audio/Kernel/Events/KernelCycle.swift#L157-L176
