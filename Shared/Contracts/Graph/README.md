# Portable graph v1

This is value-only intent, not a render plan or live routing API. Use
`GraphDocument.decode(from:)` / `encoded()` for bounded I-JSON persistence,
then `validate()` for structure. Decoding does not activate or repair anything.

- Project and graph revisions are independent `ContractRevision` streams.
  Node and edge IDs are graph-scoped; port IDs are node-scoped. Address a port
  through its owning node. Scalar aliases use Core `ContractID`, including UUID imports.
- Audio ports declare 1–64 channels. MIDI, control and clock ports have no audio
  channel count. Edges require output-to-input direction and equal signal kinds.
- Audio width changes require `channelMap`: one destination row containing the
  source indices summed into that channel. Empty rows are silence; at least one
  row must carry signal. No implicit conversion, rate conversion or MIDI coercion.
- Feedback must specify at least one render block of delay and a finite gain
  ceiling no greater than 0 dB. Removing those feedback edges must leave no cycle.
  This is a causal contract, not proof of acoustic stability.
- `CapabilityID` and `CapabilityDefinition` share the portable catalog used by
  device advertisements; they are not physical device identity or host observations.
  `validateForPreparation(supportedCapabilities:)` rejects missing required IDs;
  missing advisory capabilities remain placeholders, never substituted or bypassed.
  Passing this check grants no authority and proves no resource is prepared.
- `requiresReview` blocks validation of legacy imports, including empty graphs.
  Clearing it is a reviewed edit, not authorization to activate a host.

Unknown optional members survive at their original nesting level through Core
`ExtensionFields`; `extensions` remains a separate explicit bag. Strict validation
rejects stray unknown fields but permits extension bags. Unknown nonempty
`requiredFeatures` and unsupported versions reject rather than becoming optional data.

## Constant mute syntax profile

`audioMute.constant.v1` is one opt-in, fail-closed graph v1 syntax profile.
`requiredFeatures` stores the exact supplied candidate array. In a graph with no
gain nodes it must be `[]` when there are no mute nodes, and exactly
`["audioMute.constant.v1"]` when there is at least one `audioMute` node; the
gain combinations are listed below. Construction and mutation never infer, sort,
deduplicate, insert or remove features; validation, decoding and encoding reject
mismatches.
Missing, null and empty wire lists normalize to `[]` and are invalid with mutes.
Empty lists are omitted on encoding to retain base-v1 canonical bytes.
An unknown-field `requiredFeatures` collision rejects rather than being dropped.
Unsupported headers reject before node decoding; feature/node consistency runs
after bounded node decoding, before topology validation.

An `audioMute` requires an explicit Boolean `muted`, exactly one audio input and
one audio output with matching 1–64 channel widths, and no role, asset or graph
reference. Missing, null and non-Boolean state reject; there is no default.
State is constant per prepared graph; changing it requires a newly prepared graph.
False means a bit-preserving channelwise copy. True means channelwise positive
zero, **not multiplication by zero**. Neither state may suppress upstream work,
nonfinite-input refusal or intermediate-overflow refusal.

`muted` is known only on `audioMute`. Every older kind preserves arbitrary
unknown `muted` data (including null) through lenient canonical round trips;
strict validation still reports that unknown node path. Manually assigned typed
state on an older kind, or an unknown `muted` collision on a mute, rejects
validation and encoding rather than silently losing data.

Recognizing this syntax does not mean general executor support. The bounded
offline subset below adds no live control, physical-mute acknowledgement or
activation authority. Older graph readers
reject the feature marker before interpreting the new kind; they do not support
the profile. Project and package envelopes still reject all nonempty features,
including this graph token. Integer-major checks are unchanged; `minorVersion`
remains unknown optional data, not feature negotiation.

## Constant gain syntax profile (execution unsupported)

`audioGain.constant.v1` is a second opt-in, fail-closed graph v1 syntax profile;
the graph version stays 1. Graph v1 recognizes a closed, fixed set of exact
`requiredFeatures` arrays, not a registry:

- `[]`
- `["audioGain.constant.v1"]`
- `["audioMute.constant.v1"]`
- `["audioGain.constant.v1","audioMute.constant.v1"]`

Any other array, including reversed order, duplicates or an unknown token,
rejects as unsupported before node decoding. After bounded node decoding the
declaration must equal exactly the sorted tokens for the gain/mute kinds present
(gain nodes need the gain token, mute nodes the mute token, both need both, and
neither needs `[]`); otherwise `invalidRequiredFeatures`. Nothing is inferred,
sorted or repaired.

