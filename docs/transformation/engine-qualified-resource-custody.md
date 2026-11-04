# Engine-qualified resource custody

| Field | Value |
|---|---|
| Decision | #285, parent #191, roadmap #48 |
| Status | Ratified scope for this decision record; source implementation is not authorized by this record |
| Source baseline | `6e4db20dab5bb8896e73004e5f86f76a180b4745` (tree `4d665c6d590de3d40c81e75bae44637baf1b30f5`) |
| First future slice | Actor-private, noncopyable, **never-published** adoption and exact-binding retirement |
| Initial bound | One outstanding preparation lifetime, including queued admission and one custody/evidence slot, covered by canonical ledger capacity |
| Unresolved prerequisite | [#291 specifies the proposed target and eligibility](engine-software-routing-activation.md); justified all-category charged-region cost basis, concrete implementation and independent qualification remain prerequisites to canonical successful binding |

**No supplied representation/cost basis satisfies all-category accounting in
section 5, even in the narrower charged covered backing-region domain.
Allocator-dependent eligibility implementation remains stopped.** This #304
amendment supplies neither that basis nor implementation or eligibility.

## 1. Decision and activation meaning

Evolve the existing private processor-and-arena cell in `HostAuthority`, rather
than introduce another pending owner or repeat abandoned-preparation maintenance.
The first proposed lifecycle may retain a genuinely prepared resource as held,
relinquish it, destroy it and account for its exact retirement, but **cannot
publish it, commit it to render, or export a resource borrow**. This is a concrete
ownership boundary, not a new activation success category.

Preserve the existing prepare/review/authorize/commit contract. Successful
preparation must name an actual artifact eligible for that activation contract;
it is not merely successful offline compilation or evaluation. The current
`OfflineAudioRoutingProcessor` is **not activation-ready**. Assigning it a
`PreparedActivationID` cannot fix that, and no “offline-prepared” success may
enter `ActivationTransaction.prepared`.

[#291](engine-software-routing-activation.md) specifies the proposed software-role
target and eligibility predicate. Section 5's narrower charged covered
backing-region accounting requires a justified all-category basis and enforcement
before corresponding allocation or authority retention, not merely before
binding. That basis, concrete implementation and independent qualification remain
prerequisites to canonical successful binding; existing construction-only behavior,
including #299/#302's requested-raw-only acceptance, remains construction-only. The existing
review/authorization path and commit-time checks remain required. This
prerequisite does **not** block this decision record, nor require all of G2 to
be implemented first.

## 2. Grounding in accepted source

These are current APIs and contracts, not implementations of the proposed
sequence in section 4.

| Source | Current boundary and consequence |
|---|---|
| [`HostAuthority.swift`](../../Shared/Host/Authority/HostAuthority.swift) | `preparation` holds file-private `PendingPreparation: ~Copyable`. `constructNextPreparation`, `evaluatePreparation`, `disposePreparation` and `reclaimAbandonedPreparation` operate without suspension. Prepare-only mode refuses external successful answers, retirement, cancellation and commit operations. Explicit consuming disposal precedes a failure answer; post-cleanup refusal latches a fault. Last-reference actor destruction is not qualified teardown. |
| [`OfflineAudioRoutingProcessor.swift`](../../Shared/Audio/Kernel/Processors/OfflineAudioRoutingProcessor.swift) | Noncopyable, explicitly unavailable as `Sendable`; privately owns the lowered plan and its existing `ScratchArena`. No publication, retirement or engine acknowledgement is wired. |
| [`ActivationTransaction.swift`](../../Shared/Host/Authority/ActivationTransaction.swift) | `PrepareAttemptID` includes transaction issuer identity and generation. `prepared` accepts success into `awaitingReview`; authorization and commit checks follow. A raw prepared name is not evidence that an executable artifact exists. |
| [`EnginePlanLedger.swift`](../../Shared/Host/Ownership/EnginePlanLedger.swift) | The single canonical non-Sendable ledger admits pending work, creates `PlanBinding`, and retains held/committed/retiring entries. `complete`, `completeRetiring`, `reclaim`, `release` and `acknowledgeRetired` account for ownership, not physical work. Genuine executor cleanup and quiescence remain caller premises. |
| [`HostAuthorityBook+Prepare.swift`](../../Shared/Host/Authority/HostAuthorityBook+Prepare.swift) | `begin` stages transaction/queue admission before ledger dispatch. `prepareAnswered` routes wanted and abandoned answers; `route` uses `completeRetiring` for transaction-rejected genuine success. `cancel` checks queue room before releasing held ownership. |
| [`HostAuthorityBook+Plans.swift`](../../Shared/Host/Authority/HostAuthorityBook+Plans.swift) | `scheduleRetirement` and `refillRetirements` preserve discard delivery. `retired` checks queue, outbox, restore and deferred-discard obligations before `acknowledgeRetired`; it does not observe destruction or reader departure. |
| [`PreparedPlanSlot.swift`](../../Shared/Audio/Kernel/Memory/PreparedPlanSlot.swift) | Requires `Plan: AnyObject & Sendable`, exclusive ownership and supported synchronous destruction. `publish` creates a separate arena and uses latest-wins exchange; `reclaim` returns a count, not the destroyed binding. It cannot be adopted unchanged for the existing processor. |
| [`RetiringExchange.swift`](../../Shared/Audio/Kernel/Memory/RetiringExchange.swift) | Latest-wins publication can release an unadopted payload directly on control; adopted payloads retire through a queue. A release need not be destruction with aliases or isolated destruction. Control/render roles and detached-render teardown are caller obligations. |
| [`ScratchArena.swift`](../../Shared/Audio/Kernel/Memory/ScratchArena.swift) | Allocates at initialization and frees at destruction; maximum arena capacity is 16 MiB. Borrowed buffers expire on reset or release. Last release requires no owner use in flight or still to come. |
| [Graph contract](../../Shared/Contracts/Graph/README.md) | Portable graph validation and bounded allocated-buffer offline execution confer neither activation custody nor live routing, backend, hardware or RT qualification. |

In particular, neither a ledger phase, queue dequeue, reclaim count, mute,
supersede nor actor serialization is a destruction or reader-departure
acknowledgement. No new method or acknowledgement API is defined here.

## 3. Owners, identities and capacity

**Physical owner:** `HostAuthority`'s file-private noncopyable cell, evolved in
place, keeps the plan and its already allocated arena together. No second arena,
reference-box conversion to satisfy `PreparedPlanSlot`, supplied backend, public
resource accessor or escaping pointer is part of this slice. Local evaluation
borrows must finish within their nonsuspending actor operation.

**Canonical accounting owner:** the authority's private `HostAuthorityBook.plans`
remains the only `EnginePlanLedger`. The book owns transaction interest and
discard delivery; the cell owns the actual resource and, after destruction, the
bounded evidence obligation. Those records associate custody with canonical
state; they are not a duplicate ledger or a replay-history service.

Before binding, every action names `HostPrepare(instance: EngineInstanceID,
attempt: PrepareAttemptID)`: the exact strongly retained opaque instance and the
full attempt (issuer identity plus generation), not a project/raw-ID lookup or
the current instance substituted at delivery. After genuine canonical success,
retain the resulting `PlanBinding(instance, attempt, prepared)` from canonical
state. All three components participate in equality. The ledger alone constructs
bindings; no global identity minter or reconstruction from snapshots is added.
Inert snapshots are observations, not ownership authority.

For this first slice, the admission foundation accepted in **#288/#290** now
reserves at most **one outstanding preparation lifetime** for construction-only
custody; successful-binding phases below remain proposed. The bound spans pre-admission
reservation, queued admission, construction, live pending/held/retiring custody
and retained completion/destruction evidence. These are successive states of
one reservation, not separate allowances. The authority reserves the lifetime's
physical/evidence capacity **before calling canonical preparation admission**;
any additional preparation is refused unchanged before canonical mutation or
enqueue. If canonical admission refuses, the provisional reservation is released
without leaving a phantom reservation or command. Successful admission retains
the charge through the terminal cleanup/accounting rules in section 4.

The same reserved slot must retain completion disposition, exact identity/binding,
cleanup evidence and a bounded fault outcome. Canonical admission covers the
accepted lifetime; the ledger must have capacity at least one, shared across
all phases and both current and retained prior instances. Ledger/queue headroom
does not authorize a second queued preparation in this slice.

This prevents ordinary work from creating a FIFO dependency cycle: without the
gate, book-level `begin` can queue preparation B while A occupies the cell; construction of B
then waits for A, but `discard(A)` behind B prevents A's canonical retirement.
[`nextEngineCommand`](../../Shared/Host/Authority/HostAuthorityBook+Commit.swift)
does not automatically bypass that preparation. The proposed policy neither
adds a delivered-but-unconstructed deferred-command owner nor bypasses the FIFO.
Cancellation, discard delivery and retirement-progress operations **must not be
gated on physical-slot availability**; they retain their existing qualification,
queue-room and delivery checks and can progress while A owns the reservation.

One lifetime is intentionally restrictive: no overlapping replacement admission
or construction while queued, held, retiring or unacknowledged. Lost answers/evidence do not
permit eviction, timeout reuse, reset, another dispatch or another terminal
answer. Uncertainty consumes the slot indefinitely and applies backpressure.

## 4. Proposed never-published sequence

The labels below describe **future sequencing requirements**, not implemented
methods. Successful branches are conditional on section 1's implementation and
qualification prerequisite. All cell transitions are private nonsuspending actor operations.

| Label | Named owner, action and retained custody on refusal |
|---|---|
| **Reserve** | Before calling the book's canonical preparation admission, the authority reserves the single outstanding lifetime, including physical custody **and** completion/cleanup evidence capacity. Section 5's owner-specific charged-region preflight must precede each corresponding allocation or authority retention, including inherited document backing and work on later-refused paths; lifetime reservation alone does not establish those charges. An existing lifetime refuses additional preparation unchanged before canonical mutation or enqueue. On acceptance, associate the reservation with the book's full instance/attempt and queued snapshots; construction reuses that admission, never dispatches again. Admission refusal releases only the provisional reservation, leaving no resource, phantom reservation or queued command. Once admitted, missing admission evidence, blocked delivery or identity mismatch preserves custody and charge and faults or refuses as appropriate; it does not free the reservation. This preparation-admission gate does not gate cancellation, discard delivery or retirement progress. |
| **Construct** | The authority pulls only the admitted FIFO head and constructs into the reserved cell using the accepted pending owner. The processor keeps its plan and original arena. Section 5's preflight includes simultaneous construction storage before allocation, even if construction later refuses. Already abandoned queued work follows the existing no-construction termination path. Recoverable constructor failure must fully unwind partial allocations before the single terminal failure answer; fatal allocator exhaustion is nonrecoverable and establishes neither cleanup nor a terminal answer. Until canonical failure is accepted, the identity/evidence reservation remains occupied; bookkeeping refusal faults closed without a second answer. |
| **Complete once** | Only after a truthful activation-eligible artifact exists, including section 5's all-category charged-region accounting enforced before allocation or authority retention, the authority stages promotion of that same cell and submits its genuine completion once through the book. Completion is not postallocation authorization or a substitute for that preflight. The book performs its canonical `complete` or `completeRetiring` transition; the authority takes the exact resulting binding from canonical state (a `.routed` outcome alone does not carry it). No second construction, dispatch or substitute failure answer is allowed. A state-preserving completion refusal leaves the actual resource and evidence reservation with the cell and the canonical admission charged. Unexpected inconsistency after a canonical transition retains custody/charge and faults closed, rather than fabricating a binding or rolling back by assertion. |
| **Wanted success** | If the transaction accepts the genuine success, the book retains the reviewed binding and the cell becomes held under that exact binding. Publication remains structurally unavailable. Lost outward reporting does not release either charge or authorize resubmission. |
| **Abandoned or rejected success** | A genuinely successful result whose pending interest was abandoned becomes retiring through the existing canonical reclaim path. A transaction-rejected genuine success becomes retiring through `completeRetiring`, not terminal failure: the resource still exists. The authority retains the resource/binding; the book retains the scheduled discard in queue/outbox. Full delivery queues delay work without losing custody. |
| **Abandoned pending cleanup** | If no genuine success was produced, reuse `reclaimAbandonedPreparation` and consuming pending disposal, with exact canonical abandonment evidence. Finish cleanup before the one failure completion. If completion won the serialized order first, use its resulting bound retiring path instead. A still-wanted or inconsistent pending entry is not silently reclaimed; the cell and admission remain charged. |
| **Authorized relinquishment** | Held ownership leaves held only through the book's authorized exact-binding release path, such as successful `cancel`, not by treating it as abandoned pending work. Preserve `cancel`'s queue-room preflight: queue-full or any other refusal leaves transaction, held resource, binding and capacity unchanged. Successful release marks retiring and schedules discard; it does not destroy anything or free capacity. Committed ownership, outside this first slice, likewise requires authorized release, never abandoned reclaim. |
| **Consume and finish** | For the exact retiring binding, the book preserves and services qualified discard delivery, including outbox and restore/deferred dependencies; it does not clear them to manufacture eligibility. The authority permits consuming cleanup only when no local borrow remains and no future use is possible. Publication is absent by construction, not inferred from a quiet actor. Keep the inert binding outside the consuming scope, destroy the processor **and its existing arena**, then record completed destruction only after that scope has returned. Wrong binding/phase or unresolved use keeps the resource and charge. Duplicate disposal must never consume twice. |
| **Acknowledge and release charge** | The authority retains the exact-binding destruction evidence in the same slot and presents retirement through the book only after all discard obligations are satisfied. The book's delivery guards and the executor's destruction evidence are both required before canonical `acknowledgeRetired`. Only successful canonical retirement releases the bound entry and custody/evidence reservation. Refused or lost acknowledgement leaves a destroyed-but-unacknowledged obligation charged; retry, if allowed, uses the retained exact evidence, never another destruction or prepare answer. Missing evidence or uncertain acceptance faults closed with bounded backpressure, not assumed retirement. |

For an unbound failure, accepted canonical failure removes the pending entry
only after completed cleanup; then its reservation may be released. If that
post-cleanup completion is refused or its acceptance cannot be established, the
authority retains the bounded cleanup/fault record and does not answer again.
For bound success, destruction and ledger retirement are distinct events.
Dropping the last authority reference performs neither protocol.

## 5. Bounds beyond the arena

The one-resource bound and the arena's **16 MiB** ceiling are **not a
whole-resource byte proof**. The narrower accounting domain is **finite
preflighted charges for backing regions representing covered preparation data**,
including the original scratch region and added endpoint/peak storage as well
as all five categories below. It includes unused reserve/excess collection
capacity, internal representation/object headers and metadata, padding and
simultaneous construction copies. It is not total allocator-owned capacity,
total heap, physical residency or memory availability.

Region boundaries and exclusions must be justified independently of convenience
of accounting. The only exclusions are:

- Underlying allocator block rounding or slack demonstrably outside the covered
  representation's backing region, not collection reserve or representation padding.
- Underlying allocator bookkeeping demonstrably distinct from covered
  representation headers, metadata and preparation bookkeeping.
- OS virtual-memory/page-management overhead and physical-residency effects
  outside the accounted regions.

Swift/Foundation management never makes backing used to represent, validate,
copy or retain covered data, or its temporaries, free. No other cost is excluded
merely because it is not enumerated here. Unjustified or unknown capacity is an
unmet qualification requirement, never a zero charge.

Every category must identify its accountable owner, justified representation/
backing-region cost basis, retained multiplicity, simultaneous construction
overlap and enforcement point. Checked arithmetic and finite limits must enforce
charges **before corresponding allocation or authority retention**, including
later-refused paths and inherited document backing retained by the authority.
Any representation change must preserve canonical graph/project values, metadata
and identity, the original processor/arena and custody provenance; accounting
does not authorize replacing or reconstructing the original custody chain.

| Retained data | Required finite accounting |
|---|---|
| Lowered plan and descriptors | The compiler during construction and the private cell during retention must identify the region/cost basis, retained multiplicity and simultaneous lowering/construction copies, with enforcement before allocation or retention. [`PreparedAudioRoutingPlan`](../../Shared/Audio/GraphCompiler/AudioRoutingCompiler.swift) retains layout endpoint arrays and their node/port/role IDs, bounds, output rows, mute rows and ordered terms. [`AudioRoutingLimits`](../../Shared/Audio/GraphCompiler/AudioRoutingTypes.swift) and [`AudioRoutingAdmission`](../../Shared/Audio/GraphCompiler/AudioRoutingAdmission.swift) check channels, frames, terms, scratch and sample work; covered collection backing, headers, reserve and any future activation descriptors still need justified charged-region budgets. |
| Input snapshots and validation data | The authority/book, queue and validation/transaction owners must identify a region/cost basis for queued `GraphDocument`/`ProjectDocument`, selected and unrelated project references, roles, metadata/extension bags, capability and permission context, validated candidates, transaction/review/recovery snapshots and temporary validation/lowering dictionaries, sets and arrays. They must bound retained multiplicity and simultaneous validation/lowering copies before allocation or authority retention, including inherited document backing and later-refused paths. Serialized document ceilings do not alone bound these in-memory regions or construction overlap. |
| Control bookkeeping | [`HostAuthorityBook`](../../Shared/Host/Authority/HostAuthorityBook.swift) holds projects, outstanding attempts, reviewed/resident bindings, in-flight commits, authorization windows, restore state and deferred discard lists. The book and its ledger must identify their covered bookkeeping region/cost basis, retained multiplicity and simultaneous construction/update storage, enforced before allocation or authority retention. The project limit is 16; the default ledger capacity is 64 (configurable), not an extra physical-resource allowance. Ledger entries, at most two instance records, queue/outbox/deferred bindings and duplicate retained references must be counted together, not as unbounded side lists. |
| Delivery and evidence | The authority/cell, book and [`EngineCommandQueue`](../../Shared/Host/Authority/EngineCommandQueue.swift) must identify their delivery/evidence region/cost basis, retained multiplicity and simultaneous command/result/evidence construction storage, enforced before allocation or authority retention, including refused delivery/completion paths. The queue has 256 command slots, not a 256-byte budget. Commands retain snapshots, bindings and descriptor arrays. Retirement outbox entries are ledger-backed. Completion results, retained identities, destruction evidence, acknowledgement uncertainty and fault/diagnostic data need explicit bounded storage; one slot includes destroyed evidence, not just live processors. No growing tombstone or retry log. |
| Observations and evaluation buffers | Producing authority/evaluation owners and retaining caller/observer owners must identify the region/cost basis, per-value limits, retained multiplicity and simultaneous creation/copy storage for layout snapshots, authority/ledger snapshots, caller input, allocated output/peak arrays and returned blocks. Enforcement must precede creation allocation and each corresponding retention; observer-owner accounting covers both snapshot creation and retention, including later-refused evaluation paths. An inert copy may still retain identity objects; shared backing is not automatically free. Independent historical observers are not absorbed into one preparation lifetime allowance. The authority cannot claim a whole-system lifetime bound while arbitrary observers accumulate snapshots or blocks. |

The compiler's existing document-free plan and preflight checks are useful
inputs to this accounting, not permission to omit the book's retained documents
or evidence. Aggregate accounting must justify shared backing, retained
multiplicities and simultaneous overlap across all five categories and their
owners; neither double use of one allowance nor an unproved zero charge is a
basis. **No supplied representation/cost basis satisfies all-category accounting;
an unproved category blocks qualification, and allocator-dependent eligibility
implementation remains stopped.** Even a future qualified charged-region bound
would not establish total allocator capacity, memory availability or fatal-OOM
recovery. Raising resource capacity or introducing publication requires a new
bound including reserved, pending, held, published/current, stalled, retiring
and destroyed-but-unacknowledged lifetimes.

## 6. Later publication obligations, not prerequisites to this record

A later design must choose a representation that preserves the resource and
its arena as one lifetime, without pretending `PreparedPlanSlot` accepts this
noncopyable/non-Sendable processor unchanged. It must map every release path
(including latest-wins supersession, refused publication, queued reclamation
and teardown) to the exact binding and completed destruction evidence.

Once readers exist, the executor must establish **departure of every reader of
that exact resource**, prevent future acquisition, and order departure before
control-side consuming destruction. Queue acceptance, `.ok`, reclaim counts,
mute and elapsed time are insufficient. Escaping/weak/unowned aliases, shared
queue roles, nonreentrant borrows, destruction execution context and any
FaultLatch caller obligations require explicit treatment.

Old-instance quiescence is separately qualified: `supersede` is not quiescence,
and per-binding destruction is not proof the old engine can do no more work.
The ledger's `acknowledgeQuiescent` requires truthful backend evidence and no
pending preparations; the prior record releases only with quiescence and zero
entries. Reset cannot erase unknown custody or replace lost evidence.

These are later publication/reader/reset design obligations, **not circular
requirements to complete G2 before accepting the never-published decision**.
The first slice's no-reader premise must be structural and reviewed, not a
claim that actor isolation solves published-reader safety.

## 7. Focused future fixtures and acceptance boundary

These are fixture specifications, not tests implemented or run by this record.
Use exact identities, actual custody/destruction observations and canonical
snapshots; never accept a queue count as destruction evidence.

| Fixture | Required observation |
|---|---|
| Same- and cross-project raw-ID reuse; both completion orders | Distinct full attempts/instances remain distinct even with equal prepared names. Completing the older or newer attempt first cannot transfer custody or retire the other's resource. |
| Wrong instance/attempt/binding; duplicate disposal | Every mismatch preserves the correct resource and charges; repeated disposal never destroys twice or acknowledges another binding. |
| Evaluation/disposal and abandonment/completion in either serialized order | A local borrow ends before destruction; later evaluation refuses. Abandon-first uses pending cleanup or genuinely successful retiring completion; complete-first preserves the canonical binding and follows its qualified release path. |
| Recoverable constructor failure and post-cleanup bookkeeping refusal | Partial construction fully unwinds before the only failure answer. A refused completion after cleanup retains evidence/fault capacity and never emits a second answer. Fatal allocator exhaustion establishes neither cleanup nor a terminal answer. |
| Lost answers and repeated abandon/reuse | Pending/custody charges remain occupied; repeated cycles never exceed one physical/evidence slot or canonical capacity. No dispatch replay, eviction or implicit reset. |
| Canonical completion refusal (review addition) | The real resource, exact pending identity and reservation survive unchanged; no fabricated failure, binding or capacity release. |
| Transaction-rejected genuine success (review addition) | `completeRetiring`'s exact binding remains attached to real retiring custody, with discard obligations, not a “failed therefore freed” shortcut. |
| Destruction completed; retirement acknowledgement refused/lost (review addition) | Processor and arena are gone before evidence, yet evidence capacity stays charged until canonical acceptance is established. No duplicate destruction or guessed acknowledgement. |
| Queue-full cancellation (review addition) | Held resource, reviewed binding, transaction and all capacity remain unchanged on preflight refusal; later authorized release is a separate transition. |
| A/B/discard(A) admission ordering | While A owns the sole lifetime (queued, constructing, live or evidence-only), B is refused unchanged before canonical mutation or enqueue. In particular, with A held, B cannot sit ahead of `discard(A)`: authorized cancellation, qualified discard delivery, completed destruction and exact-binding retirement of A can progress without extra construction, lost commands or fabricated acknowledgement. Admission refusal leaves no phantom reservation/command; no deferred-command owner or FIFO bypass is used. |
| Evidence-inclusive capacity (review addition) | A destroyed-but-unacknowledged slot blocks the next admission, not only construction, just as a live slot does. Missing evidence cannot be replaced by an unbounded side record or another answer. |
| Later published-reader fixture, outside the first slice | No destruction or retirement acknowledgement while an exact-resource reader remains active; qualified departure enables reclamation. Prove old-instance quiescence separately. |

Future #191/G2/#62/O2 acceptance requires a justified all-category basis for
section 5's narrower charged covered backing-region domain, including owner,
multiplicity, construction overlap and enforcement before allocation or authority
retention on later-refused paths, inherited documents and observer creation and
retention. **No supplied basis satisfies that accounting; allocator-dependent
eligibility implementation remains stopped.** Policy approval is not
representation qualification and does not upgrade #299/#302's raw-only acceptance.

Acceptance of this record establishes the ownership choices and explicit
unresolved boundaries, not successful binding, physical teardown evidence,
reader safety, a lifetime byte bound, runtime readiness, #190 caller proof or
completion of #191/G2/#62/O2. Binding, installation, reclamation, reader departure,
quiescence, stopped-residency and runtime qualification remain separate gates.
It authorizes no runtime, hardware or service work.
Independent source-to-contract review and normal integration review remain
required; this document is not a completion claim.
