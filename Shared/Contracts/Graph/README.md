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

## Constant mute syntax profile (execution unsupported)

`audioMute.constant.v1` is one opt-in, fail-closed graph v1 syntax profile.
`requiredFeatures` stores the exact supplied candidate array: it must be `[]`
without mute nodes, or exactly `["audioMute.constant.v1"]` with one or more
`audioMute` nodes. Construction and mutation never infer, sort, deduplicate,
insert or remove features; validation, decoding and encoding reject mismatches.
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

Recognizing this syntax does not mean executor support. The current offline
routing compiler remains unchanged and refuses every mute as `unsupported`,
including disconnected mutes. This contract adds no DSP execution, live control,
physical-mute acknowledgement or activation authority. Older graph readers
reject the feature marker before interpreting the new kind; they do not support
the profile. Project and package envelopes still reject all nonempty features,
including this graph token. Integer-major checks are unchanged; `minorVersion`
remains unknown optional data, not feature negotiation.

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
