# Workspace UX and contract examples (draft)

Package `contract-ux-draft` · issue #98 · roadmap #48 · status: **design draft for review**.

These are original sketches, flows, state tables and synthetic contract snapshots. They give the
graph, parameter, device and authority owners compatible examples **before** production
integration. They are not Swift types, not a schema and not a decision. Field names illustrate
intent; the owning packages decide the real shapes. Nothing here creates hardware, starts an engine,
sends MIDI/OSC or needs a finished renderer.

## Index

| Document | Surface or flow | Primary owner |
|---|---|---|
| [wiring.md](wiring.md) | Typed wiring: canvas, matrix and list | #101 |
| [perform.md](perform.md) | Performance panels, bindings, pickup, Learn review | #102 |
| [spatial.md](spatial.md) | Placement, speakers, masks, staged calibration | #116 |
| [library-inspector.md](library-inspector.md) | Library sources and the selection inspector | #99 |
| [status-diagnostics.md](status-diagnostics.md) | One status projection, lifecycle, permissions, diagnostics | #99 |
| [host-remote-roles.md](host-remote-roles.md) | Host, remote, observer and assistant roles; epochs | #96 |
| [draft-active-transactions.md](draft-active-transactions.md) | Validate → prepare → review-authorize → commit → acknowledge | #62 |
| [phone-compact-routing.md](phone-compact-routing.md) | Full host routing with lists and pickers on a phone | #101 |
| [examples/](examples/) | Synthetic Project/Graph/Parameter/Device/Transport/Command snapshots and a checker | #54, #55 |

## Principles

1. **Originality.** No screenshots, layouts, icons, templates or wording from other products. The
   wireframes are text. DSP faders and knobs are normal controls; a system-volume guideline does not ban them.
2. **Equivalent paths.** Every drag or canvas gesture has a menu, list, picker, keyboard and
   VoiceOver path. All of these produce the same draft operation. Touch targets are at least 44 pt. Dynamic Type
   reflows the layout instead of truncating it. State is never shown by colour alone. Reduce Motion removes pulsing and animated wires.
3. **Truthful status.** One status projection feeds every surface. Meters come only from measured
   telemetry; otherwise they show **Unavailable**. Fader travel is never shown as signal. **Verified** appears only
   after confirmation. A lost device shows **Lost/Muted**, not uninterrupted audio.
4. **Authority follows role, not screen size.** A phone host is a full host. Layout adapts to the
   screen, but permissions do not change with it (`session.json` → `layoutAdaptations` carries no permissions).
5. **Draft is not active.** Editing, accepting an assistant draft and activation are separate.
   The assistant only proposes. Manual equivalents never require a model.
6. **Safety is always reachable locally.** Panic and Safe Mute appear on every host surface and in every
   lifecycle state, and never need a draft or review. Paired peers are not granted them here; whether a
   remote or observer may trigger them is an open policy question for #94.
7. **Portable is not local.** Project roles (for example "Mains") are portable, inert intent. Device
   routes are confirmed host-local bindings that are not synced. Console connector numbers are not interface channels.
8. **One authority per live graph.** Each host session (Mac or phone) owns its own rig, lease, epoch,
   command log and drafts. Two hosts that open the same project file are two sessions, not one.

## Shared state words

| Word | Meaning | Never implies |
|---|---|---|
| Ready | Node prepared or preparable on this host | Audio is flowing |
| Mapped | Role has a confirmed host-local route | Signal present |
| Unmapped | Role has no route on this host; edits still allowed | Error in the project |
| Missing | Required plugin/device/asset absent; placeholder kept, branch silent | Auto-bypass or substitution |
| Stale | Evidence from an earlier session or epoch | Current truth |
| Lost/Muted | Was running; device lost; outputs muted safely | Survivors boosted |
| Unavailable | No measured value exists (meter, rate, latency) | Zero or silence |
| Draft | Editable change against a base revision | Activation |
| Awaiting review | Validated and prepared; needs an authorized human | Accepted by the assistant |
| Active (rev N) | Committed at a render boundary and acknowledged | Persisted to other hosts |

## Example snapshots

