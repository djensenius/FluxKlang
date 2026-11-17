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

### Environment adoption

`LegacyEnvironmentAdoption.adopt(environmentsData:environmentID:...)` adopts one
environment from `EnvironmentStore`'s `environments.json` bytes. The bytes are bounded
by the package entry limit and the 4 MiB ceiling before decoding, then decoded
strictly; the top level must hold an `environments` array of objects with a UUID `id`
and a string `name`. Exactly one environment must match the requested ID (missing or
repeated IDs refuse). Its `studioGraph` and `studioEndpoints` are re-encoded canonically
and passed to `LegacyAdoption.adopt`; a missing graph adopts as empty. The whole
original file is kept unchanged at `legacy/Environments.json` as opaque state, so other
environments and unknown members survive. `studioSetup` (local plug mappings) and the
WING `graph`, `effects` and `placements` are never interpreted: they gain no role,
patch or authority, and the graph still requires review.

Unlike direct adoption, `legacy/StudioGraph.json` and `legacy/StudioEndpoints.json`
hold canonical re-encodings of the selected environment's members, not original
bytes; the true original is `legacy/Environments.json`. The whole file must fit one
package entry and is charged against the package total alongside the re-encoded graph
and endpoints, so a large `environments.json` is refused (`oversizedInput`, or an
assembly refusal) even when the chosen environment is small.

Still open: running migration over real on-disk stores, adopting sidecars from the
global stores, app wiring, and splitting or per-environment retention of large files.

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
- The writer detects concurrent mutation of the new destination but does not
  prevent it. It keeps the destination's parent open and records the device
  and inode of the destination and of every directory it creates. Before each
  entry it re-checks the destination's name and re-opens the entry's parent
  chain from the root with `O_NOFOLLOW|O_DIRECTORY`, comparing each component
  with its recorded identity. After each entry, and when creating an entry
  fails, it checks the held parent again by name; a failed create whose
  parent still matches keeps its own error. After the last entry it re-walks
  every recorded directory. A replaced, moved, missing or non-directory
  component, or a link, refuses with `destinationChanged`. Output already
  written stays where it is: a directory moved outside the destination while
  the writer held it keeps the member written into it, and discarding the
  destination does not remove that output. Not covered: a swap between
  `mkdirat` and the `openat` that records the new directory (Darwin has
  neither a descriptor-returning `mkdirat` nor `O_BENEATH`), a rename away and
  back between two checks, files renamed after they are closed, and any
  emptiness or link-count check for an impostor directory (APFS link counts
  are not a reliable signal). The device (`st_dev`) half of the identity
  comparison is verified by code reading only, because the tests run on a
  single volume.
  Callers should still give the writer a destination no other process
  mutates until the write returns.

The reader and writer do not decode project or graph documents; that is the
next layer.

## Package documents

`ProjectPackageDocuments(contents:)` decodes the project and every pinned graph,
in manifest order, only from the original bytes of their listed members, then
runs the manifest's `validateReferences`. It deliberately does not call
`ProjectDocument.validate(graphs:)`: graph and project validation is the
caller's job, so packages whose graphs require review stay readable.
The source `ProjectPackageContents` is retained unchanged, including opaque,
unlisted and resource members.

`ProjectPackageContents.make(project:graphs:extraFiles:policy:)` encodes the
project and graphs at caller-chosen member paths, records their actual byte
counts, lists `.opaqueState` extra files in supplied order and keeps `.unlisted`
ones out of the manifest. Extra files keep their exact bytes; other roles,
including resources, are refused. Parent directories are derived from the
member paths. The manifest is encoded within the P2 policy, references are
checked, and the result passes through the same in-memory P1/P3 construction.
Documents round-trip semantically (unknown fields and extension bags), in
canonical encoding rather than their original bytes.

Refusals are typed `ProjectPackageDocumentError` cases: undecodable, future
version or unsupported `requiredFeatures` (unsupported), unversioned or older
(legacy, never upgraded here), over-limit (bounds), unencodable (`make` refuses
documents the encoder rejects, e.g. unsupported `requiredFeatures`), or wrapped
P1/P2/P3 errors. `version: 0` and wrong-contract documents are reported as
undecodable, not unsupported. Refusals carry only graph IDs, never paths,
payload bytes or Foundation text. Graph documents above 4 MiB or beyond the
package limits refuse before decoding; nothing here does file IO.

`make` charges extra files against the entry and total byte limits before
encoding anything, then each document as soon as it is encoded, so the first
member that crosses a limit refuses before later graphs are encoded. These size
checks run before path uniqueness, so input that is both oversized and has a
duplicate path (a repeated extra, or an extra sharing a document's path) may
report a size error rather than `duplicatePath`; it is refused either way.

## Package inspection

`ProjectPackageInspectionLoader` opens a package read-only: one reader pass
under its reviewed admission policy (4,096 entries, depth 16, 1,024 path bytes,
8 MiB per member, 32 MiB total, 1 MiB manifest, 64 KiB chunks), then
`ProjectPackageDocuments` decoding. `ProjectPackageInspection` keeps those
documents whole and adds diagnostics: the first 256 non-strict validation
errors plus a dropped count, graphs that require review, member counts by role,
the directory count and total bytes. Nothing is written, resolved, migrated,
confirmed or activated, and no revision advances. Every failure becomes a
`ProjectPackageInspectionRefusal` case with no payload, so no path, bookmark,
identity or OS/decoder text escapes. `load(at:)` runs off the caller's actor;
a started read always finishes, and a task cancelled meanwhile gets
`.cancelled`, never the payload.

## Staging on a real disk

`DiskStagingFileSystem` runs staged export, import and recovery on a real
directory. It holds the volume root and its parent open by descriptor and
re-checks the root's name and identity before every primitive. Paths are
resolved from the root one `O_DIRECTORY|O_NOFOLLOW` component at a time; an
empty, `.`, `..` or NUL-containing component is refused with `.denied` before
any IO, and no link is followed. Directories the adapter creates have their
device and inode recorded; a recorded directory that is replaced, moved,
retyped or swapped for a link, a renamed or replaced root, or a link used as
a path component fails with `StagingIOFault.changed`. Records are keyed by the
path's UTF-8 bytes, so an alias spelling (case or Unicode normalisation) is
treated as unrecorded. Every listing reads through a fresh descriptor. Files
are created exclusively and `fsync`ed, directories are synced with `fsync` (not
`F_FULLFSYNC`), and `rename` uses `renameatx_np(RENAME_EXCL)`, so it never
replaces. `removeTree` never follows a link, never removes (or descends into)
a recorded directory whose identity changed, never crosses onto another device
(`.crossVolume`), and counts and checks the whole tree within the package
limits before it removes anything.

Non-goals:
- It detects concurrent mutation; it does not prevent it. A change between a
  check and the call it guards is not caught.
- It is not a file coordinator. A replace is two renames, not an atomic
  `RENAME_SWAP`; second-volume (`EXDEV`, `st_dev`) behaviour is not exercised
  by tests.
- The backup name lies inside the confined root but was never created by the
  adapter, so it is not identity-checked before it is removed.
- Nothing in the app uses the adapter yet.

Later slices own migration and adoption, including packaging legacy imports,
app wiring of staged export and import, and an atomic swap replace. Bookmark
resolution, document lifecycle and activation also remain separate obligations.
