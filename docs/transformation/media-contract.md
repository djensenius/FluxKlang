# G-MEDIA: media clock, scheduling and fidelity contract (v1)

| Field | Value |
|---|---|
| Contract | `fluxklang.media` |
| Version | `1` (integer major version; see [§12](#12-versioning-and-compatibility)) |
| Gate | G-MEDIA, issue #53 (roadmap #48). Must be accepted before the #54/#55 schema freeze |
| Status | **Proposed**. Becomes **Accepted v1** when this PR merges after coordinator review. #54 and #55 then adopt the accepted v1; later changes follow [§12](#12-versioning-and-compatibility) |
| Owners | This document: #53. Production types: #55 (stamps, generations, commands) and #54 (persisted media references) |
| Machine-readable form | [`media-contract/media-contract-v1.schema.json`](media-contract/media-contract-v1.schema.json) and [`media-contract/examples/`](media-contract/examples/) |
| Validation | `python3 docs/transformation/media-contract/check_media_contract.py` (standard library only; [§15](#15-examples-and-validation)) |

This contract fixes the media meaning the graph, transport and performance work must share. It distils the research
already recorded in #48 ("Plugins, patches and shows", "Runtime and latency", "Contracts and authority"), #53 and
#109–#112, plus the primary sources in [§16](#16-sources). It defines **values, rules and policies only**. Swift
types, queues and adapters belong to their owners ([§11](#11-ownership-and-adoption-notes)). Nothing here depends on
playback, recording or backend selection being finished.

## 1. Scope

In scope: plain clock stamps and generations; sample, host and musical anchors; event ordering, quantization and
cancellation; loop, seek and tempo mutation policy; readiness of preloaded actions; bounded prefetch and capture
ownership, and discontinuities; and MIDI container versus actual protocol fidelity, native capture, and visible lossy
SMF export.

The kernel contract names no Foundation objects and no specific engine. AVAudioTime, AVAudioPlayerNode, AVAudioFile
and CoreMIDI stay behind adapters ([§10](#10-adapter-boundary)).

## 2. Terminology

| Term | Meaning |
|---|---|
| Sample clock | A device-driven frame counter (`Int64` frames) with an identity (`clockId`) and a generation; each generation has its own nominal rate. It is the render timeline |
| Host clock | The monotonic process clock in host ticks (`UInt64`) with a timebase `numer/denom` (ns per tick). Process-local; it does not advance during sleep |
| Musical time | Ticks (`Int64`) at a fixed **15360 ticks per quarter note** (TPQ). A beat is a quarter note. Converted to frames only through the musical map and an anchor |
| Musical map | `(atTicks, microsPerQuarter)` segments from tick 0 with strictly increasing `atTicks` (initial map and every revision), plus one meter. One revision covers both; an absent meter is inherited |
| Console setup | Device selection, routing, buffer size and gain. It is configuration, **not a clock**; changing it may bump the sample clock generation |
| Anchor | One simultaneous observation of `(sample clock, generation, frame, hostTicks)`, optionally with `(transport generation, musicalTicks, loopIteration)` |
| Generation | A counter that names an epoch of meaning (see [§5.1](#51-generation-counters)) |
| Owned note | A note started by a transport-synchronised playback stream (clip, sequence or preloaded action) and not yet released. Live-input notes, routed or held notes, and patch tails are **not** owned; their release belongs to #82 and #105 |
| Trigger | A stamped request to perform a prepared action: origin host time, the horizon at arrival, the generations it requires, and a target |
| Origin | The host time of the human or remote intent (`originHostTicks`) |
| Horizon | The earliest frame the scheduler can still affect. A trigger's `horizonFrame` records it at arrival; it continues advancing while the trigger is pending (§6.1) |
| Assigned frame | The frame the quantized target resolves to. Late if it precedes the **current** horizon at commit |
| Pending, committed | A trigger is **pending** until its outcome. A `fired`, `firedLate` or `joined` outcome **commits** it: its frame is final and it goes to the render queue. Before committing, the scheduler rechecks the current horizon and applies the late policy if needed; earlier look-ahead is owned by #84 and #107. Only pending targets re-resolve (M6) or are cancelled (M4). A committed event whose generation changes before it renders is discarded, never retargeted |
| Outcome | The single terminal result of a trigger: `fired`, `firedLate`, `joined`, `cancelled`, `rejectedStale` or `dropped` |
| Readiness | The preparation state of an action: `unprepared`, `preparing`, `ready`, `invalidated` or `failed` |
| Stream | An ordered event or sample source with a prepare-time `ordinal` (`audio`, `midi` or `state`; playback or capture) |
| Discontinuity | A recorded break in continuity (restart, jump, underrun, overflow, loss, locate, wrap, format change, stop) |
| Container | How MIDI bytes are carried: UMP words, MIDI 1.0 bytes or SMF |
| Effective protocol | The protocol the source actually produced (`midi1` or `midi2`). It is independent of the container |
| Take / segment | A capture. A take has one segment per sample clock generation |

## 3. Plain values

Kernel values are fixed-size and trivially copyable. They use no strings, Foundation types, reference counting or
allocation. Identities are dense `UInt32` slots resolved at prepare time. String IDs such as `smp.main` appear only
in persisted, debug and example forms. Clock, stream, action, trigger, take and export IDs are unique: a duplicate is
invalid, never overwritten. These semantics are normative; the field widths below and the ring layout in
[§8.2](#82-prefetch-109) are advisory for #55, #64 and #109.

| Value | Fields (width) |
|---|---|
| `SampleStamp` | `clock` (UInt32 slot), `generation` (UInt64), `frame` (Int64) |
| `HostStamp` | `ticks` (UInt64). The timebase `numer/denom` (UInt32 each) is process-wide, not per stamp |
| `MusicalStamp` | `transport` generation (UInt64), `musicalMap` revision (UInt64), `ticks` (Int64), `loopIteration` (UInt32) |
| `ClockAnchor` | `SampleStamp`, `HostStamp`, optional `MusicalStamp` |
| `GenerationKey` | `kind` (UInt8: sampleClock, transport, musicalMap, source, context, cancelScope), `slot` (UInt32) |
| `TriggerStamp` | `triggerId` (UInt64), `action` slot, `originHost`, `horizonFrame` (Int64), `requires` (bounded array of ≤ 8 `(GenerationKey, UInt64)`), `target` |
| `Target` | `timeBase` (musical, sample or asap), `gridTicks`, `atTicks` or `atFrame` |
| `Outcome` | `triggerId`, `result` (UInt8), `reason` (UInt8), `assignedFrame`, `frame`, `startOffsetFrames` (Int64), `musicalMap` revision |
| `Discontinuity` | `type` (UInt8), `SampleStamp`, `frames` (UInt32, optional), `stream` slot, optional `HostStamp`; `previousFrame` (Int64) on `clockRestart` and `reason` (UInt8) on `captureStopped` only |

## 4. Invariants

The checker enforces these invariants on every example. Markers: ✔ checked, ◐ partly checked, — documented only.

| ID | Invariant | |
|---|---|---|
| M1 | Audio sample clock, host clock, musical time and console setup are distinct domains. Values never convert implicitly. Conversion goes only through an anchor of the **current** generations | ✔ |
| M2 | Generations start at 1, advance by exactly 1, are never reused, and are compared only for equality | ✔ |
| M3 | Every trigger carries its origin host time, its horizon and the generations it depends on. Musical-map revisions are never dependencies | ✔ |
| M4 | A trigger whose required generation changed is never fired, deferred, retargeted or replayed. It is `cancelled` if pending and `rejectedStale` if it arrived stale | ✔ |
| M5 | Every accepted trigger receives exactly one terminal outcome. Its outcome slot is reserved when it is accepted, so the bounded outcome channel never drops. With no free slot, submit refuses synchronously with `capacity`: no trigger is accepted and no outcome is emitted | ◐ |
| M6 | Pending (uncommitted, [§2](#2-terminology)) musical targets re-resolve against the current musical map. A tempo or meter edit cancels nothing | ✔ |
| M7 | An action fires only if it was `ready` when triggered and stayed `ready` until dispatch. Nothing is loaded, allocated or decoded at fire time | ✔ |
| M8 | Prefetch and capture use preallocated, bounded single-producer/single-consumer handoffs. The render thread never blocks, allocates or performs I/O | ◐ |
| M9 | Every loss of continuity is recorded as a discontinuity with its frame and count. Underruns and overflows are never silent | ✔ |
| M10 | MIDI fidelity reports what the source actually sent; an unknown endpoint protocol is reported as unverified MIDI 1. Conversion loss and unverifiable fidelity are always declared, never hidden | ✔ |
| M11 | Native timing objects and engine APIs stay in adapters. The kernel contract has no Foundation or engine types | — |
| M12 | Fixed-rate audio is the default. Tempo-following MIDI and time-stretched audio are explicit, distinct policies. Stretching never happens silently | ✔ |
| M13 | Host-tick stamps are transient runtime data and are never persisted. Persisted media stores frames, musical ticks and nanosecond offsets from a recorded anchor (takes: `startOffsetNs`; native exports: `offsetsNs` from their `origin`) | ✔ |

## 5. Generations and mutation policy

### 5.1 Generation counters

Counters are keyed `kind/id` (for example `transport/mus.main`). Owners are in brackets.

| Kind | Bumped by (reason) | Effect on dependants |
|---|---|---|
| `sampleClock` [#65, #55] | `deviceRestart`, `rateChange` (carries the new `nominalRate`; others may, else inherit), `configurationChange`, `wake` | Pending triggers cancelled. Old anchors void. Forces a `transport` bump (`clockRestart`) |
| `transport` [#84, #55] | `locate`, `clockRestart`, `transportRestart` | Pending musical triggers, including `nextBoundary` fallback, cancelled. [Owned notes](#2-terminology) released. Musical anchor void until re-anchored |
| `musicalMap` [#84] | `tempoEdit`, `externalTempo` (rate-limited) | Pending musical targets re-resolve. **Nothing is cancelled** |
| `source` [#109, #81] | `sourceLost`, `sourceReacquired` | Dependent triggers cancelled. Readiness invalidated |
| `context` [#62, #55] | `contextChange` (activation or engine lease) | Pending triggers cancelled. Old-context triggers rejected |
| `cancelScope` [#107] | `userCancel` | Pending triggers in the scope cancelled |

Two changes are **not** generations. A loop wrap increments `loopIteration`. A sample jump within a continuous
device mapping is a `sampleJump` discontinuity.

### 5.2 Anchors and conversion

- An anchor is valid only while its sample generation (and, for musical fields, its transport generation) is current.
- `frame(host) = anchor.frame + (host − anchor.host) · (numer/denom) · rate / 10⁹`. `rate` is the nominal rate of the
  anchor's generation, used between anchors. Adapters re-anchor at least once per render cycle in which they observe
  both values.
- Musical ticks to frames: integrate the musical map from the anchor in effect: for a frame, the latest musical anchor
  at or before it (else the first); for a target, the latest anchor of its loop pass ([§5.5](#55-loop)). Frames to
  ticks is the exact inverse, so a frame before the anchor crosses earlier tempo segments. Round half-up
  (`floor(x + ½)`) only at the final frame or tick.
- Within one generation, anchors must advance, and each must agree with the frame predicted from the generation's
  **first** anchor at the nominal rate within `(rate + span) / 1000` frames, where `span` is the predicted frame
  count: 1 ms of observation jitter plus 0.1% of the elapsed span. Jitter never accumulates against the first anchor,
  but a real rate change does. The checker applies exactly this bound, in exact arithmetic.
- A device-reported rate change is authoritative and always bumps `sampleClock` (`rateChange`). An unreported
  disagreement beyond the bound is treated the same way.

### 5.3 Clock restart

The policy for a device restart, rate change, configuration change or wake:

1. Bump `sampleClock` and record a `clockRestart` discontinuity before the first anchor of the new generation. It
   carries the new generation's start `hostTicks` and `previousFrame`, the end of the frames rendered in the old one.
   Each change has its own record and any step-3 bump; changing that clock again before they exist is invalid.
2. Cancel every pending trigger that required the old generation.
3. Bump `transport` (`clockRestart`), before or after the `clockRestart` record: exactly once per primary
   `sampleClock` bump when a transport exists, and never otherwise. The transport resumes at the musical
   position of `previousFrame`, the last **rendered** position, converted through the musical anchor and map in force
   at the `sampleClock` bump (so at the old rate; a `previousFrame` at loop end resumes at `startTicks`), with
   `loopIteration` 0. There is no catch-up.
4. Re-anchor. The first new anchor is not before the restart's `(frame, hostTicks)` and agrees with it at the new
   rate within the §5.2 bound, `span` measured from the restart (examples 01, 08). Late triggers stamped with the old
   generation are `rejectedStale` (example 01: 48 → 96 kHz).

### 5.4 Seek (locate)

A locate bumps `transport` and records a `locate` discontinuity at the frame where it takes effect. The `release` lane
then turns off every owned note, and affected audio prefetch is invalidated and re-prepared. The transport re-anchors
at the new position with `loopIteration` 0 (example 03), superseding any pending clock-restart resume position.

### 5.5 Loop

A loop is `[startTicks, endTicks)`, with `startTicks < endTicks`. At the wrap frame (exactly `endTicks` through the
pass's anchor, rounded as in §5.2) the transport records a `loopWrap` discontinuity, re-anchors with `musicalTicks =
startTicks` and `loopIteration + 1`, and dispatches owned-note releases first ([§6.5](#65-ordering)). A pass anchored
past `endTicks` does not wrap. A position resolves through the anchor in effect at its frame, so an event before the
wrap keeps its pass even when delivered after the wrap anchor. A scheduled target is an **occurrence**: the pass
holding its origin, plus its ticks. A wrap never moves it; musical-map revisions re-resolve it within its pass. A grid
boundary equal to `endTicks` is the wrap frame, and later ones continue on the next pass's grid (example 03). In v1,
musical targets must resolve inside `[startTicks, endTicks]` while a loop is active ([§14](#14-open-questions)).

Virtual future passes use the same per-wrap rounding as recorded wraps: full passes advance by the rounded
loop duration, not an accumulated unrounded duration. A zero-rounded duration still permits representable
current-pass and first-wrap boundaries; a search requiring a later frame fails explicitly rather than
dividing by zero, walking passes indefinitely or narrowing valid loop bounds. Grid arithmetic stays exact
through the full declared tick range. Musical positions, map/loop tick fields and grids stay in the nonnegative
`Int64` domain. An unrepresentable anchor/capture tick or rounded restart resume tick is diagnosed before publishing
its timing state; replay continues checking later independent sample/ASAP records. An invalid musical-map revision
does not publish its new generation or map.

For frame projection only, `(pass, endTicks)` aliases `(pass + 1, startTicks)` when the selected pass anchor is
at or before `endTicks`. A pass anchored past the end does not wrap or alias. This deterministic boundary alias
does not change the stored occurrence or substitute the currently running pass for a historical one.

Quantized origins retain their exact frame fraction until pass classification and grid selection. The interval
after an unrounded loop end but before its rounded wrap still belongs to the original pass: its upcoming wrap
boundary is considered before retroactive selection, never mistaken for a past boundary.
When that upcoming end is on-grid, retroactivity tests the preceding admissible boundary instead. A past-end
anchor's previous-boundary search starts at the loop end. An unrepresentable `Int64` boundary is a controlled
resolution failure, not a wider tick domain; it does not prevent an otherwise valid retroactive choice.
A later re-anchor can move grid lines in either direction relative to the origin. Each examined pass compares
the latest anchor's inverse-projected grid boundary with its separately qualified end alias. The closest
nonfuture projection wins; an interior boundary wins an equal-frame tie rather than inventing a future wrap.
Eligible retained earlier passes are compared too: re-anchors and map edits can make their projections closer
than an origin-pass match. Virtual candidates are bounded using the latest inverse and per-wrap rounding,
never by walking the number of elapsed passes or grid ticks.
An assignment is retroactive only when its projected frame is strictly before the exact origin, regardless
of equality with the origin-time tick.

### 5.6 Tempo and meter

A musical-map edit bumps `musicalMap` and carries the whole new tempo map plus an optional `meter` (inherited when
absent; in v1 one meter applies to the whole map, and it only labels bars because targets are ticks). Committed events
keep their frames; pending musical targets re-resolve with the new map, and their outcome names the revision used
(example 04). External tempo (#84) is rate-limited so it cannot cause unbounded re-resolution. Fixed-rate audio keeps
its sample length; a tempo mismatch is advisory.

Before commit, occurrence identity is frozen, not a physical sample frame. While running, resolve with the
current map and latest valid running anchor of the projection pass, including the loop-end alias above.
A same-pass resume may change `assignedFrame` through backward projection from its resume anchor. That frame
is a timing-policy reference, not evidence that the transport physically traversed the tick then; actual
dispatch remains constrained by the commit horizon. Only committed events retain their committed frames.
The v1 trace format/checker does not encode stop/resume transitions, so this rule does not establish validation
of a complete pause trace or introduce new v1 records.

### 5.7 Source loss

A lost file, volume, device or endpoint bumps `source`, records `sourceLost` on the stream, and invalidates
dependent readiness. Reacquisition is a new generation (`sourceReacquired`) recorded as `sourceRestored`, and it
requires re-preparation. Triggers stamped before the loss never replay (example 05).

### 5.8 Context changes and user cancel

`contextChange` (#62) covers a new activation or engine lease, and `userCancel` (#107) a cancelled set or scene.
Both cancel pending triggers and reject late stale ones (example 06).

## 6. Scheduling

### 6.1 Horizon

The scheduler publishes `horizonFrame`, the earliest frame it can still affect: at least the next render cycle plus
any adapter latency. A target is **late** if it precedes the horizon at commit, not at arrival; `asap` commits at that
horizon. Traces lower-bound it by the primary anchor frames and trigger `horizonFrame`s of the current primary sample
generation; only a primary `sampleClock` change resets it, not a locate, wrap or map edit.

### 6.2 Quantization

A `musical` target has exactly one of `gridTicks` (the next boundary at or after the origin, which an exact boundary
uses) or an absolute `atTicks`; a `sample` target has `atFrame`; an `asap` target has neither (schema-enforced). When
stopped, the action's stopped policy applies: `wait` (default), `immediate` or `startTransport`.

### 6.3 Late and retroactive cues

| Policy | When late (`assignedFrame < current horizon`) |
|---|---|
| `drop` | `dropped`, reason `late` |
| `fireLate` | If lateness ≤ `maxLatenessMs`: `firedLate` at the horizon. Otherwise `dropped` (`late`) |
| `joinInProgress` | If lateness ≤ `maxLatenessMs`: `joined` at the horizon with `startOffsetFrames = horizon − assigned`, so the source stays aligned. Otherwise `dropped` (`late`) |
| `nextBoundary` | `fired` at the first boundary at or after the horizon on the trigger's resolved grid (its `gridTicks`, else the action's). Requires a musical grid and anchor; the outcome names the musical-map revision used. The trigger requires `transport` even with a `sample` or `asap` target, so a locate cancels it |

**Retroactive tolerance.** `retroactiveMs` ranges over 0–120, defaults to 0, must not exceed `maxLatenessMs`, and
is allowed only with `fireLate` and `joinInProgress`. If the origin is within the tolerance after the previous grid
boundary, the trigger is assigned to that boundary (example 02, trg.1); outside the window it takes the next one
(trg.2). A retroactive assignment is late, so `maxLatenessMs` still decides its outcome as in the table above.

### 6.4 Outcomes and precedence

The checker evaluates a trigger's outcome in this order:

1. `rejectedStale` if it arrived with a stale required generation.
2. `cancelled` if a required generation changed while it was pending.
3. `dropped` (`notReady`) if the action was not continuously `ready`; its target need never be resolved.
4. The timing policy.

`notReady` has one v1 policy, `dropAndReport`; deferral is an open question for #107. `capacity` is not an outcome:
it is the synchronous refusal of submit when no outcome slot is free, so a trace has neither a trigger nor an outcome
for it (M5). No outcome is ever followed by a second outcome or a replay.

### 6.5 Ordering

Dispatched events are ordered by **(frame, lane, streamOrdinal, streamSeq)**:

| Lane | Rank | Contents |
|---|---|---|
| `release` | 0 | System releases: [owned-note](#2-terminology) note-offs at wrap, locate or stop, and panic |
| `transport` | 1 | Transport state and position changes |
| `state` | 2 | Prepared parameter, program and recall changes |
| `content` | 3 | Stream content (notes, clips) in source order |

Source order within a stream is preserved (`streamSeq` strictly increases, across clock restarts too). Frame order
restarts when the primary sample clock changes generation. Ordinals are fixed at prepare time.

## 7. Readiness

| From | Allowed to |
|---|---|
| `unprepared` | `preparing` |
| `preparing` | `ready`, `failed`, `unprepared` |
| `ready` | `invalidated`, `unprepared` |
| `invalidated` | `preparing`, `unprepared` |
| `failed` | `preparing`, `unprepared` |

`ready` means every resource the action needs is resident: the prefetch head, decoded state and stream ordinals.
`failed` and `invalidated` carry a reason (for example `timeStretchUnavailable`, `memoryPressure`, `assetChanged` or
`sourceLost`). "Armed" is a derived UI state (ready plus a pending trigger), not a readiness state. A trigger that
arrives while its action is not `ready`, or whose action leaves `ready` while it is pending, is `dropped` with reason
`notReady` (example 07).

## 8. Audio policies, prefetch and capture

### 8.1 Time policies

| Media | Allowed `timePolicy` | Default for new actions |
|---|---|---|
| audio | `fixedRate`, `timeStretch` | `fixedRate` (sample-rate conversion is not stretching) |
| midi | `tempoFollowing`, `fixedRate` | `tempoFollowing` |
| state, transport | none | — |

Persisted audio and MIDI actions always state their `timePolicy`, so a future default change can never alter a saved
show. `timeStretch` needs an adapter that declares `adapterCapabilities.timeStretch`. Without one, the action is
never `ready` (not even initially): readiness fails with `timeStretchUnavailable`, and there is no silent fixed-rate
fallback (example 04).

### 8.2 Prefetch (#109)

- Each audio source voice owns an SPSC ring of preallocated pool blocks: `blockFrames × blockCount ≥ headFrames`.
- Blocks carry the source generation and read generation. Stale blocks are discarded, never played.
- On underrun the voice outputs silence, skips the missing source frames to stay aligned, and records `underrun`
  with a frame count (example 05).

### 8.3 Capture (#109, #110)

- Each consumer gets its own handoff. One tap never feeds two racing SPSC consumers.
- Overflow never blocks. Dropped frames are padded with silence in the file and recorded as `overflow`. A take's
  `droppedFrames` equals the sum of its padded frames.
- A sample clock restart starts a new segment, with no padding across restarts: a segment continuing across it ends at
  its `previousFrame`, padded overflow included, and the next starts at the restart's frame. No segment, the last
  included, ends after its generation's `previousFrame`. Every overflow interval lies wholly inside its segment. A
  segment's frames are at its generation's own rate (example 08 goes from 48 to 96 kHz). Each segment stores
  `startOffsetNs`, the nanosecond offset of its anchored start from the first segment's (the take's anchor), never
  absolute host ticks (M13).
- Disk full records `captureStopped` at the end of the last segment and leaves a recoverable partial file
  (example 08).
- A take owns only the overflow and `captureStopped` records on its stream that touch its own segments (same clock
  generation, overlapping frames), so earlier and later takes never count. A `captureStopped` it owns must match its
  `stopReason`: a `user` stop owns none; any other owns exactly one, at the end of its last segment (example 08 `tk.2`).

### 8.4 Discontinuity kinds

| Type | Meaning | Required data |
|---|---|---|
| `clockRestart` | New sample clock generation begins | new generation, `hostTicks`, `previousFrame` |
| `sampleJump` | Frame jump within a continuous device mapping | frame |
| `underrun` | Playback ran out of prefetched data | playback stream, `frames` |
| `overflow` | Capture handoff full; frames padded | capture stream, `frames` |
| `sourceLost`, `sourceRestored` | Source availability changed (one per `source` bump) | stream |
| `locate` | Transport jumped (one per `locate` bump) | frame |
| `loopWrap` | Loop iteration boundary | frame |
| `formatChange` | Stream format or MIDI protocol changed (for example after MIDI-CI) | stream, before the next capture |
| `captureStopped` | Capture ended for a non-user reason | stream, `reason` (`diskFull` or `deviceLost`) |

### 8.5 Latency

Input latency is reported as `reportedFrames` (device or OS claim) and `measuredFrames` (loopback measurement, or
`null`). A measured value must cite its evidence. Reported latency is never presented as measured.

## 9. MIDI fidelity and export

### 9.1 Container versus effective protocol

An input port receives the protocol it was created with; the header says only that CoreMIDI "will automatically
convert to this protocol as needed" (`MIDIServices.h`). The endpoint's native protocol is `kMIDIPropertyProtocolID`,
documented as a UMP-native property that can change after MIDI-CI negotiation. Rules:

- `endpointProtocol` is that property. When it is missing or unrecognised it is `unknown`: the capture is treated as
  `midi1` for every derived field and carries `verified: false`.
- *Derived, not documented:* `translatedBy = os` exactly when the endpoint protocol (`unknown` counts as `midi1`)
  differs from `portProtocol`, otherwise `none`. #81 and #83 verify this ([§14](#14-open-questions), question 8).
- Every message from an endpoint that is not `midi2` is effective `midi1`, whatever its type. MT 0x2 (MIDI 1.0
  channel voice in UMP) is always effective `midi1`.
- Channel voice arrives in the port's protocol: MT 0x4 on a `midi2` port, MT 0x2 on a `midi1` port.
- MT 0x4 (MIDI 2.0 channel voice) is effective `midi2` **only** when the endpoint protocol is `midi2`; otherwise it
  is OS-upscaled MIDI 1.0 and effective `midi1`.
- Effective protocol comes from the endpoint property, never from inspecting values.
- A change of endpoint or port protocol on a stream records a `formatChange` discontinuity on that stream before
  its next capture.

| Endpoint | Port | translatedBy | Words received | Effective | Example |
|---|---|---|---|---|---|
| midi1 | midi1 | none | MT2 | midi1 | 09 (`str.keys-a`) |
| midi1 | midi2 | os | MT4 (upscaled) | midi1 | 09 (`str.keys-b`) |
| midi2 | midi2 | none | MT4 | midi2 | 10 (`str.synth`) |
| midi2 | midi1 | os | MT2 (downscaled before we see it) | midi1 | 10 (`str.synth-legacy`) |
| unknown | midi2 | os (assumed) | MT4 | midi1, `verified: false` | 10 (`str.synth-unknown`) |

### 9.2 Native capture

Capture stores the UMP words verbatim, plus host ticks, the derived frame (through the current anchor) and musical
ticks exactly when a transport is anchored, plus the protocol fields above. These host-tick stamps are transient
runtime data. A capture delivered after a `clockRestart` or locate but stamped before it is unsupported in v1: it is
reported, neither remapped through the new anchor nor silently dropped, and nothing containing it claims to be
lossless (recovery: #110, #112). Delayed delivery within a generation is supported (examples 03, 04). Otherwise
`nativeUmp` export is lossless: it keeps the words verbatim and persists `offsetsNs` from its `origin` (the take start
as clock, generation and frame, bound to that generation's recorded anchor, so a later restart changes nothing). Any
Jitter Reduction timestamps it writes derive from them; it never writes absolute host ticks.

### 9.3 SMF export losses

SMF (RP-001) carries MIDI 1.0 bytes. Every export selects distinct, declared MIDI capture streams. Export computes
and declares every loss. `lossless` is true exactly when `losses` is empty.

| Category | Counted when |
|---|---|
| `timingQuantized` | The event's exact capture position, rounded half-up to `division`, maps back through the same capture-time anchor ([§5.2](#52-anchors-and-conversion)) and map to a different frame (rounded `musicalTicks` can hide this). `division` must divide 15360 |
| `syntheticTempoMap` | An event has no musical stamp, so export must invent a tempo map |
| `velocityDownscaled` | A genuine MIDI 2.0 note velocity is not the min-centre-max upscale of its top 7 bits (independent of the remap below: `0x0100` counts in both) |
| `noteOnVelocityRemapped` | A genuine MIDI 2.0 Note On's 7-bit velocity is 0, so it is sent as 1 (not Note Off) |
| `valueDownscaled` | A genuine 32-bit value (poly pressure, CC, channel pressure, RPN/NRPN data, pitch bend) does not survive reduction to 7 or 14 bits |
| `attributeDropped` | A Note On or Off has an attribute type ≠ 0 |
| `perNoteDropped` | Per-note controllers, per-note pitch bend or per-note management (no MIDI 1.0 equivalent) |
| `umpOnlyDropped` | Messages v1 export does not map (MT 0, 1, 5 and higher, and relative controllers). Some have SMF equivalents, such as Flex Data tempo, meter, key and text; mapping them is deferred to #112 |
| `fidelityUnverified` | An MT4 event from an `unknown` endpoint, whose loss export cannot rule out |
| `passesOverlaid` | Events from more than one transport pass share one tick line: a pass is a loop iteration, or the span after a locate or transport restart (a clock restart continues its pass). Each event outside the earliest pass counts; unrolling is deferred to #112 (example 03) |
| `groupsFlattened` | Messages that carry a Group (MT 0x1–0x5 and 0xD; MT 0x0 and 0xF have none, M2-104-UM §2.1.2) span more than one group: each one outside the lowest counts. Groupless messages never add a group (example 10) |

Rules:

- Losses are computed only for genuine `midi2` MT4 data. OS-upscaled MIDI 1.0 survives losslessly (example 09);
  MT4 data from an `unknown` endpoint counts as `fidelityUnverified` (example 10).
- "Survives" uses the MIDI Association min-centre-max bit scaling: `scaleUp(100, 7→16) = 0xC924` and
  `scaleUp(64, 7→32) = 0x80000000`.
- MIDI Clip File (M2-116-U) export is reserved for a later version.

## 10. Adapter boundary

| Native API | Adapter rule |
|---|---|
| `AVAudioTime` | May carry host time, sample time or both. Only a value with **both** valid becomes an anchor (`extrapolateTime(fromAnchor:)` needs both). Sample time maps to frames of the current `sampleClock` generation |
| `AVAudioPlayerNode` | `stop()` unschedules everything and resets player sample time to 0. `playerTime(forNodeTime:)` is nil when the player is not playing. Player timelines are adapter-private: the adapter maps kernel frames to `when` values, and kernel frames never depend on player sample time. Buffers are at the node's output rate |
| `AVAudioFile`, bookmarks | Prefetch (#109) and capture (#110) adapters only. They map file loss to `source` generations |
| CoreMIDI | Ports are created per protocol (`MIDIInputPortCreateWithProtocol`). The receive block runs on a high-priority CoreMIDI thread and only copies into a bounded handoff. Input `timeStamp` is when events occurred. Output timestamp 0 means "now" for `MIDISendEventList`, but not for a virtual source's `MIDIReceivedEventList`, which must stamp real times |
| Host time | `mach_absolute_time` with `mach_timebase_info`, or `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. Both pause during sleep, so wake bumps `sampleClock` (`wake`). Use requires a privacy-manifest declaration ([§11](#11-ownership-and-adoption-notes)) |

Render-thread code must be checkable with Clang `[[clang::nonblocking]]`/`nonallocating` and RealtimeSanitizer
where the toolchain supports them. These only cover code the compiler sees: they do not prove native framework,
FFI or plugin code real-time safe (#48).

## 11. Ownership and adoption notes

| Issue | Adopts or owns |
|---|---|
| #54 Versioned projects and graphs | Persists media references with musical ticks and frames only (M13). Stores `timePolicy`, late policy and retroactive tolerance per action. Reserves `extensions` |
| #55 Capability, parameter, transport and command contracts | Owns the production Swift types for [§3](#3-plain-values) and the generation kinds in [§5.1](#51-generation-counters). Command acknowledgements carry the [§6.4](#64-outcomes-and-precedence) outcomes |
| #62 Activation and engine lease | Owns `context` generations. A lease change is a `contextChange` |
| #64 Bounded buffers and queues | Provides the bounded, non-lossy outcome channel (M5) and the SPSC rings used by [§8.2](#82-prefetch-109)–[§8.3](#83-capture-109-110) |
| #65 Interface discovery and lifecycle | Owns `sampleClock` bumps for device restart, rate and configuration change, and wake, and each generation's `nominalRate` |
| #81 CoreMIDI I/O, #83 UMP/MIDI 2/MIDI-CI | Move from the legacy `MIDIInputPortCreateWithBlock` (`Shared/MIDI/CoreMIDIInput.swift`) to per-protocol ports. Report `endpointProtocol` (`unknown` when absent), `portProtocol` and `translatedBy`. Emit `formatChange` after MIDI-CI. Verify the derived translation and upscaling rules ([§14](#14-open-questions), question 8) |
| #84 Musical MIDI clock | Owns `transport` and `musicalMap`, rate-limited external tempo, the restart resume rule ([§5.3](#53-clock-restart)), and with #107 the commit look-ahead ([§2](#2-terminology)) |
| #107 Preloaded performance actions | Uses triggers, the requires list, `cancelScope`, the late policies and readiness. Decides `notReady` deferral and, with #84, the commit look-ahead |
| #109 Shared prefetch and capture handoff | Implements [§8.2](#82-prefetch-109)–[§8.3](#83-capture-109-110). Owns `source` generations for files |
| #110 Bounded I/O and recoverable recording | Implements takes, segments, overflow padding, `captureStopped` and latency evidence |
| #111 Backing clips, metronome, tuner | Backing clips are `fixedRate` by default and use `joinInProgress`. The metronome is a musical-grid `state` or `midi` action with no audio stretching |
| #112 MIDI clips with protocol fidelity | Plays clips with `tempoFollowing` by default. Implements native UMP capture and export (timing as offsets from the take start), and SMF export with declared losses ([§9](#9-midi-fidelity-and-export)) |

Coordinator follow-ups (proposed, not done here): a CI or Makefile step that runs the checker, and a
`PrivacyInfo.xcprivacy` system-boot-time declaration when adapters first read host time.

## 12. Versioning and compatibility

- Every example declares `"contract": "fluxklang.media"` and `"version": 1`.
- Within v1, changes are additive and optional only. Removing or renaming a field or enum value, or changing any
  invariant or default, requires `version: 2` and new examples.
- Readers preserve unknown optional data under `extensions`. The strict validator rejects unknown fields elsewhere,
  so drift is caught.
- Examples are synthetic and deterministic, and use stable synthetic IDs (`ex.NN-name`, `trg.N`, `act.name`).
  Examples and the schema are canonical JSON: authored key order, two-space indent, and a container inline when it
  fits 120 columns (or is a timeline record), otherwise its members packed into rows of at most 120 columns, with
  closing brackets ending the last row. The checker enforces the canonical form.

## 13. Non-goals

- No Swift types, queues or backend choice, and no edits to `Shared/` or the project. Owners adopt this contract.
- No sample-accurate cueing of external hardware, and no network clocks (network tempo-sync protocols, PTP, MIDI clock over network).
- No time-stretch algorithm or vendor choice.
- No lossless UMP→SMF conversion, and no recovery of fidelity the OS already discarded.
- No drift compensation between multiple devices in v1. There is one primary sample clock per graph.

## 14. Open questions

1. TPQ 15360 versus rational ticks for tuplets beyond 15360's divisors (#84, #54).
2. Multiple simultaneous sample clocks and drift compensation (#65).
3. Using UMP Jitter Reduction timestamps when endpoints provide them (#83).
4. MIDI Clip File (M2-116-U) export, and mapping Flex Data tempo, meter, key and text to SMF meta events (#112).
5. A `notReady` deferral policy, which v1 leaves out (#107).
6. Default `retroactiveMs` per action type (#107, #111).
7. Absolute musical targets outside an active loop (#84, #107).
8. Whether CoreMIDI converts exactly when endpoint and port protocols differ, and whether its MIDI 1→2
   upconversion is min-centre-max on the shipping OS (#81, #83, #110).
9. The stopped-transport default (`wait`) (#84, #107).
10. Meter changes positioned inside a map revision (#84), and whether a take writer continues one file across a rate
    change by resampling or starts a new file (#110).

## 15. Examples and validation

| Example | Covers |
|---|---|
| [`01-clock-restart`](media-contract/examples/01-clock-restart.json) | clock restart at a new rate, resume position with the transport bump first, frame order across the restart, cancellation, stale-trigger rejection |
| [`02-late-and-retroactive-cue`](media-contract/examples/02-late-and-retroactive-cue.json) | join in progress, retroactive window, fire late, drop, next boundary on a trigger's grid |
| [`03-seek-and-loop`](media-contract/examples/03-seek-and-loop.json) | loop wrap, a cue and a delayed capture across the wrap (occurrences), same-frame ordering, locate, re-preparation, SMF pass overlay |
| [`04-tempo-mutation`](media-contract/examples/04-tempo-mutation.json) | tempo and meter edit re-resolution, delayed capture across tempo segments and its lossless SMF export, fixed-rate default, time-stretch unavailable |
| [`05-source-loss`](media-contract/examples/05-source-loss.json) | underrun, source loss and reacquisition, no replay |
| [`06-stale-trigger-no-replay`](media-contract/examples/06-stale-trigger-no-replay.json) | user cancel, context change, rejection |
| [`07-readiness-and-prefetch`](media-contract/examples/07-readiness-and-prefetch.json) | readiness transitions, `notReady` drops |
| [`08-audio-capture-discontinuities`](media-contract/examples/08-audio-capture-discontinuities.json) | overflow padding, 48 → 96 kHz restart splits the take, disk full, a later take scoped to its own stop |
| [`09-midi1-in-ump-capture-export`](media-contract/examples/09-midi1-in-ump-capture-export.json) | MIDI 1 in UMP, OS upconversion, lossless SMF at 20 BPM, native export origin across a restart |
| [`10-midi2-capture-lossy-smf-export`](media-contract/examples/10-midi2-capture-lossy-smf-export.json) | genuine MIDI 2, unknown endpoint, native UMP export, declared SMF loss, groupless JR Timestamp |

Timeline records are transient traces; their host ticks are never persisted. Take segments and export records show the
persisted, anchor-relative shapes. Constants: 48 kHz unless a generation sets a rate; host timebase 125/3 ns per tick
(500 per frame); 120 BPM (1.5625 frames per tick, 96000 frames per 4/4 bar), but 20 BPM in example 09.

Run from the repository root (Python 3.9 or later, standard library only; no app, hardware, network or plugins):

```sh
python3 docs/transformation/media-contract/check_media_contract.py           # validate
python3 docs/transformation/media-contract/check_media_contract.py --write   # rewrite in canonical form
```

The checker parses strictly (invalid UTF-8, duplicate keys, `NaN` and `Infinity` are rejected) and requires each file
to round-trip byte-for-byte to canonical form. It validates against the schema, implementing exactly the keywords used
(`pattern` anchors as in ECMA-262, so `$` never matches before a final newline). It then replays each trace in exact
rational arithmetic, enforcing [§4](#4-invariants)–[§9](#9-midi-fidelity-and-export) and recomputing every outcome
frame, resume position, take offset and SMF loss. Every `covers` tag must be backed by evidence in a trace. Mutation
self-tests each break one rule in a valid example (for example a stale trigger fires, a trigger is relabelled
`capacity`, or an SMF loss is hidden) and must fail with that rule's error; positive controls must pass. A malformed
file or trace reports `FAIL`, never a crash, and is not used for mutations.

Run the focused trace regressions with
`python3 -B -m unittest discover -s docs/transformation/media-contract -p 'test_*.py'`.
They cover declared musical-counter identities, primary render progress despite a stale secondary-clock dependency,
and loop-bounded `nextBoundary` fallback, including a valid loop-end target. Native Swift coverage remains part of #55.

**Checker limits.** Not fully checked here; acceptance items for the #55 Swift contract tests or the named owner:
- lateness and `asap` against the exact latency-inclusive horizon at commit; the checker only lower-bounds it (§6.1);
- synchronous `capacity` refusal and outcome-slot reservation (M5); the stopped-transport policy (§6.2);
- owned-note releases at locate, loop wrap, clock restart and stop (§5.1, §6.5);
- bounded SPSC handoffs, render-thread safety and adapter-only engine types (M8, M11, §10; #64, #109);
- the recorder's report of cross-restart captures (§9.2; #110, #112); the checker just rejects such traces;
- rejecting captures stamped before a locate but delivered after it (§9.2); the checker remaps them;
- readiness invalidation and re-preparation after a `source` bump (§5.1, §5.7); the checker trusts readiness records.

## 16. Sources

- Apple, [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime): host and sample time validity;
  `extrapolateTime(fromAnchor:)`.
- Apple, [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode): player and node
  timelines, `stop()`, `playerTime(forNodeTime:)`, and `when` semantics.
- Apple CoreMIDI:
  [MIDIInputPortCreateWithProtocol](https://developer.apple.com/documentation/coremidi/midiinputportcreatewithprotocol(_:_:_:_:_:)),
  [kMIDIPropertyProtocolID](https://developer.apple.com/documentation/coremidi/kmidipropertyprotocolid),
  [MIDITimeStamp](https://developer.apple.com/documentation/coremidi/miditimestamp) and
  [MIDIEventPacket](https://developer.apple.com/documentation/coremidi/midieventpacket); and the macOS SDK header
  `CoreMIDI/MIDIServices.h` (`kMIDIPropertyProtocolID`, port protocol conversion, `MIDIReceivedEventList`).
- Apple, [mach_absolute_time](https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time) and the
  [privacy manifest required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).
- MIDI Association, [UMP Format and MIDI 2.0 Protocol, M2-104-UM v1.1.2](https://midi.org/universal-midi-packet-ump-and-midi-2-0-protocol-specification/);
  [MIDI 2.0 Bit Scaling and Resolution](https://midi.org/midi-2-0-bit-scaling-and-resolution);
  [MIDI Clip File, M2-116-U](https://midi.org/midi-clip-file-specification-smf-midi-2-0/); and
  [Standard MIDI Files, RP-001](https://midi.org/standard-midi-files).
- [AM_MIDI2.0Lib](https://github.com/midi2-dev/AM_MIDI2.0Lib) (MIT): reference `scaleUp` and UMP→MIDI 1 translation,
  used to cross-check the examples.
- Clang, [RealtimeSanitizer](https://clang.llvm.org/docs/RealtimeSanitizer.html) and
  [Function Effect Analysis](https://clang.llvm.org/docs/FunctionEffectAnalysis.html).