| File | Contract | Owner | Demonstrates |
|---|---|---|---|
| `project.json` | Project | #54 | Portable roles, patches with explicit deltas, legacy authority invalidated, unknown fields kept |
| `graph.json` | Graph | #54 | Typed ports, explicit channel conversion, explicit feedback, missing plugin placeholder, spatial layout |
| `parameters.json` | Parameter | #55 (+#87/#88) | Units/ranges/classes, bindings, encoder profile, pickup waiting, Learn blocked/awaiting review |
| `devices.json` | Device/Capability | #55 (+#65) | Host-local identity evidence, present/missing/stale, required/advisory capabilities, routes |
| `transport.json` | Transport | #55 | Distinct sample/host/tempo/MIDI clocks, host and connection epochs; media deferred to #53 |
| `commands.json` | Command | #55 (+#62) | Classes, stale-epoch rejection, permission rejection, review-only assistant, binding origins |
| `transactions.json` | Transaction trace | #62 | Committed, stale, invalid, prepare-failed and awaiting-review transactions; two assistant provenances |
| `session.json` | Session/status projection | #99 (+#62/#94) | Host A's session: roles, one lease across windows, OS permissions, derived node states, telemetry, diagnostics |
| `phone-host.json` | Separate host session | #62 (+#99/#101) | A phone as its own full host: own rig, lease, epoch, log and draft over the same project file |

These snapshots are **illustrative, not a production model**. Capability definitions are portable
(`graph.json`); each host's rig evaluates them locally. Required capabilities block activation; advisory ones
degrade a node to a silent Missing placeholder.

**IDs** are readable synthetic strings `<prefix>.<slug>` (for example `nod.verb`, `prt.mic.out`).
Each one is defined once across all files. The checker lists the known prefixes. Real encoding (UUID or
typed string) belongs to #54/#55. **Revisions:** each file has `revision` and a strictly increasing
`history`. Every `*Revision` key must name a revision that exists in that contract's history.

Run the checker (stdlib Python 3 only; it reads only these files):

```sh
python3 docs/transformation/workspace-ux/examples/check_examples.py
# OK: 9 contracts, 143 synthetic ids, 2 host sessions, all references and revisions consistent
```

