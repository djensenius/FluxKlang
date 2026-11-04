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

## Package manifest v1

`ProjectPackageManifest` describes the reserved root member `manifest.json`, with
contract `fluxklang.project-package` and version `1`. It records one project,
pinned graphs, digest-keyed resources and opaque-state members. Member paths are
explicit package-root-relative paths, not names derived from identities.
Resources have optional embedded media and a required bookmark-candidate array;
candidate order grants no preference or access authority. Unknown optional fields
and extension bags round-trip semantically, not as original JSON bytes.

The caller supplies finite P1 package limits and a manifest-byte ceiling.
Declaration checks reject duplicate ownership, file/ancestor collisions,
oversized claims and entry/byte-budget overflow. Decoding counts original
manifest input bytes; encoding counts actual output bytes. Reference checking
has neither the original manifest bytes nor their length and does not recreate
that byte-inclusive total. External asset lengths are not bookmark byte counts
or package consumption. Identity checks preserve inert `requiresReview` intent
without claiming graph readiness, resource availability or activation authority.

The manifest itself performs no filesystem access or bookmark resolution.

## Package reader and writer

`ProjectPackageReader` reads a directory package with one P1 admission attempt.
The root's final path component is opened with `O_NOFOLLOW`; its ancestors
resolve normally. Below the root, each entry is inspected with
`fstatat(AT_SYMLINK_NOFOLLOW)` and admitted by P1 before it is opened relative to
its already-open parent with `O_NOFOLLOW`, then matched by device, inode and type.
Symbolic links at any level, FIFOs, sockets and devices are refused through P1 as
unsupported kinds. Regular files with more than one hard link
(`hardLinkedMember`) and entries on a different device from the root
(`crossedMountPoint`) are refused before they are opened, and the same check
is repeated on the opened descriptor's status, so a link added between
admission and open cannot become the change-detection baseline. A link added
while reading usually changes the status-change time and refuses as
`memberChanged`; on filesystems with coarse timestamps it may go unnoticed, but
the member had a single link when opened, so a later link cannot alias outside
content into the package.

Each read request is bounded before IO, each delivered chunk is charged once
before it is retained, a zero allowance probes for one more byte rather than
assuming EOF, and a member finishes only after an actual zero-byte read.
Declared lengths are never preallocated. At EOF the open member is re-checked:
a changed size, modification time or status-change time, or a size different
from the bytes read, refuses with `memberChanged`.

The resulting `ProjectPackageContents` retains the original manifest bytes and
the original bytes of every member, including undecoded/unsupported listed
members and unlisted files and directories. Listed members must exist as regular
files and embedded media must match its `sha256:` content digest. Values come
only from the reader or from in-memory construction, which runs the same P1 pass
and checks.

`ProjectPackageWriter` accepts only a `ProjectPackageContents` value, so every
write has passed manifest, membership and digest verification. It also
re-admits every path through P1 before any IO, so escaping, absolute, duplicate
or parentless paths write nothing. It opens the destination's parent with
`O_DIRECTORY|O_NOFOLLOW`; a parent that is a link or not a directory is refused
with `destinationParentRefused`. It then creates the destination with
`mkdirat` (an existing name is refused) and opens it relative to that parent
without re-resolving the path. Members are created exclusively with no-follow,
descriptor-relative calls, the original bytes are written unchanged, and each
file is `fsync`ed. If a later IO step fails, partial output stays in the new
destination for the caller to discard.

Non-goals:
- The reader does not hash or snapshot content during reads, so a change that
  keeps size and both timestamps is not detected.
- Nothing prevents another process from swapping the destination between
  `mkdirat` and `openat` for a different directory.
- `crossedMountPoint` and device-node refusal are not exercised by tests,
  because creating a mount or a device node requires root.
- The writer is not an atomic replace, staged export, file-coordination or
  iCloud step, and it does not clean up partial output.
- The writer does not defend against concurrent mutation of the new
  destination. It reopens subdirectories by name, and it keeps writing through
  directory descriptors it already holds, so a subdirectory renamed while the
  write runs, including one moved outside the destination on the same volume,
  receives the remaining members wherever it now lives. Discarding the
  destination does not remove that output. Callers must give the writer a
  destination no other process mutates until the write returns.

Project and graph documents are not decoded here. Migration, bookmark
resolution, document lifecycle and activation remain separate obligations.
