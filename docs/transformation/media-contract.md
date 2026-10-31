# G-MEDIA: media clock, scheduling and fidelity contract (v1)

| Field | Value |
|---|---|
| Contract | `fluxklang.media` |
| Version | `1` (integer major version; see [§12](#12-versioning-and-compatibility)) |
| Gate | G-MEDIA, issue #53 (roadmap #48). Must be accepted before the #54/#55 schema freeze |
| Status | **Proposed**. Becomes **Accepted v1** when the #54 and #55 coordinators merge it |
| Owners | This document: #53. Production types: #55 (stamps, generations, commands) and #54 (persisted media references) |
| Machine-readable form | [`media-contract/media-contract-v1.schema.json`](media-contract/media-contract-v1.schema.json) and [`media-contract/examples/`](media-contract/examples/) |
| Validation | `python3 docs/transformation/media-contract/check_media_contract.py` (standard library only; [§15](#15-examples-and-validation)) |

This contract fixes the media meaning the graph, transport and performance work must share. It distils the research
already recorded in #48 ("Plugins, patches and shows", "Runtime and latency", "Contracts and authority"), #53 and
#109–#112, plus the primary sources in [§16](#16-sources). It defines **values, rules and policies only**. Swift
types, queues and adapters belong to their owners ([§11](#11-ownership-and-adoption-notes)). Nothing here depends on
playback, recording or backend selection being finished.

## 1. Scope

In scope:

- plain clock stamps and generations
- sample, host and musical anchors
- event ordering, quantization and cancellation
- loop, seek and tempo mutation policy
- readiness of preloaded actions
- bounded prefetch and capture ownership, and discontinuities
- MIDI container versus actual protocol fidelity, native capture, and visible lossy SMF export

The kernel contract names no Foundation objects and no specific engine. AVAudioTime, AVAudioPlayerNode, AVAudioFile
and CoreMIDI stay behind adapters ([§10](#10-adapter-boundary)).

## 2. Terminology

| Term | Meaning |
|---|---|
| Sample clock | A device-driven frame counter (`Int64` frames) with an identity (`clockId`), a nominal rate and a generation. It is the render timeline |
| Host clock | The monotonic process clock in host ticks (`UInt64`) with a timebase `numer/denom` (ns per tick). Process-local; it does not advance during sleep |
| Musical time | Ticks (`Int64`) at a fixed **15360 ticks per quarter note** (TPQ). A beat is a quarter note. Converted to frames only through the musical map and an anchor |
| Musical map | Ordered `(atTicks, microsPerQuarter)` segments plus meter. One revision covers both tempo and meter |
| Console setup | Device selection, routing, buffer size and gain. It is configuration, **not a clock**; changing it may bump the sample clock generation |
| Anchor | One simultaneous observation of `(sample clock, generation, frame, hostTicks)`, optionally with `(transport generation, musicalTicks, loopIteration)` |
| Generation | A counter that names an epoch of meaning (see [§5.1](#51-generation-counters)) |
| Trigger | A stamped request to perform a prepared action: origin host time, the horizon at arrival, the generations it requires, and a target |
| Origin | The host time of the human or remote intent (`originHostTicks`) |
| Horizon | `horizonFrame`: the earliest frame the scheduler can still affect when the trigger arrives |
| Assigned frame | The frame the quantized target resolves to. Late if `assignedFrame < horizonFrame` |
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
in persisted, debug and example forms.

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
| `Discontinuity` | `type` (UInt8), `SampleStamp`, `frames` (UInt32, optional), `stream` slot, optional `HostStamp` |

## 4. Invariants

The checker enforces these invariants on every example. Markers: ✔ checked, ◐ partly checked, — documented only.

| ID | Invariant | |
|---|---|---|
| M1 | Audio sample clock, host clock, musical time and console setup are distinct domains. Values never convert implicitly. Conversion goes only through an anchor of the **current** generations | ✔ |
| M2 | Generations start at 1, advance by exactly 1, are never reused, and are compared only for equality | ✔ |
| M3 | Every trigger carries its origin host time, its horizon and the generations it depends on. Musical-map revisions are never dependencies | ✔ |
| M4 | A trigger whose required generation changed is never fired, deferred, retargeted or replayed. It is `cancelled` if pending and `rejectedStale` if it arrived stale | ✔ |
| M5 | Every accepted trigger receives exactly one terminal outcome. The outcome channel is bounded and never silently drops; on overflow the producer refuses new triggers (`dropped`, reason `capacity`) | ◐ |
| M6 | Uncommitted musical targets re-resolve against the current musical map. A tempo or meter edit cancels nothing | ✔ |
| M7 | An action fires only if it was `ready` when triggered and stayed `ready` until dispatch. Nothing is loaded, allocated or decoded at fire time | ✔ |
| M8 | Prefetch and capture use preallocated, bounded single-producer/single-consumer handoffs. The render thread never blocks, allocates or performs I/O | ◐ |
| M9 | Every loss of continuity is recorded as a discontinuity with its frame and count. Underruns and overflows are never silent | ✔ |
| M10 | MIDI fidelity reports what the source actually sent. Conversion loss is always declared, never hidden | ✔ |
| M11 | Native timing objects and engine APIs stay in adapters. The kernel contract has no Foundation or engine types | — |
| M12 | Fixed-rate audio is the default. Tempo-following MIDI and time-stretched audio are explicit, distinct policies. Stretching never happens silently | ✔ |
| M13 | Persisted media stores no absolute host ticks. It stores frames, musical ticks and nanosecond offsets relative to a recorded anchor | — |

## 5. Generations and mutation policy

### 5.1 Generation counters

Counters are keyed `kind/id` (for example `transport/mus.main`). Owners are in brackets.

| Kind | Bumped by (reason) | Effect on dependants |
|---|---|---|
| `sampleClock` [#65, #55] | `deviceRestart`, `rateChange`, `configurationChange`, `wake` | Pending triggers cancelled. Old anchors void. Forces a `transport` bump (`clockRestart`) |
| `transport` [#84, #55] | `locate`, `clockRestart`, `transportRestart` | Pending musical triggers cancelled. Owned notes released. Musical anchor void until re-anchored |
| `musicalMap` [#84] | `tempoEdit`, `externalTempo` (rate-limited) | Uncommitted musical targets re-resolve. **Nothing is cancelled** |
| `source` [#109, #81] | `sourceLost`, `sourceReacquired` | Dependent triggers cancelled. Readiness invalidated |
| `context` [#62, #55] | `contextChange` (activation or engine lease) | Pending triggers cancelled. Old-context triggers rejected |
| `cancelScope` [#107] | `userCancel` | Pending triggers in the scope cancelled |

Two changes are **not** generations. A loop wrap increments `loopIteration`. A sample jump within a continuous
device mapping is a `sampleJump` discontinuity.

### 5.2 Anchors and conversion

- An anchor is valid only while its sample generation (and, for musical fields, its transport generation) is current.
- `frame(host) = anchor.frame + (host − anchor.host) · (numer/denom) · rate / 10⁹`. The nominal rate is used between
  anchors. Adapters re-anchor at least once per render cycle in which they observe both values.
- Musical ticks to frames: integrate the musical map from the latest musical anchor. Round half-up
  (`floor(x + ½)`) only at the final frame.
- Within one generation, consecutive anchors must advance and agree with the nominal rate within 0.1%. Larger
  disagreement means the device changed rate, so the adapter must bump `sampleClock` (`rateChange`).

### 5.3 Clock restart

The policy for a device restart, rate change, configuration change or wake:

1. Bump `sampleClock` and record a `clockRestart` discontinuity before the first anchor of the new generation.
2. Cancel every pending trigger that required the old generation.
3. Bump `transport` (`clockRestart`). The internal transport resumes from the last **rendered** musical position.
   There is no catch-up for the gap.
4. Re-anchor. Late triggers stamped with the old generation are `rejectedStale` (example 01).

### 5.4 Seek (locate)

A locate bumps `transport` and records a `locate` discontinuity at the frame where it takes effect. The `release`
lane then turns off every owned note. Prefetch for affected audio is invalidated and re-prepared. The transport
re-anchors at the new position (example 03).

### 5.5 Loop

- A loop is `[startTicks, endTicks)`.
- At the wrap frame:
  1. record a `loopWrap` discontinuity
  2. re-anchor with `musicalTicks = startTicks` and `loopIteration + 1`
  3. dispatch owned releases first ([§6.5](#65-ordering))
- A grid boundary equal to `endTicks` resolves to the wrap frame, the start of the next iteration.
- In v1, musical targets must resolve inside `[startTicks, endTicks]` while a loop is active
  ([§14](#14-open-questions)).

### 5.6 Tempo and meter

- A musical-map edit bumps `musicalMap` and carries the whole new map.
- Already-dispatched events keep their frames. Pending musical targets re-resolve with the new map, and their
  outcome names the revision used (example 04).
- External tempo (#84) is rate-limited so it cannot cause unbounded re-resolution.
- Fixed-rate audio keeps its sample length. A tempo mismatch is advisory.

### 5.7 Source loss

- A lost file, volume, device or endpoint bumps `source`, records `sourceLost` on the stream, and invalidates
  dependent readiness.
- Reacquisition is a new generation (`sourceReacquired`) recorded as `sourceRestored`. It requires re-preparation.
- Triggers stamped before the loss never replay (example 05).

### 5.8 Context changes and user cancel

- `contextChange` (#62) covers a new activation or engine lease.
- `userCancel` (#107) covers a cancelled set or scene.
- Both cancel pending triggers and reject late stale ones (example 06).

## 6. Scheduling

### 6.1 Horizon

- The scheduler publishes `horizonFrame` as the earliest frame it can still affect, at least the next render cycle
  plus any adapter latency.
- `asap` targets resolve to the horizon.
- A target before the horizon is **late**.

### 6.2 Quantization

- `musical` targets use either a `gridTicks` (next boundary at or after the origin's musical position) or an
  absolute `atTicks`.
- `sample` targets use `atFrame`.
- An origin exactly on a boundary uses that boundary.
- When the transport is stopped, the action's stopped policy applies: `wait` (default), `immediate` or
  `startTransport`. This is documented only in v1.

### 6.3 Late and retroactive cues

| Policy | When late (`assignedFrame < horizonFrame`) |
|---|---|
| `drop` | `dropped`, reason `late` |
| `fireLate` | If lateness ≤ `maxLatenessMs`: `firedLate` at the horizon. Otherwise `dropped` (`late`) |
| `joinInProgress` | If lateness ≤ `maxLatenessMs`: `joined` at the horizon with `startOffsetFrames = horizon − assigned`, so the source stays aligned. Otherwise `dropped` (`late`) |
| `nextBoundary` | `fired` at the first grid boundary at or after the horizon. Requires a musical grid |

**Retroactive tolerance.** `retroactiveMs` ranges over 0–120 and defaults to 0. It is allowed only with `fireLate`
and `joinInProgress`. If the origin is within the tolerance after the previous grid boundary, the trigger is
assigned to that boundary (example 02, trg.1). Outside the window it takes the next boundary (trg.2).

### 6.4 Outcomes and precedence

The checker evaluates a trigger's outcome in this order:

1. `rejectedStale` if it arrived with a stale required generation.
2. `cancelled` if a required generation changed while it was pending.
3. `dropped` (`notReady`) if the action was not continuously `ready`.
4. The timing policy.

Rules:

- `notReady` has one v1 policy, `dropAndReport`. Deferral is an open question for #107.
- `dropped` (`capacity`) reports bounded-queue refusal.
- No outcome is ever followed by a second outcome or a replay.

### 6.5 Ordering

Dispatched events are ordered by **(frame, lane, streamOrdinal, streamSeq)**:

| Lane | Rank | Contents |
|---|---|---|
| `release` | 0 | System releases: owned note-offs at wrap, locate or stop, and panic |
| `transport` | 1 | Transport state and position changes |
| `state` | 2 | Prepared parameter, program and recall changes |
| `content` | 3 | Stream content (notes, clips) in source order |

Source order within a stream is preserved (`streamSeq` strictly increases). Stream ordinals are assigned at prepare
time, never at fire time.

## 7. Readiness

| From | Allowed to |
|---|---|
| `unprepared` | `preparing` |
| `preparing` | `ready`, `failed`, `unprepared` |
| `ready` | `invalidated`, `unprepared` |
| `invalidated` | `preparing`, `unprepared` |
| `failed` | `preparing`, `unprepared` |

- `ready` means every resource the action needs is resident: the prefetch head, decoded state, and stream ordinals.
- `failed` and `invalidated` carry a reason (for example `timeStretchUnavailable`, `memoryPressure`,
  `assetChanged` or `sourceLost`).
- "Armed" is a derived UI state (ready plus a pending trigger), not a readiness state.
- A trigger that arrives while its action is not `ready`, or whose action leaves `ready` while the trigger is
  pending, is `dropped` with reason `notReady` (example 07).

## 8. Audio policies, prefetch and capture

### 8.1 Time policies

| Media | Allowed `timePolicy` | Default for new actions |
|---|---|---|
| audio | `fixedRate`, `timeStretch` | `fixedRate` (sample-rate conversion is not stretching) |
| midi | `tempoFollowing`, `fixedRate` | `tempoFollowing` |
| state, transport | none | — |

Persisted audio and MIDI actions always state their `timePolicy`, so a future default change can never alter a saved
show. `timeStretch` needs an adapter that declares `adapterCapabilities.timeStretch`. Without one, readiness fails
with `timeStretchUnavailable`, and there is no silent fixed-rate fallback (example 04).

### 8.2 Prefetch (#109)

- Each audio source voice owns an SPSC ring of preallocated pool blocks: `blockFrames × blockCount ≥ headFrames`.
- Blocks carry the source generation and read generation. Stale blocks are discarded, never played.
- On underrun the voice outputs silence, skips the missing source frames to stay aligned, and records `underrun`
  with a frame count (example 05).

### 8.3 Capture (#109, #110)

- Each consumer gets its own handoff. One tap never feeds two racing SPSC consumers.
- Overflow never blocks. Dropped frames are padded with silence in the file and recorded as `overflow`. A take's
  `droppedFrames` equals the sum of its padded frames.
- A sample clock restart starts a new segment. There is no padding across restarts; segments align by their host
  anchors.
- Disk full records `captureStopped` at the end of the last segment and leaves a recoverable partial file
  (example 08).
- Persisted takes store segment frames and nanosecond offsets relative to the take's first anchor, never absolute
  host ticks (M13). The example's `startHostTicks` is a trace-only debug field.

### 8.4 Discontinuity kinds

| Type | Meaning | Required data |
|---|---|---|
| `clockRestart` | New sample clock generation begins | new generation, host ticks |
| `sampleJump` | Frame jump within a continuous device mapping | frame |
| `underrun` | Playback ran out of prefetched data | playback stream, `frames` |
| `overflow` | Capture handoff full; frames padded | capture stream, `frames` |
| `sourceLost`, `sourceRestored` | Source availability changed (one per `source` bump) | stream |
| `locate` | Transport jumped (one per `locate` bump) | frame |
| `loopWrap` | Loop iteration boundary | frame |
| `formatChange` | Stream format or MIDI protocol changed (for example after MIDI-CI) | stream |
| `captureStopped` | Capture ended for a non-user reason | stream, reason |

### 8.5 Latency

Input latency is reported as `reportedFrames` (device or OS claim) and `measuredFrames` (loopback measurement, or
`null`). A measured value must cite its evidence. Reported latency is never presented as measured.

## 9. MIDI fidelity and export

### 9.1 Container versus effective protocol

CoreMIDI converts between protocols automatically when the port and endpoint protocols differ. The endpoint's native
protocol is `kMIDIPropertyProtocolID`, which can change after MIDI-CI negotiation. Rules:

- `translatedBy = os` exactly when `endpointProtocol ≠ portProtocol`. Otherwise it is `none`.
- MT 0x2 (MIDI 1.0 channel voice in UMP) is effective `midi1`.
- MT 0x4 (MIDI 2.0 channel voice) is effective `midi2` **only** when the endpoint protocol is `midi2`; otherwise it
  is OS-upscaled MIDI 1.0 and effective `midi1`.
- Effective protocol comes from the endpoint property, never from inspecting values.
- A protocol change records a `formatChange` discontinuity.

| Endpoint | Port | translatedBy | Words received | Effective | Example |
|---|---|---|---|---|---|
| midi1 | midi1 | none | MT2 | midi1 | 09 (`str.keys-a`) |
| midi1 | midi2 | os | MT4 (upscaled) | midi1 | 09 (`str.keys-b`) |
| midi2 | midi2 | none | MT4 | midi2 | 10 (`str.synth`) |
| midi2 | midi1 | os | MT2 (downscaled before we see it) | midi1 | 10 (`str.synth-legacy`) |

### 9.2 Native capture

Capture stores the UMP words verbatim, plus host ticks, the derived frame (through the current anchor) and musical
ticks when a transport is anchored, plus the protocol fields above. `nativeUmp` export is lossless by definition.
Capture never upgrades fidelity: OS-upscaled values keep `effective = midi1`.

### 9.3 SMF export losses

SMF (RP-001) carries MIDI 1.0 bytes. Export computes and declares every loss. `lossless` is true exactly when
`losses` is empty.

| Category | Counted when |
|---|---|
| `timingQuantized` | An event's musical tick is not a multiple of `15360 / division`. `division` must divide 15360 |
| `syntheticTempoMap` | An event has no musical stamp, so export must invent a tempo map |
| `velocityDownscaled` | A genuine MIDI 2.0 note velocity is not the min-centre-max upscale of its top 7 bits |
| `noteOnVelocityRemapped` | A genuine MIDI 2.0 Note On's 7-bit velocity is 0, so it is sent as 1 (not Note Off) |
| `valueDownscaled` | A genuine 32-bit value (poly pressure, CC, channel pressure, RPN/NRPN data, pitch bend) does not survive reduction to 7 or 14 bits |
| `attributeDropped` | A Note On or Off has an attribute type ≠ 0 |
| `perNoteDropped` | Per-note controllers, per-note pitch bend or per-note management (no MIDI 1.0 equivalent) |
| `umpOnlyDropped` | Messages with no SMF form (MT 0, 1, 5 and higher, and relative controllers) |
| `groupsFlattened` | Events from more than one UMP group are merged into 16 channels |

Rules:

- Losses are computed only for genuine `midi2` MT4 data. OS-upscaled MIDI 1.0 survives losslessly (example 09).
- "Survives" uses the MIDI Association min-centre-max bit scaling: `scaleUp(100, 7→16) = 0xC924` and
  `scaleUp(64, 7→32) = 0x80000000`.
- MIDI Clip File (M2-116-U) export is reserved for a later version.

## 10. Adapter boundary

| Native API | Adapter rule |
|---|---|
| `AVAudioTime` | May carry host time, sample time or both. Only a value with **both** valid becomes an anchor (`extrapolateTime(fromAnchor:)` needs both). Sample time maps to frames of the current `sampleClock` generation |
| `AVAudioPlayerNode` | `stop()` unschedules everything and resets player sample time to 0. `playerTime(forNodeTime:)` is nil when the player is not playing. Player timelines are adapter-private: the adapter maps kernel frames to `when` values, and kernel frames never depend on player sample time. Buffers are at the node's output rate |
| `AVAudioFile`, bookmarks | Prefetch (#109) and capture (#110) adapters only. They map file loss to `source` generations |
| CoreMIDI | Ports are created per protocol (`MIDIInputPortCreateWithProtocol`). The receive block runs on a high-priority CoreMIDI thread and only copies into a bounded handoff. Input `timeStamp` is when events occurred. Output timestamp 0 means "now" |
| Host time | `mach_absolute_time` with `mach_timebase_info`, or `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. Both pause during sleep, so wake bumps `sampleClock` (`wake`). Use requires a privacy-manifest declaration ([§11](#11-ownership-and-adoption-notes)) |

Render-thread code must be checkable with Clang `[[clang::nonblocking]]`/`nonallocating` and RealtimeSanitizer
where the toolchain supports them.

## 11. Ownership and adoption notes

| Issue | Adopts or owns |
|---|---|
| #54 Versioned projects and graphs | Persists media references with musical ticks and frames only (M13). Stores `timePolicy`, late policy and retroactive tolerance per action. Reserves `extensions` |
| #55 Capability, parameter, transport and command contracts | Owns the production Swift types for [§3](#3-plain-values) and the generation kinds in [§5.1](#51-generation-counters). Command acknowledgements carry the [§6.4](#64-outcomes-and-precedence) outcomes |
| #62 Activation and engine lease | Owns `context` generations. A lease change is a `contextChange` |
| #64 Bounded buffers and queues | Provides the bounded, non-lossy outcome channel (M5) and the SPSC rings used by [§8.2](#82-prefetch-109)–[§8.3](#83-capture-109-110) |
| #65 Interface discovery and lifecycle | Owns `sampleClock` bumps for device restart, rate and configuration change, and wake |
| #81 CoreMIDI I/O, #83 UMP/MIDI 2/MIDI-CI | Move from the legacy `MIDIInputPortCreateWithBlock` (`Shared/MIDI/CoreMIDIInput.swift`) to per-protocol ports. Report `endpointProtocol`, `portProtocol` and `translatedBy`. Emit `formatChange` after MIDI-CI. Verify the OS upscaling rule ([§14](#14-open-questions)) |
| #84 Musical MIDI clock | Owns `transport` and `musicalMap`, rate-limited external tempo, and the restart resume rule ([§5.3](#53-clock-restart)) |
| #107 Preloaded performance actions | Uses triggers, the requires list, `cancelScope`, the late policies and readiness. Decides `notReady` deferral |
| #109 Shared prefetch and capture handoff | Implements [§8.2](#82-prefetch-109)–[§8.3](#83-capture-109-110). Owns `source` generations for files |
| #110 Bounded I/O and recoverable recording | Implements takes, segments, overflow padding, `captureStopped` and latency evidence |
| #111 Backing clips, metronome, tuner | Backing clips are `fixedRate` by default and use `joinInProgress`. The metronome is a musical-grid `state` or `midi` action with no audio stretching |
| #112 MIDI clips with protocol fidelity | Plays clips with `tempoFollowing` by default. Implements native UMP capture and export, and SMF export with declared losses ([§9](#9-midi-fidelity-and-export)) |

Coordinator follow-ups (proposed, not done here):

- Add a CI or Makefile step that runs the checker.
- Add a `PrivacyInfo.xcprivacy` system-boot-time declaration when adapters first read host time.

## 12. Versioning and compatibility

- Every example declares `"contract": "fluxklang.media"` and `"version": 1`.
- Within v1, changes are additive and optional only. Removing or renaming a field or enum value, or changing any
  invariant or default, requires `version: 2` and new examples.
- Readers preserve unknown optional data under `extensions`. The strict validator rejects unknown fields elsewhere,
  so drift is caught.
- Examples are synthetic and deterministic, and use stable synthetic IDs (`ex.NN-name`, `trg.N`, `act.name`). Files
  are canonical JSON: authored key order, two-space indent, and containers inline at 120 columns or one record per
  line. The checker enforces the canonical form.

## 13. Non-goals

- No Swift types, queues or backend choice, and no edits to `Shared/` or the project. Owners adopt this contract.
- No sample-accurate cueing of external hardware, and no network clocks (Ableton Link, PTP, MIDI clock over network).
- No time-stretch algorithm or vendor choice.
- No lossless UMP→SMF conversion, and no recovery of fidelity the OS already discarded.
- No drift compensation between multiple devices in v1. There is one primary sample clock per graph.

## 14. Open questions

1. TPQ 15360 versus rational ticks for tuplets beyond 15360's divisors (#84, #54).
2. Multiple simultaneous sample clocks and drift compensation (#65).
3. Using UMP Jitter Reduction timestamps when endpoints provide them (#83).
4. MIDI Clip File (M2-116-U) export (#112).
5. A `notReady` deferral policy, which v1 leaves out (#107).
6. Default `retroactiveMs` per action type (#107, #111).
7. Absolute musical targets outside an active loop (#84, #107).
8. Whether CoreMIDI's MIDI 1→2 upconversion preserves the top 7 bits exactly on the shipping OS (#83, #110).
9. The stopped-transport default (`wait`) (#84, #107).

## 15. Examples and validation

| Example | Covers |
|---|---|
| [`01-clock-restart`](media-contract/examples/01-clock-restart.json) | clock restart, cancellation, stale-trigger rejection |
| [`02-late-and-retroactive-cue`](media-contract/examples/02-late-and-retroactive-cue.json) | join in progress, retroactive window, fire late, drop |
| [`03-seek-and-loop`](media-contract/examples/03-seek-and-loop.json) | loop wrap, same-frame ordering, locate, re-preparation |
| [`04-tempo-mutation`](media-contract/examples/04-tempo-mutation.json) | tempo edit re-resolution, fixed-rate default, time-stretch unavailable |
| [`05-source-loss`](media-contract/examples/05-source-loss.json) | underrun, source loss and reacquisition, no replay |
| [`06-stale-trigger-no-replay`](media-contract/examples/06-stale-trigger-no-replay.json) | user cancel, context change, rejection |
| [`07-readiness-and-prefetch`](media-contract/examples/07-readiness-and-prefetch.json) | readiness transitions, `notReady` drops |
| [`08-audio-capture-discontinuities`](media-contract/examples/08-audio-capture-discontinuities.json) | overflow padding, segment split, disk full |
| [`09-midi1-in-ump-capture-export`](media-contract/examples/09-midi1-in-ump-capture-export.json) | MIDI 1 in UMP, OS upconversion, lossless SMF |
| [`10-midi2-capture-lossy-smf-export`](media-contract/examples/10-midi2-capture-lossy-smf-export.json) | genuine MIDI 2, native UMP export, declared SMF loss |

Example constants: 48 kHz, host timebase 125/3 ns per tick (500 ticks per frame), 120 BPM (1.5625 frames per tick;
a 4/4 bar is 96000 frames).

Run from the repository root (Python 3.9 or later, standard library only; no app, hardware, network or plugins):

```sh
python3 docs/transformation/media-contract/check_media_contract.py           # validate
python3 docs/transformation/media-contract/check_media_contract.py --write   # rewrite in canonical form
```

The checker runs these steps:

1. It parses strictly (duplicate keys are rejected) and requires every file to round-trip byte-for-byte to its
   canonical form.
2. It validates against the v1 schema. The validator implements exactly the schema keywords used and refuses others.
3. It replays each trace with exact rational arithmetic and enforces [§4](#4-invariants)–[§9](#9-midi-fidelity-and-export).
   That includes:
   - recomputing every outcome frame
   - generation monotonicity
   - stale and cancelled triggers never firing
   - readiness transitions and ordering keys
   - UMP word counts
   - capture stamps and take padding totals
   - exact recomputation of SMF losses
4. It requires each `covers` tag to be backed by evidence in the trace and all tags to be covered.
5. It runs eleven mutation self-tests. Each one breaks a single rule (for example a stale trigger fires, a hidden
   SMF loss, a silent capture drop, or converted MIDI 1 claiming MIDI 2) and must be rejected.

## 16. Sources

- Apple, [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime): host and sample time validity;
  `extrapolateTime(fromAnchor:)`.
- Apple, [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode): player and node
  timelines, `stop()`, `playerTime(forNodeTime:)`, and `when` semantics.
- Apple CoreMIDI:
  [MIDIInputPortCreateWithProtocol](https://developer.apple.com/documentation/coremidi/midiinputportcreatewithprotocol(_:_:_:_:_:)),
  [kMIDIPropertyProtocolID](https://developer.apple.com/documentation/coremidi/kmidipropertyprotocolid),
  [MIDITimeStamp](https://developer.apple.com/documentation/coremidi/miditimestamp) and
  [MIDIEventPacket](https://developer.apple.com/documentation/coremidi/midieventpacket).
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