It enforces: object-shaped JSON with `synthetic: true` and unique contract names; unique IDs; resolved
references; integer (never boolean), monotonic revisions and sequence numbers; ports owned by graph nodes; typed
edges (direction, signal, channel maps of integer indices within the source, where an empty row is a silent
channel); no duplicate wires, and cycles only through explicit causal feedback, in the graph and in each draft's
candidate graph; one capability level per capability; one host authority per session (lease, rig, logs, drafts)
using only its own rig, whose route bindings follow device presence and whose capabilities are available only
while a provider is present; step order, outcomes that match their step results (only `awaitingReview` is
pending) and stale-base detection; authorization bound to draft, base, host epoch and diff digest; commits advance
by one, are cited in history and appear in the graph with the same feedback; each operation fits its
[command class and result](draft-active-transactions.md#policy-by-command-class), and draft commands name this
session's draft and carry its exact ops; stale epochs reject every class; permissions come only from roles; a
controller binding sets only its own parameter, held or accepted per its pickup; setter values stay within range
and ceiling; the assistant holds only an allowlist and its drafts carry matching provenance; remotes open no
engine or console write session; a phone runs as a full host; host roles keep Panic and Safe Mute; stale
controllers produce no input; drafts never disable a Perform control; node states follow the Wiring state table
from the host's own rig, and status, meters and diagnostics cite only that rig; measured meters need the running
lease and, on a route, a confirmed binding, else show Unavailable; Learn blocks excluded targets. Malformed input
prints `FAIL` lines, never a traceback.

## Single-owner integration map

Each seam has exactly one owner. Other lanes consume it and do not redefine it. The coordinator keeps
`AppModel*`, `AppRootView`, `MacCommands`, `project.yml`, schema and migration registration, and root composition.

| Seam / surface | Owner | Consumes | Examples |
|---|---|---|---|
| Project identity, roles, patch references, unknown fields | #54 project-graph-contracts | — | `project.json` |
| Graph nodes, typed ports, edges, conversions, feedback | #54 | — | `graph.json` |
| Patches and variation deltas, shared instances | #104 patch-variation-global | #54 IDs, #55 parameter IDs | `project.json` `patches` |
| Parameter catalog, classes, ranges, values | #55 device-parameter-transport-contracts | #54 node IDs | `parameters.json` |
| Bindings, pickup, encoder profiles | #87 general-control-bindings | #55 | `parameters.json` `bindings` |
| Learn sessions and review | #88 control-learn-feedback | #87 | `parameters.json` `learn` |
| Device/capability contract, host-local routes | #55 | #54 roles | `devices.json` |
| Discovery evidence, presence, loss | #65 device-backends-lifecycle | #55 | `devices.json` `devices` |
| Clocks and epochs | #55 | — | `transport.json` |
| Media timing, cues, quantization, fidelity | #53 media-clock-fidelity-contracts (**reference only here**) | — | none |
| Command envelope, classes, results | #55 | — | `commands.json` |
| Validation, authorization, transactions, engine lease, safety path | #62 host-authority-transactions | #54, #55 | `transactions.json`, `session.json` `lease` |
| Meter taps in the compiled render plan | #66 graph-compiler-dsp | #62 lease | `session.json` `telemetry` `source` |
| Telemetry transport: bounded buffers and event queues to the UI | #64 render-buffers-queues | #66 | `session.json` `telemetry` |
| External send/return insert node (legacy `.effect`), loopback compensation | #68 send-return-compensation | #54 | Mapping table below |
| Timed automation of parameters and spatial motion | #108 automation-gestures | #55, #53 | `spatial.md` Timing |
| Shell, status projection, Edit/Perform policy, inspector container, Library container, Panic/Safe Mute placement | #99 workspace-navigation-accessibility | #62, #65, #66 | `session.json` |
| Rig wizard, mapping unmapped roles | #100 interface-rig-wizard | #55, #65 | `devices.json` `routes` |
| Wiring surface, matrix/list, diffs, phone compact routing | #101 typed-wiring-editor | #54, #62 | `graph.json`, `transactions.json` |
| Perform panels, meters display | #102 performance-panels | #55, #87, #88, #64 | `parameters.json`, `session.json` |
| Spatial model adapter (sources, speakers, routes) | #114 spatial-neutral-adapter | #54, #55 | `graph.json` `spatial`, `devices.json` |
| Spatial DSP: bounded DBAP, masks without renormalization, calibration signals | #115 spatial-dsp-calibration | #114, #62 | `graph.json` `spatial.masks` |
| Spatial placement/calibration UI | #116 spatial-ui-motion | #114, #115 | `graph.json` `spatial` |
| Plugin catalog content shown in Library | #70 plugin-catalog-scan | #55 | `devices.json` `capabilities` |
| Plugin editor and opaque state behind Inspector Replace | #77 plugin-editors-snapshots | #70 | `library-inspector.md` |
| Pairing, trust, scoped permissions, peer safety policy | #94 peer-pairing-permissions | #62 | `session.json` `roles`, `safety` |
| Peer snapshot and command freshness | #95 peer-contract-sync-commands | #54, #55, #62 | `commands.json` |
| Remote controller mode | #96 remote-controller-role | #94, #95 | `session.json` |
| Reconnect and stale-queue drop | #97 peer-reconnect-backpressure | #95 | `transport.json` `connections` |
| Read-only assistant snapshots and tools | #118 local-ai-snapshot-tools | #54, #55 | `session.json` `diagnostics` |
| Routing semantics into neutral proposals | #37 semantic-assistant-review | #118, #62 | `transactions.json` `dft.assistant-cue` |
| Assistant explanation and diff review UI | #119 assistant-review-diagnostics | #37, #99 | `status-diagnostics.md` |
| Deterministic doubles; they follow the #54/#55 schemas once frozen, not these drafts | #58 contract-fixtures | #54, #55 | all (illustrative) |
| Persisting drafts and provenance; versioned legacy migration | #122 versioned-project-storage | #54 | `project.json` `legacy` |
| Coordinated saves across host sessions, checkpoints, undo, recovery | #123 coordinated-save-recovery | #122, #62 | `phone-host.json` `authorityNote` |

## Mapping from the current app (compatibility, read-only)

| Current code (main @ 9cfa1ec) | Draft concept |
|---|---|
| `StudioPortRef {nodeID, side, port: Int}` | Stable ID `prt.<node>.<in|out><index>`, labelled from `Equipment` jack names. Legacy data has no channel counts, so imported ports stay inert until review confirms counts |
| `StudioNodeKind.instrument(Equipment.ID)` | `roleInput` node for a portable role; its console input numbers become host-local evidence |
| `StudioNodeKind.effect(Effect.ID)` (outboard send/return jacks, `Effect.swift:18-30`) | `externalInsert` node with send and return ports; compensation is #68's seam; serial chains become explicit edges |
| `StudioNodeKind.liveChannel` (not routable) | `observedShortcut`, `routable: false`, state Stale |
| `StudioEndpointDestination` `.finalMix/.space/.custom` | `roleOutput` / `spatialBus` nodes that point at portable roles |
| `StudioEndpoint.outputConnectors: [WingOutputConnector]` | Console evidence on `dev.console` only, never route channels (#48: "WING Local numbers are not USB channels") |
| `StudioRoutingIssue.Kind` (`missingNode`, `invalidDirection`, `nonroutableLiveChannel`, `missingEndpoint`, `unfinishedBranch`, `cycle`) | Validate diagnostics with the same meanings; a cycle is allowed only with explicit feedback |
| `StudioResourceAllocator` bus pairs, `SpatialRouting` sends | Compile details (bus pairs #66, spatial sends #114); never in the portable graph |
| `GlobalStudioConnections` Home + `TemporaryDeviceMove` (`planned`/`readyToApply`/`active`/`readyToReturn`) | Portable roles vs confirmed host-local routes with the same four lifecycle states |
| `Speaker`/`SpatialSource` positions in 0…1, Front L at (0,0), y toward the rear | x′ = 2x − 1, y′ = 1 − 2y; unit constants rescaled ([spatial.md](spatial.md#legacy-coordinate-transform)) |
| Stereo `SpatialSource` (`left`/`right` `WingNodeRef`, `width`) | One source on a 2-channel port; both refs become console evidence on its inert input; width kept |
| `StudioApplyStatusView` "Listen on WING" + verified/partial/failed | Commit + acknowledge with truthful partial outcomes; #62 replaces the UI-only guard |
| `PendingStudioPatchReviewView` Accept/Replace (no write) | Accepting a draft is still separate from activation |
| `StudioConnectNodesMenu` | Generalized From/To port pickers ([phone-compact-routing.md](phone-compact-routing.md)) |
| `MeterView(level: position)` in `FaderStripView` | Fader travel only; signal meter shows Unavailable until measured telemetry arrives (#66 taps, #64 transport) |

## Open questions for coordinators

Graph (#54): (1) UUID or typed-string IDs, and are port IDs scoped under nodes? (2) Should explicit conversion
be an edge attribute (as here) or a conversion node? (3) Should feedback be an edge attribute with a delay, or a
dedicated delay node? (4) Do roles live in Project (as here) or Graph? (5) Should drafts be op lists (as here)
or snapshot plus diff, and are revisions per graph or per project? (6) Should the spatial layout stay inside
Graph or become its own contract (#114)? (7) Should observed console shortcuts stay graph nodes or become
UI annotations?

Device/parameter (#55): (1) Is there one parameter revision stream per project, or one per node? (2) Is the live/structural/hazardous
class set on the parameter or on the command? (3) Do epochs use host + connection only, or also a lease generation?
(4) What vocabulary describes identity evidence and Stale versus Missing? (5) Which staleness window turns
telemetry into Unavailable? (6) Do capability matches work by count ("≥ 3 inputs") or by exact layout? (7) Does pickup
state belong to bindings (#87) or to the parameter value?

Authority (#62/#94/#123): (1) May a paired remote or observer trigger Panic/Safe Mute at all, and does the
freshness rule then apply (`cmd.0007` is rejected as stale here)? Not granted in these examples (#94). (2) When two
host sessions open the same project file, how does a coordinated save report a stale base (#123)? (3) Is
`externalInsert` a #54 node kind, with #68 owning only compensation?
