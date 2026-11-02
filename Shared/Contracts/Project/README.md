# Portable project v1

`ProjectDocument` stores portable roles, pinned graph references, patch references,
asset references and per-action media policy. It contains no device routes, runtime
clock stamps, host authority, plugin instances or embedded media bytes.

Use bounded `decode(from:)` / `encoded()` and then `validate(graphs:)`.
Every collection is capped at 4,096 records and each document at 4 MiB. Supplied
graphs must resolve the exact pinned revision. Duplicate supplied identities,
dangling references, incompatible role ports and recursive shared-graph references
reject. Patch variation deltas and shared-instance execution belong to #104.
Role, asset and supplied-graph lookups retain the first occurrence; duplicates
still reject in document order. Each referenced graph/revision pair is checked
once, including missing revisions. Different pinned revisions remain distinct.

Roles have their own stable `RoleID`; #55 consumes that ID in host-local bindings,
whose identities and confirmation evidence are separate. Graph/node/port identity
is never inferred from a console connector number.

Assets have content digests (`sha256:` plus 64 lowercase hexadecimal digits),
optional nonnegative byte counts and explicit allowed audio/MIDI time policies.
Untimed documents declare neither timing nor an audio/MIDI policy.
Media players require audio or MIDI assets, never documents. Every audio/MIDI
output must match the asset's media; auxiliary control/clock ports are unchanged.
This check neither converts media nor grants preparation or activation authority.
Timing values are asset-relative frames, musical ticks (15360 per quarter) and
nanosecond offsets; they are not host ticks or live render-clock positions.
Recorded source anchors/fidelity remain capture metadata, not invented by import.

`ProjectMediaAction` references an asset and reuses #55's `ActionID` and
`ActionPolicy`. Time policy, late policy, retroactive tolerance, grid and stopped
policy persist per action; two actions may use the same asset differently.
The action media must match the referenced asset. Nothing here schedules a trigger.
Unknown optional fields and explicit extension bags remain separate and round-trip.

Shared `JSONValue` encoding writes exact integral doubles as `Int64` or `UInt64`
where representable, and `-0.0` as `0`; other finite doubles keep their double
encoding. Large integral doubles may therefore be written as integers rather
than exponent notation. This canonicalizes numeric representation only: it does
not normalize Unicode or preserve the original JSON bytes.

## Legacy adoption

`StudioGraphNeutralAdapter.adapt(graphData:endpointsData:id:)` reads the existing
legacy Codable wire format using only Foundation/CoreGraphics and contract values.
It returns both exact original byte sequences and a new graph at the initial
revision. Storage owners must retain the original bytes alongside the new document.
The graph also retains complete decoded originals as inert `legacyStudio` evidence,
including endpoint connectors, reviewed-output references, placement and unknown data.

Canvas geometry is copied without coordinate normalization. Imported audio ports
have unconfirmed channel counts. All imports require review; console observations
become non-routable shortcuts with no ports. Equipment/endpoint role IDs use distinct
legacy namespaces. No USB mapping, authority, current device evidence or compatibility
with a future contract version is inferred. Versioned input is not accepted as legacy.
