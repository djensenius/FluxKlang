# Software-role routing activation target

| Field | Value |
|---|---|
| Decision | #291, parent #191, roadmap #48; follows #288/#290 |
| Status | Proposed target and eligibility requirements only; no source implementation or runtime authorized |
| Source baseline | `de1cbcd84e77905f17d7a6be0e876ec0a8f7f5f4` (tree `41d7a57b570d64199e79a1966239a7af33f1f664`) |
| Target | Software-owned planar Float32 role ports, qualified by the existing canonical engine instance |
| Application | Persistent selection of a whole executable image within the same private custody boundary |
| Remaining prerequisite | Justified all-category charged-region cost basis, concrete installation/use implementation and independent qualification before canonical successful binding |

**No supplied representation/cost basis satisfies all-category accounting in
custody section 5, even in the narrower charged covered backing-region domain.
Allocator-dependent eligibility implementation remains stopped.** This #304
amendment supplies neither that basis nor implementation or eligibility.

**Current construction-only progress (#299):** The existing private cell now owns
one initialized fixed-stride input/output/peak slab alongside its original
processor/arena, stages input and returns independent value snapshots. For frame
stride F and input/output channel counts I/O, added requested bytes
`P = 4*(F*I + F*O + O) <= S <= 16 MiB`, where S is the original scratch request;
`S+P <= 32 MiB` bounds **only those two requested raw allocations**. Zero payload
adds no slab, not an empty processor or a free lifetime; mute-only still executes.
Caller input and new/historical snapshots, collection backing capacity, allocator
overhead, temporaries, construction/evaluation peaks and other custody accounting
are additional. Staging/clearing/copying is outside `maxSampleWork`. Configuration
throws do not make allocator exhaustion recoverable; recoverable errors unwind
before a failure answer, while fatal allocation establishes neither cleanup nor
a terminal answer. This is not activation eligibility: predicate 3.6 and custody
section 5's charged-region accounting remain unmet and must preflight **before relevant
future allocations/retentions**, not retroactively before binding. No successful
binding, installation, commit/ACK, publication/readers, overlapping replacement,
reset/quiescence or runtime/RT qualification is added. The historical grounding
below records the decision baseline, not a claim that those gates are now met.
The narrower domain defined below does not upgrade #299/#302's historical
requested-raw-only acceptance.

## 1. Decision and boundary

Specify a **new in-process software-role routing target**, not a physical
endpoint backend. Its application operation selects a complete prepared routing
image persistently; subsequent processing uses that installed image internally,
not a caller-selected preparation. Whole-image replacement is the intended
effect, subject to the single-lifetime restriction in section 5.

The target remains inside the **same private custody boundary** chosen by
[#285/#287](engine-qualified-resource-custody.md): evolve the existing cell,
not another owning target, pending slot, copied processor or borrow registry.
The proposed primitive is serialized, nonsuspending and control-only. It has no
supplied backend, escaping resource borrow or render reader. Actor serialization
establishes local ordering only, not reader departure or engine quiescence.

Names such as `prepareSoftwareRouting`, `installPreparedRouting` and
`processInstalledRouting` are conceptual proposals, **not existing APIs**.
Qualifying an isolated installation/use primitive does not install every
production candidate during preparation, authorize production publication, or
open #285's never-published lifecycle. Preparation establishes eligibility for
the existing review/authorization path; it is not authorization or commit.

## 2. Grounding in accepted source

These are existing boundaries, not implementations of the proposed target.

| Source | Current capability and limit |
|---|---|
| [`EngineCommandQueue.swift`](../../Shared/Host/Authority/EngineCommandQueue.swift), `EngineCommand` | Carries prepare/commit/discard identities; performs no engine operation. This decision does not implement `EngineCommand.commit`. |
| [`ActivationValidator.swift`](../../Shared/Host/Authority/ActivationValidator.swift), `ValidatedActivation` | Context validation is neither authorization nor a write and can become stale. Provenance alone is not activation. |
| [`HostAuthority.swift`](../../Shared/Host/Authority/HostAuthority.swift), `begin`, `constructAdmittedPreparation`, `PendingPreparation.evaluate` | #288/#290 reserve one lifetime before canonical admission and consume its admitted FIFO command. Construction remains private and construction-only; evaluation allocates output/peak arrays per call. Prepare-only mode refuses external success and commit. |
| [`AudioRoutingAdmission.swift`](../../Shared/Audio/GraphCompiler/AudioRoutingAdmission.swift), `preflight`, `validateSelectedContext` | Checks the bounded role-input/output and at-most-one constant-mute subset, selected graph/project context, topology, metadata, capability and budget refusals; does not validate unsupplied unrelated graph documents. |
| [`AudioRoutingCompiler.swift`](../../Shared/Audio/GraphCompiler/AudioRoutingCompiler.swift), `PreparedAudioRoutingPlan`, `compile`, `validateCorrespondence` | Produces a document-free plan and runs an ephemeral offline-plan consistency validator against the selected graph: endpoint identity/order and geometry, node coverage, mute identity/geometry, and positional row/ordered-term contents. It does not produce a persistent executable-component coverage descriptor or installed target. |
| [`AudioRoutingTypes.swift`](../../Shared/Audio/GraphCompiler/AudioRoutingTypes.swift), `AudioRoutingLayout`; [`OfflineAudioRoutingProcessor.swift`](../../Shared/Audio/Kernel/Processors/OfflineAudioRoutingProcessor.swift), `process` | Fixed-stride planar Float32 processing of supplied buffers. The noncopyable processor owns its original arena. Its private `commit` copies samples to caller buffers; it is not activation or `EngineCommand.commit`. |
| [`ActivationTransaction.swift`](../../Shared/Host/Authority/ActivationTransaction.swift), `ActivationCommitReport`, `acknowledged` | Requires an outcome and exact planned-node partition. Empty sets alone distinguish neither successful empty replacement nor failure. |
| [`PreparedPlanSlot.swift`](../../Shared/Audio/Kernel/Memory/PreparedPlanSlot.swift); [`ScratchArena.swift`](../../Shared/Audio/Kernel/Memory/ScratchArena.swift) | The slot requires an exclusively owned `AnyObject & Sendable` plan and creates a fresh arena. It is not an adapter for this processor. The arena's 16 MiB ceiling is not a whole-resource byte proof. |
| [`RoutingTranslator.swift`](../../Shared/Models/RoutingTranslator.swift), `settings(for:)` | Legacy `ChainGraph`-to-WING settings translation has a different graph, operation and resource boundary; it is not this target's activation. |

## 3. Genuine preparation predicate

Before any canonical successful binding, all of the following must hold.
Predicate 3.6's charged covered backing-region accounting must be enforced
before the corresponding allocation or authority retention, including paths
later refused; binding is not a deferred accounting checkpoint.

1. Consume the actual admitted FIFO command once, retaining its exact
   `HostPrepare(instance:attempt:)`, full canonical instance/attempt and validated
   graph/project context. No second admission, dispatch, global identity minter
   or binding reconstructed from a snapshot. Later binding comes only from the
   canonical ledger, under the custody decision's completion rules.
2. Preserve the supported subset and every existing topology, context, metadata,
   capability and resource refusal. Lower the complete executable image rather
   than retain another graph document as a stand-in for execution.
3. Own initialized input/output/peak storage and exact role geometry before
   installation. Each role ID, direction, node/port identity and width resolves
   to an actual owned slab range. A role input's graph port is an output; a role
   output's graph port is an input. Channels use fixed `maxFrames` stride,
   including padding; peaks have one element per output channel. Checked ranges
   must be disjoint, correctly Float-bound and within their full slab counts.
   These are software ports, not promises of physical endpoint binding.
4. Retain the same original processor and scratch arena in the evolved private
   cell, together with the added storage and immutable coverage descriptors.
   No second arena, reference boxing, duplicate owner or `PreparedPlanSlot`
   adaptation. Scratch remains cycle-local and initialized before reading;
   endpoint storage must not depend on scratch surviving a reset.
5. Establish exact node-to-executable-component correspondence during
   compilation beyond the existing offline-plan consistency check described in
   3.1.
   It must cover every candidate node with the actual ranges, rows and
   operations below, with no missing or extra node. Appending a node-ID set
   after compilation proves nothing.
6. Preflight finite charges for the covered backing regions of added endpoint/peak
   storage, lowered collections, coverage/layout descriptors and construction
   storage using checked arithmetic **before** allocation or authority retention.
   Include unused reserve, internal representation/object headers and metadata,
   padding and simultaneous construction copies. For every custody section 5
   category, identify its accountable owner, justified region/cost basis,
   retained multiplicity, construction overlap and early enforcement point;
   retained documents (including inherited backing), control/evidence data and
   observer creation and retention are not free. Swift/Foundation management
   does not exempt backing or temporaries; unknown capacity blocks qualification.
   Only custody section 5's independently justified underlying allocator and
   OS costs outside covered representation regions are excluded. This narrower
   domain is not total allocator capacity, heap, physical residency or memory
   availability. One reservation and a scratch ceiling do not discharge it.
7. An independently implemented and exercised concrete installation operation
   must be able to consume this image without inventing endpoint resources
   afterward. Eligibility is not inferred from validation, offline evaluation,
   provenance, a prepared name or an installed flag.

| Component | Required compiler-derived coverage and preserved behavior |
|---|---|
| Every role input, including disconnected inputs | Owned input range and input staging/finite-value validation, even when no output consumes it. |
| Every role output, including disconnected outputs | Owned output/peak geometry and executable output rows; an unconnected row produces silence, not an omitted node. |
| The optional constant mute, even without consumers | Input materialization rows, scratch ranges and mute operation, including true/unused channels and a wholly disconnected mute. It is not elided because no output observes it. |

These behaviors already appear in the compiler and processor's `stage`,
`materializeMute` and `compute`; the existing plan validator checks lowered
plan consistency, and the proposed full correspondence proof must preserve
them.
Acknowledgement means those components became the installed executable image,
not that samples have run or output was nonzero. Preparation proves neither
lease/context freshness at commit, successful samples, physical deallocation
nor the remaining byte/lifetime obligations.

### 3.1 Proposed executable correspondence proof (#887)

The full proof below remains a proposed obligation, not a persistent descriptor
or a verifier for owned executable components. The compiler does implement an
ephemeral offline-plan consistency validator: it checks endpoint identities,
roles, port directions, sorted channel positions and totals; node coverage;
mute identity and offsets; and output/mute row positions, identity flags,
ordered term occurrences and complete term coverage against the selected
graph. The #890 regression tests exercise rejection of malformed endpoints,
mute geometry, rows and terms. This is more than a count-only check, but it
validates fields in the offline plan; it does not establish charged ownership
or backing-region accounting, correspondence to owned endpoint/peak slabs, a
persistent component-coverage descriptor, or exact execution/custody and
installation. The offline processor executes the lowered plan on supplied
buffers; that offline execution is not target installation or activation.

For the same admitted graph ID/revision and candidate node identities, derive
evidence **as lowering creates the components**, tied to the actual plan and
its geometry rather than a second description of intended nodes. Conceptually
there must be a bijection between candidate nodes and executable components:
exactly one component of the correct kind and identity per node, and no
component without a candidate node. The proof must also account for all
applicable endpoint channels, rows, term occurrences and scratch regions of
those components: none omitted, assigned twice to different components, or
left as extra executable work. Shared source channels may legitimately feed
multiple rows, and repeated source terms in a row are legitimate occurrences;
neither is a duplicate node/component assignment. No particular descriptor
layout or new operation is prescribed.

Use checked half-open ranges within the actual plan bounds, including empty
ranges, and verify the following correspondence:

| Candidate | Identity and executable coverage |
|---|---|
| Role input | Match node, role and graph **output** port, direction and width to its input endpoint. Its unique channel interval matches the owned input slab and the staged-input scratch channels at the plan's fixed frame stride; all channels participate in staging and finite-value validation, whether consumed or not. |
| Role output | Match node, role and graph **input** port, direction and width to its output endpoint. Its unique channel interval matches the owned output slab, peak entries, output scratch channels and exactly one output row per channel. Each row corresponds to that destination channel's admitted incoming edge or its absence. |
| Optional constant mute | Match node, input and output ports, width and constant mute value to the actual mute component. Cover one input materialization row per channel, its input and result scratch channels, and the mute operation over every channel, including when true or unconsumed. No mute component is permitted if no mute node was admitted. |

These processing duties apply to active frames when the corresponding stage is
reached without an earlier refusal. The existing zero-frame path bypasses
staging, mute materialization and output computation.

For example, with frame stride `F`, total input/output channels `I`/`O` and
mute width `C` (zero when absent), the current lowering reserves input scratch
`[0, I*F)`, mute input `[I*F, (I+C)*F)`, mute result
`[(I+C)*F, (I+2C)*F)`, output scratch `[(I+2C)*F, (I+2C+O)*F)`
and `O` peak scratch entries thereafter. Endpoint channel intervals partition
their respective input or output channels; multiplying their bounds by `F`
gives their full fixed-stride slab ranges, including padding. Output rows and
peak entries follow output channel indices; mute rows follow mute channel
indices. The proof checks these ranges against actual counts and offsets, with
checked arithmetic, disjoint component destinations and no gaps or overlaps
where a partition is required. Reserved padding is not a claim that the
processor initializes or processes inactive frames. Empty intervals are valid;
the compiler's minimum scratch allocation for an empty plan is not an extra
node or executable component.

Each row's checked term interval must be within the actual ordered term array;
the mute rows followed by output rows account for all term **occurrences**
without gaps or overlapping ownership. For an absent edge the row has no terms
and produces silence. Otherwise its identity/copy or conversion/sum behavior
and ordered source channel offsets must match the admitted edge and conversion,
including empty conversion rows and repeated indices (an admitted conversion
still has at least one nonempty row). Source references must
resolve to the correct staged input or mute-result channel and stay in the
corresponding scratch range for active frames. This preserves existing lowering
and evaluator behavior, not a claim that the processor independently verifies
the proposed correspondence.

Symbolically, for equal-width `input A -> mute M -> output B`, the proof links
`A` to its input endpoint/staging, `M` to its ports, materialization rows and
mute operation, and `B` to its output endpoint/rows/peaks; each row's terms
refer to the appropriate preceding source. With disconnected `A`, `M` and
`B`, all three components still exist: `A` is staged and validated, `M` has
empty-input rows and executes, and `B` has silent rows. A mute-only graph has
mute work despite empty external geometry; a graph with no nodes has no
components, rows, terms or addressable output/peak geometry. These are
coverage cases, not evidence of installation or sample execution.

Refuse proposed coverage if, for candidate inputs `A` and `B`, two input
components are reported but one actually belongs to `C` instead of `B`, even
if counts and an appended `{A, B}` set match. Also refuse if both
correspondences claim the same actual component for `A`, leaving `B` uncovered,
even when two records and valid-looking ranges are supplied. Likewise, a
correct node ID with another node's port, channel range, row or terms is not
correspondence. These refusals describe the proposed proof obligation. The
current validator does reject malformed plan endpoint identities and
missing/duplicate node coverage in its tested cases, but those checks are not a
persistent proof descriptor or qualification of owned components, backing,
execution or installation.

## 4. Installation and outcome semantics

All installation checks precede any target-state change: exact identity and
eligible custody, complete image/coverage, initialized storage and geometry,
capacity, and the applicable authorization/context checks at eventual
production dispatch. No endpoint allocation or fallible incremental application
may be hidden after selection changes.

**Refusal** preserves the prior installed selection, geometry and sample state.
**Success** selects the complete new image, never a subset. For an eventual
truthful commit report, success applies exactly all planned nodes and leaves
none unapplied; known refusal applies none of the candidate and leaves all its
nodes unapplied. This narrow installation has no partial-application outcome;
do not fabricate partial success to fit the general transaction model.

Processing is a separate operation on the internally selected image. Its
refusals retain their own buffer/silencing semantics; they do not retrospectively
make installation failed or partial. Missing installation or report evidence is
uncertainty, neither invented success nor proof of failure, and cannot release
custody or its charge.

Eventual successful **empty replacement** removes the old installed selection
and current addressable output **and peak geometry**. Old samples cannot remain
current outputs. Previously returned observer copies may remain only as
historical values, not live target storage. Because both report sets are empty
for an empty plan, the sets alone cannot establish that this operation occurred.

## 5. Capacity is not replacement permission

Preserve one charged lifetime across reservation, queued admission,
construction, held/committed/retiring custody and retained completion/destruction
evidence. #288/#290 already implement admission reservation for the
construction-only path; they do not enable successful binding or committed
custody. Canonical and physical/evidence accounting remain the custody record's
single lifetime, not separate allowances.

Replacement semantics, **including empty replacement**, do not permit admitting
B while A remains charged. Only installation into a **vacant target** can be
qualified without a later capacity/retirement decision. Occupied-target
replacement and its evidence obligation remain open; this document specifies
its intended effect, not an available path under today's bound.

A fixture must not seed an uncharged old image, inject canonical success, clear
committed custody or admit B beside A. Initial empty installation and
cleanup-then-empty installation can show empty geometry in a vacant target;
neither proves replacement of a still-installed old image. Authorized release,
consuming cleanup and exact retirement/evidence accounting cannot be replaced
by an assignment that makes capacity appear vacant. Actor serialization does
not establish reader quiescence, and lost evidence retains the charge.

## 6. Future qualification and remaining gates

Future #191/G2/#62/O2 acceptance must establish the narrower charged covered
backing-region accounting of predicate 3.6 and custody section 5, with a justified
basis for every category and enforcement before allocation or authority retention,
including subsequently refused paths and observer creation and retention.
**No supplied basis meets that obligation; allocator-dependent eligibility
implementation remains stopped.** Policy wording alone qualifies no representation.
Recoverable constructor unwind before a failure answer does not promise cleanup
or a terminal answer after fatal allocator exhaustion.

This issue requires documentation and independent source-to-contract review,
not new tests or implementation. Future isolated fixtures must observe actual
selection and subsequent use of the installed image with meaningful nonzero-frame
processing; refusal preservation of selection, geometry and sample state;
disconnected input validation, output silence and mute materialization/operation;
and empty output/peak geometry. An installed flag, node sets, zero-frame-only
processing or caller-buffer evaluation is not installation evidence. Occupied
replacement evidence must wait for the separate decision in section 5.

The #890 compiler-consistency regression tests inspect actual offline-plan
fields and exercise refusal of malformed endpoint identities/positions,
missing or duplicate endpoint coverage, mute geometry, row descriptors and
reordered or duplicated terms. They do not establish the proposed complete
component-coverage proof or its ownership/backing/slab and exact-execution
claims. Future fixtures for that proof must independently compare compiler-
derived coverage to admitted nodes and edges, including connected,
disconnected, mute-only and empty graphs, empty conversion rows and repeated
terms; test missing/extra work and adversarial wrong-component assignments;
and verify any claimed owned ranges. Those observations qualify only the
proposed correspondence proof; installation selection and subsequent use
require the separate evidence above.

A possible later sequence is a persistent full compiler-derived coverage proof
beyond the existing offline-plan consistency validator, concrete owned storage
and isolated installation/use in the existing `HostAuthority.swift` custody
boundary, then separately reviewed successful-binding and cleanup increments.
Names, file placement and fixture interfaces remain proposals, **not
implementation authorization**. Qualification must not use a supplied backend
or expose a resource/borrow to make fixtures pass.
Even a qualified primitive does not authorize installing production candidates
during prepare or publishing from the never-published lifecycle.

Preserve accepted G1 authority, review/authorization and commit-time checks,
canonical identity/custody decisions and legacy behavior. Full #191/G2/#62/O2,
#190 caller proof and nonblocking/allocation/panic-free qualification, and full
#60 remain open. Binding, installation, reclamation, reader departure,
quiescence, stopped-residency and runtime qualification remain separate gates.
No production commit dispatch, render publication/readers,
overlapping lifetimes, recovery/reset execution or quiescence acknowledgement
is implemented or authorized here. No apps, hosted tests, services, production
audio, MIDI, OSC, WING, cloud, plugins or hardware execution is authorized.