An `audioGain` requires an explicit JSON number `linearGain`, a linear factor
(not decibels; unrelated to `gainCeilingDb`). It must be finite, normal, greater
than zero, at most 16 and exactly representable as a normal Float32
(`Double(Float(g)) == g`): `0.1` rejects while `0.10000000149011612` is accepted.
Zero, negative zero, negative values, subnormals, NaN and infinities reject; there
is no zero gain or polarity inversion (silence is mute's job). Missing, null and
non-number values reject; there is no default. Shape matches mute: exactly one
audio input and one audio output with matching 1–64 channel widths and no role,
asset or graph reference. Errors are `invalidGainState` (missing value, typed
value on another kind, unknown-field collision), `invalidGainValue` and
`invalidGainShape`. Finite out-of-range values round-trip through coding and
reject in validation; encoding refuses only nonfinite values and state errors.

Documented semantics, not implemented: per channel and sample the output is
`Float32(input) × Float32(g)` as a single round-to-nearest multiply, never fused
with other operations; `g = 1` is bit-exact. The value is constant per prepared
graph.

Gain and mute are separate nodes. `linearGain` is known only on `audioGain` and
`muted` only on `audioMute`; on every other kind (including each other) they are
preserved unknown data, reported by strict validation. Typed state on the wrong
kind, or an unknown-field collision, rejects validation and encoding.

This is contract only: the offline routing compiler refuses every gain node as
`unsupported`, including valid disconnected gains. Project and package envelopes
still reject all nonempty features, including the gain token.

### Bounded offline routing execution

The offline routing compiler retains its no-mute subset and accepts **at most
one** valid constant `audioMute`. Edges may only be role-input → role-output,
role-input → mute, or mute → role-output, with at most one incoming edge per
destination. Role bindings are unique among role endpoints. Identity edges and
ordered explicit maps (including duplicate terms) work on every allowed edge.
Fanout, direct routes beside the mute and disconnected endpoints are allowed.
Two or more mutes refuse even when independent or disconnected; chains,
cycles/feedback, other node kinds, unsupported metadata, capabilities or
references, malformed contracts and over-budget graphs refuse. Portable syntax
validation alone does not grant this narrower executor's support.

All external active inputs, even unused ones, are staged and finite-checked.
Every mute input channel/frame is then materialized through its incoming map;
an unconnected input is positive zero. A separate result slab bit-copies that
mapped input for false or stores positive zero for true. This work is never
skipped for true, unused channels, absent consumers or a wholly disconnected
mute. Output maps read the result, never substitute upstream sources or flatten
across the primitive. Identity copies preserve negative zero; explicit maps
add in declared Float32 order from positive zero, even a single-term `[[0]]`,
and check every intermediate sum. False's bit-copy promise applies to the
primitive input, not surrounding maps. Prepared state is immutable; document
changes require new preparation.

Geometry and all full-slab overlap checks (including padding) precede audio
access. Valid zero-frame calls only zero peaks. Outputs and peaks commit in
stable endpoint order only after all computations succeed. Numerical refusal
silences all active external outputs/peaks, leaves padding untouched and permits
same-instance recovery; geometry refusal touches nothing.

Caller limits are unchanged. For maximum frames `F`, external channels `I/O`,
mute width `C` (zero without a mute), and `T` terms across **all** edges including
duplicates and every fanout, scratch floats are `max(1, F*(I+2*C+O)+O)` in
input | mute-input | mute-result | output | peak order. Sample work is
`F*(2*I+T+4*O+4*C)+2*O`, identically charged for either state and disconnected
mutes; primitive work is separate from the term limit. Arithmetic, slab offsets
and term boundaries are checked before arena allocation. Collection/map
preflight precedes dictionaries, sorting, full validation and lowering.
Two-channel, 16-frame identity costs 264 bytes/228 work/2 terms; inserting a
two-channel mute with identity edges costs 520 bytes/388 work/4 terms.
This is allocated-buffer offline execution only, not RT qualification, a backend
seam, activation custody, live routing or hardware evidence.

Each document is at most 4 MiB. Graphs allow 4,096 nodes, 16,384 edges, 256 ports
per node and 1,024 capability definitions/references per node. Limits apply before
topology validation and during coding. Graph topology checks are iterative.

`GraphEdit` carries normalized connect/disconnect/add/remove/move payloads.
`applying` checks bounds and contradictions, returns a candidate, and changes no
revision. Validate the candidate separately. Removing a node cascades existing
edges but cannot silently erase a new connection in the same batch. Opposing or
duplicate operations reject. Draft commands must match normalized operations of
one unambiguous named draft; duplicate command operations reject. This is payload
consistency only—#62 owns freshness, permissions, review and commit.
