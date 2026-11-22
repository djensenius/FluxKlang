# Mac and iOS audit-run preparation (partial regression only)

`prepare.py` is an external, Python-standard-library preparer, **never a test
launcher**. It generates a fresh UUID4 before any hypothetical future launch.
Existing profiles remain metadata-only with no subprocess or native-tool calls.
The explicit runtime-backed profile below adds read-only native verification.
No profile imports app/production modules, boots a simulator, installs an app,
launches tests, or emits hardware actions. There is no in-app fallback or
conditional audit no-op.

## Closed profiles and unchanged original behavior

`mac-isolated-unit` supports only the reviewed Debug hosted-Mac XML plist
FormatVersion **1** layout:

- Exactly `FluxKlangMacTests` and `__xctestrun_metadata__` at the top level.
- Scheme `FluxKlangMacIsolatedTests` in both metadata and
  `TestingEnvironmentVariables.XCODE_SCHEME_NAME`; exact module/provider/host
  identities and `IsAppHostedTestBundle = true`.
- Host `__TESTROOT__/Debug/FluxKlangMac.app`, bundle
  `__TESTHOST__/Contents/PlugIns/FluxKlangMacTests.xctest`, and the two matching
  observed `DependentProductPaths`.
- Literal strings `FLUXKLANG_ISOLATED_TESTING=1`,
  `FLUXKLANG_QUALIFY_APPLE_ROUTING=0`, and `FLUXKLANG_RUN_APPLE_MODEL_TESTS=0`
  already present in the actual target `EnvironmentVariables`. Preparation adds
  only `FLUXKLANG_AUDIT_RUN_ID` there; it does not fix missing/wrong flags.

`ios-simulator-isolated-unit-ui-v1` supports only the reviewed combined Debug
iOS simulator XML plist FormatVersion **1** layout:

- Exactly `FluxKlangTests`, `FluxKlangUITests`, and `__xctestrun_metadata__`.
  Neither a unit-only nor a UI-only subset is supported.
- Scheme `FluxKlangIsolatedTests` in container metadata, both targets'
  `TestingEnvironmentVariables`, and `UITargetAppEnvironmentVariables`.
- Unit app host `__TESTROOT__/Debug-iphonesimulator/FluxKlang.app`, bundle
  `__TESTHOST__/PlugIns/FluxKlangTests.xctest`, and app-hosted identity.
- UI runner host
  `__TESTROOT__/Debug-iphonesimulator/FluxKlangUITests-Runner.app`, bundle
  `__TESTHOST__/PlugIns/FluxKlangUITests.xctest`, runner-hosted/UI identities,
  and UI target app `__TESTROOT__/Debug-iphonesimulator/FluxKlang.app`.
  Both targets require the four observed dependent products in their exact order
  and all distinct provider/module/bundle/host identities.
- The same literal `1/0/0` flags described above must already be present in
  both targets' `EnvironmentVariables`. They must remain **absent** from the
  observed UI target-app environment metadata.
- One fresh external UUID4 is added as `FLUXKLANG_AUDIT_RUN_ID` at exactly three
  locations: unit `EnvironmentVariables`, UI `EnvironmentVariables`, and UI
  `UITargetAppEnvironmentVariables`. No other value is added or changed.

The original reviewed input key/value/type allowlists are `OBSERVED` and
`IOS_OBSERVED` in `prepare.py`; the runtime-backed profile changes only the two
explicitly described input fields below. All profiles require **all observed values**,
including unrelated diagnostic, logging, environment, timeout, language, and
attachment fields, including `SystemAttachmentLifetime = deleteOnSuccess` and
`UserAttachmentLifetime = deleteOnSuccess` on every test target. Except for the
explicit profile transformations described here, parsed values and supported
Xcode path placeholders are preserved exactly; XML
formatting/key order need not be byte-identical. No placeholder is expanded and
no app/test product is opened. The runtime-backed profile independently inspects
its fixed tools and runtime library. No arbitrary configuration switches exist.

Unknown/missing fields, changed values, alternate layouts, binary plists,
FormatVersion2, duplicate plist/JSON keys, unsupported scalar types, ambiguous
metadata, filters (even empty), extra targets, unreviewed host markers, alternate
audit environments, conflicting schemes, and unresolved audit placeholders are refused,
not silently dropped. Any preexisting run identity is refused, including a valid
UUID, an empty value, or a malformed value. Even matching audit keys in
`TestingEnvironmentVariables` are outside all profiles. Cross-platform inputs
and cross-profile intents are refused, including old/new profiles on the same
platform; a rehashed output still must match the full permitted transformation.

**Explicit exclusions:** other iOS layouts/destinations, full-regression claims,
Release, live Apple qualification, and any other target composition. Existing
app/UI targets are unchanged; this utility never removes tests or presents skipped tests as green.
The retained layout specimens are read-only metadata examples, **not
execution-ready artifacts**.

## Explicit runtime-backed MainThreadChecker profile

`ios-simulator-isolated-unit-ui-xcode27.1-runtime27.0-mtc-v1` is a separate,
opt-in profile for #708. It preserves MainThreadChecker rather than disabling
diagnostics or broadening the original iOS profile. It accepts only two input
differences from `IOS_OBSERVED`:

- Unit `TestingEnvironmentVariables.DYLD_INSERT_LIBRARIES` is exactly XCTest
  injection, the verified checker, then RPAC, in that order.
- UI `TestingEnvironmentVariables.DYLD_INSERT_LIBRARIES` contains only the same
  checker spelling. UI target-app DYLD injection and
  `UITargetAppMainThreadCheckerEnabled` remain absent.

The generated strings are preserved, not rewritten. Only the original three
run-ID insertions are made; no retention request or runtime-authority record is
added to the intent.

Selecting this profile in **either** `prepare` or `validate` invokes
`ios_runtime.py` for fresh, read-only verification. It uses the reviewed
`/Applications/Xcode_27.1.app/Contents/Developer` path, ignores caller toolchain
environment overrides, and never changes `xcode-select`. Apple-signed native
tools must report Xcode 27.1 build `27A9275`, simulator SDK 27.1, and one
available `com.apple.CoreSimulator.SimRuntime.iOS-27-0` runtime with version 27.0
and build `24A434` on a Darwin arm64 host.

The checker is derived from that live inventory, never from candidate DYLD
text. Descriptor-relative, no-follow filesystem checks bind root-owned,
non-group/world-writable ancestors, tools and checker. The runtime `Info.plist`
is a distinct non-executable case: the reviewed artifact measured root-owned
`0664`, not `0755`. That exact regular-file shape is accepted **only** when
`fstatvfs` on its held descriptor freshly proves a read-only filesystem, checked
again on exit. Writable or unavailable mounts are refused; this exception does
not apply to ancestors, tools or the checker. The only alternate spelling is
the standard `/var` to `/private/var` alias, positively checked for ownership,
link destination and filesystem identity. Other aliases, unreviewed layouts,
path replacements and mutable/unavailable paths are refused, even if their
names or advertised versions look correct.

The file must be a 338880-byte, root-owned `0755`, thin arm64 Mach-O with SHA256
`1ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8`.
Fresh `codesign --verify --strict` enforces both
`identifier "com.apple.libMainThreadChecker"` and `anchor apple`. Tool calls
have a 30-second deadline, at most one additional 30-second cleanup wait, and a
2 MiB merged-output bound. Cleanup attempts to kill only the owned child and
closes its output even if killing or waiting fails; no implicit unbounded wait
is used, and unsuccessful cleanup cannot return success. Inventory, file
identity/content, runtime plist and alias are rechecked before returning
success. The runtime plist identifier must match; its bundle version `392`
is not treated as runtime build `24A434`.

Evidence for these closed pins is diagnostic run `43678288031`, artifact
`14146952925`, reviewed head `4d3451fbd1b3a129681205dc0dce6c6f86863bed`.
That run did not launch tests or establish candidate filesystem binding.
The new verifier's acceptance on a real host is a separate observation;
the diagnostic did not measure the plist's read-only mount flag or every tool
ancestor's permissions. Those live checks remain required and unproven on the
host; unsupported layouts must not be repaired by relaxing them.

Use the commands below with this explicit profile identifier. A previously
successful intent is not reusable authority: any separately authorized runner
must call `validate` again with the original pin and exact output/intent paths
**immediately before launch**. Validation performs fresh verification; no
serialized context or `verified` flag can bypass it. This utility has no
launch capability and does not certify earliest-host isolation, installed
guards, environment delivery, sandbox access, receipts, or #60 qualification.
The existing four profiles remain metadata-only and retain their original
inputs, outputs, CLI claims and platform independence.

## Explicit provider-trusted lower-assurance runtime profile

`ios-simulator-isolated-unit-ui-xcode27.1-runtime27.0-mtc-provider-trusted-v1`
is a distinct source-only preparation/validation profile. It uses the same
closed iOS input metadata, fixed Xcode 27.1 build `27A9275`, simulator SDK
27.1, iOS 27.0 runtime build `24A434`, checker digest, Apple-signature
requirement, and exact ordered MainThreadChecker DYLD values as the strict
runtime-backed profile above. It accepts only the inventory-derived fixed
canonical checker path or its standard `/var` spelling; input strings never
select paths for filesystem or tool probes. Unknown/ambiguous identities,
runtime entries, paths, metadata, or checker values are refused. Tool output
and reads are bounded, and the fixed observations are rechecked on exit.

Its provider-only intent field `provider_observation` uses the closed
`ios-provider-trusted-runtime-observation-v1` schema. It records only values
this preparer observes: fixed Xcode path/version/build, SDK version, Xcode tool
file metadata and Apple-anchor check results, the selected runtime's exact
inventory identity/version/build/availability/bundle paths, and the checker
path/accepted spelling(s), size, SHA256, architecture and signature-check
result. These remain observations under the stated trust assumption, not
authenticated provenance. The provider-profile outer intent uses integer
`schema_version: 3`: the standard intent fields plus exactly
`provider_observation`. That object has exactly `schema`, `xcode`, `runtime`,
and `checker`. The nested closed keys are:

- `xcode`: `developer_directory`, `version`, `build`,
  `simulator_sdk_version`, `xcodebuild_path`, `xcodebuild_file_identity`,
  `xcodebuild_apple_anchor_check`, `simctl_path`, `simctl_file_identity`,
  `simctl_apple_anchor_check`.
- `runtime`: `identifier`, `version`, `build`, `available`, `bundle_path`,
  `runtime_root`.
- `checker`: `canonical_path`, `accepted_paths`, `size`, `sha256`,
  `architecture`, `signature_requirement`, `signature_check`.

The typed `ProviderRuntimeObservation` record in `ios_runtime.py` defines the
same shape. Validation compares the whole record, rejecting changed versions,
missing/extra keys, or altered observations. The field is absent from every
other profile; schemas 1 and 2 remain unchanged.

The assurance boundary is different: this profile explicitly trusts the
disposable GitHub-hosted VM/image and reviewed job/toolchain. Its ownership,
version, digest, signature, and filesystem checks are observations on that
trusted provider environment, **not** independent provenance or proof of
custody. In particular, rechecking files or observing a matching version or
digest does not defend against hostile same-job code, mutable tool replacement,
or a compromised provider. Do not use this profile to make the strict
profile's stronger filesystem-authority claim; the strict implementation and
its acceptance/refusal semantics are unchanged.

### Opt-in bounded provider material preparation and validation

The provider profile alone supports `prepare(..., bounded_material=True)` and
`validate(..., bounded_material=True)`, or `prepare.py prepare --bounded-material`
and `prepare.py validate --bounded-material`. Both require the explicit input,
expected SHA256 and profile; validation also requires output and intent paths.
Other profiles refuse this option. It is not the default: existing prepare and
validate APIs and profiles retain their legacy behavior.

This option acquires exactly the selected original, output, and intent as
immutable bytes and applies the same pin, original XML, transformation, UUID,
sibling, intent schema, and fresh provider-observation checks to those bytes.
There is no legacy path-read fallback. Each file has a 2 MiB limit plus one
detection byte; at most 6,291,459 bytes are acquired across all three. Every
selected path must be a canonical absolute UTF-8 path of at most 4096 bytes
and 64 components, including its filename. At most 195 material-walk
descriptors are held (three paths, each with a root and 64 components);
provider and interpreter descriptors are additional. The component cap is a
conservative refusal limit, not a measured hosted path depth.
These are conservative refusal limits based on existing `build_receipt`
precedents, **not** measured iOS candidate sizes or evidence an actual pair
fits. Descriptor-relative no-follow walks refuse symlinks and special files;
file and directory identities are checked at acquisition and validation
boundaries. Growth, visible replacement or mutation, read failures, and cleanup
failures refuse. All registered closes are attempted. A control-flow exception
(such as `KeyboardInterrupt` or `SystemExit`) raised during cleanup takes
precedence over an ordinary active exception; an already-active control-flow
exception takes precedence over later cleanup failures. An ordinary active
exception takes precedence over later ordinary cleanup errors. Asynchronous
interruption between opening and registering a descriptor or during cleanup
can still prevent complete cleanup, and a failed close is not retried.
Transient changes between checks can still escape detection; this is not
custody, race freedom, or a hard RSS bound.

Bounded preparation holds and rechecks the explicit pinned input and exclusively
creates its UUID-linked output and schema-3 intent siblings relative to the
held parent directory. It caps serialization before publication, handles short
and zero writes, holds the created descriptors, and invokes the real bounded
validator. Both provider contexts must complete their exit rechecks and the
complete fresh observations must agree before success. Each bounded provider
context compares its complete exit snapshot type-sensitively: at most 1024
value nodes, depth 16 from the root, and 8,388,608 combined bytes/string
codepoints including dictionary keys across both snapshots. Integers are at
most 4096 bits; unsupported values or excess refuse. Legacy provider comparison
is unchanged. After the input walk's exit check and ancestor closes, a fresh
no-follow walk compares the whole path chain and held input identity to the
original, then rechecks both created paths
relative to the reopened parent. Duplicated original directory descriptors keep
their identities alive across ancestor closes and the fresh walk; the input,
original parent, created files and reopened directories also remain held.
There is no legacy input/output path-read fallback. Serialized scalar strings are additionally
limited to 131072 characters and integers to 4096 bits; the closed metadata and
provider observation are expected to be far smaller.
Both bounded preparation and validation use precedence-aware provider-file,
selector, owned-child and stdout cleanup. They attempt all registered cleanup
and apply the same exception precedence described above; the bounded child
cleanup wait remains limited to 30 seconds. Child cleanup is protected directly
after `Popen` returns, without callback registration. Interruption between a
resource acquisition and entering its cleanup-protected region, interruption
during cleanup, or a spawn failure before a child handle is returned can still
prevent complete cleanup. Legacy provider cleanup is unchanged.

On **any failure**, this opt-in producer never unlinks created files. Partial or
complete output/intent siblings can remain, possibly containing sensitive
metadata. Collisions and replacements are never overwritten or removed. Use an
authorized disposable workspace and clean it separately under the caller's own
namespace authority. Each invocation writes at most 4 MiB, but repeated failed
attempts can accumulate unbounded debris and disk use. Publication is neither
atomic nor durable; asynchronous interruption, crashes, transient changes
between checks, and descriptor registration/close failures remain possible.
These checks do not establish custody or race freedom.

For one successful bounded preparation, at most 262 material descriptors are
simultaneously held: 65 for the outer input, two created files and 195 for the
nested validator. Up to 64 duplicated directory anchors are retained before
ancestor closes; the final rewalk opens up to 64 additional directory
descriptors and holds at most 132 material descriptors at that later stage.
At most 326 material opens and 64 descriptor duplications occur over a
successful invocation. The rewalk does not reread material bytes. Interpreter
and provider descriptors are additional. The input is acquired twice and each
sibling once, for at most 8,388,612 material read bytes including detection bytes.
Each of four provider snapshots separately reads the checker twice and its
plist once, at most 11,099,660 bytes in total including detection bytes. They
run at most 24 fixed commands, each with a
2 MiB plus one detection-byte output limit. These counts do not bound XML/JSON
parser or serializer heap use or time, interpreter overhead, child-process
resources, or filesystem operations.

Legacy preparation and its internal validation still use unbounded path reads,
including for the provider profile. Bounded validation does not make earlier
legacy preparation bounded. Exact compile-produced candidate selection, checker
path/handoff, source coverage, real candidate acceptance and hosted integration
remain separate work.

This preparation slice does **not** claim source commit/head, runner identity,
workflow/job provenance, or that those values are bound to this observation.
It intentionally does not trust ambient environment variables to supply them.
Closing that gap needs a separate, reviewed hosted-runner issue: bind the
checked-out source/head and workflow/job/run/runner attribution to this typed
observation, then review a no-launch hosted measurement. Any launch integration
or test attempt remains a later, separately authorized and reviewed scope.

This profile does not select or verify a simulator device and has no launch
integration. It is not evidence of #60 isolation, denial of production service
access, receipt custody/coverage, or production readiness. It changes no
feature defaults, guards, receipt behavior, CI triggers, provisioning, or
privileged state and authorizes no hosted dispatch, simulator, test launch,
hardware access, or credentials.

### Standalone provider/job attribution observations (#893; source-only)

`provider_attribution.py` adds `observe(context_reader, object_reader)` returning
canonical JSON bytes and `validate(bytes, context_reader, object_reader)` requiring
fresh identical observations. Neither writes output. The separate closed schema
`ios-provider-job-attribution-observation-v1` leaves all preparer schemas/profiles
(including schema 3) and #707 untouched. It is **provider/job-reported observation,
not authenticated provenance**, a receipt, reusable authority, or iOS qualification.

`github_context.read_context(environment, event_bytes, checkout_sha)` supplies
only the context projection. All inputs are explicit: it does not read ambient
environment, files, Git, or the network, and `checkout_sha` is a caller-reported
string, **not a verified HEAD**. The first argument must be a plain dictionary
with exactly these keys (not an environment dump):

```text
GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REF
GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_JOB
RUNNER_NAME RUNNER_ENVIRONMENT RUNNER_OS RUNNER_ARCH
GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA
```

Each value is a nonempty string of at most 512 characters, except the workflow
pair may both be `None` when unavailable. IDs are canonical positive ASCII
decimal integers at most 2^63-1. The workflow path is derived from the reported
repository-qualified workflow ref; the envelope's existing closed validation
checks the complete context. No workflow SHA is inferred from checkout SHA.
The second argument is UTF-8 JSON bytes, at most 1 MiB, with duplicate keys and
nonfinite numbers refused, including in otherwise ignored provider fields.
JSON integer tokens are limited to 32 characters and floating tokens to 128;
malformed or excessively nested input refuses. Additional event fields are
ignored, not projected. Required `repository.full_name` must match the reported
repository. Push requires matching `ref` and `after`; workflow_dispatch requires
matching `ref`. Both refuse non-null PR identity. Pull request requires matching
top-level and PR numbers, base repository identity, and head/base SHA fields.
Its reported merge SHA comes only from `GITHUB_SHA` and must match the separately
supplied checkout SHA; the payload's `merge_commit_sha` is not substituted. The
envelope's raw commit parent check remains necessary to check the reported
merge/base/head relationship.
Unsupported events and missing, malformed or conflicting fields refuse.

A future reviewed runner must obtain fresh explicit inputs for **each** envelope
snapshot; reusing a frozen projection cannot detect later context changes.
The caller owns safe bounded event-file reading, path handling and selection of
the reported checkout SHA; this adapter supplies none of those operations.
Reported values are not authenticated, and the projection alone verifies
neither checkout nor source and confers no launch authority.

`checkout_head.observe_checkout_head(checkout_root, expected_oid)` is a
standalone, synchronous filesystem observer. `checkout_root` must be an
absolute Python `str`, not a `pathlib.Path`: refusing path-object conversion
keeps validation from first allocating an unbounded string representation.
It opens the explicitly supplied root component-by-component, requiring
descriptor-relative no-follow directory operations, then reads only
`.git/HEAD` from a real `.git` directory. It accepts exactly a regular, bounded
file containing a lowercase 40-hex SHA-1 object ID and newline, returning the
ID only when it matches the caller's expected ID. Symbolic HEADs,
linked-worktree `.git` files, symlinks, special files, unsupported descriptor
operations and all filesystem errors fail closed as `checkout_head.Refusal`
(`ValueError`). Each invocation
reopens and observes the filesystem; it does not cache results.

This is a narrow observation, not custody or protection against a malicious or
concurrent job. Filesystem changes around an observation can still race it, and
matching the expected object ID does not establish who created or controls the
checkout. It invokes no Git command, subprocess, network or native code; it
does not inspect objects, verify repository integrity, or assert compatibility
with hosted checkouts. It is not integrated into the existing attribution
envelope and grants no launch authority.

Its controlled filesystem fixtures run without Git:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_checkout_head.py'
```

`checkout_layout.observe_checkout_layout(checkout_root, expected_oid)` is a
separate source-only, read-only shape and metadata census. It first requires
`checkout_head`'s explicit canonical absolute root and lowercase SHA-1, and its
real `.git` directory with a matching detached `HEAD`; linked-worktree `.git`
files are refused. Descriptor-relative no-follow traversal bounds the objects
directory to 512 entries and its pack directory to 128 entries, with each name
bounded before metadata inspection. It counts only loose fanout directories
(without visiting their contents), pack/index name pairs, unpaired files, and
metadata sizes/counts within the existing pack and index size caps. Both
`alternates` and `http-alternates`, multi-pack-index, mismatched pairs, and
unexpected entries are reported only as fixed feature labels. Its compact
deterministic JSON omits paths, entry names, object IDs, file contents and
environment values; symlinks, special files,
overflows, traversal errors, detected metadata changes and cleanup errors
refuse.

The output is explicitly `shape-and-metadata-only` with acceptance
`not-assessed`. Candidate classifications do not select a pair, parse arbitrary
blobs, validate pack/index content, assert object availability, or establish
provider-profile acceptance. A size-fitting pair is not evidence that the pair
is valid or supported on a hosted provider. The census invokes no Git command,
subprocess, network, iOS test or hardware operation and is not an acceptance
gate.

Descriptor-held metadata and repeated directory entry snapshots detect only
some concurrent changes. They cannot establish path custody or exclude
transient changes, hostile same-job behavior, filesystem/provider semantics or
all races; matching metadata is not provenance, isolation or qualification.
Filesystem and cleanup errors become fixed-message `Refusal`s without
filesystem details. For later hosted output, use
`observe_checkout_layout_report`, which returns only a closed JSON projection:
an observed census, or `{"diagnostic":"Refusal","status":"refused"}`. Emit/log
that returned string, never a caught exception object, its `__context__`,
`__cause__`, or formatted traceback.

The raising `observe_checkout_layout` API is not itself a safe logging
boundary. Python can attach an already-active caller exception as
`__context__`, even when a raised exception uses `from None`; this helper does
not claim to clear arbitrary caller context. `KeyboardInterrupt` and
`SystemExit` propagate rather than becoming status reports. They, too, may
carry caller context, so a runner must not export its exception object or
traceback. Cleanup errors refuse without retrying a close.

The separate **Hosted checkout layout census (no acceptance)** workflow is
manual-only: select it in GitHub Actions and use **Run workflow** on the
desired ref. It has no user-supplied path, SHA or pack inputs. The pinned
checkout action fetches the event SHA with depth 1 and without persisted
credentials. That checkout uses network and mutates the workspace; it is not
part of the subsequent read-only census. The observer uses only
`GITHUB_WORKSPACE` and `GITHUB_SHA` and emits the closed aggregate report to
the job log, with no artifact. Refusals exit nonzero; unexpected failures and
explicit interruptions emit fixed diagnostics and also exit nonzero. The
entry point installs a non-raising SIGINT handler before observing; a SIGINT
sets a flag even while another exception is being handled. It is not an
immediate cancellation: the current operation may finish before the flag is
checked. A signal seen at the pre-write check produces an interruption
diagnostic; a later one can leave the original closed report or failure
diagnostic in the log, with exit status 130 when seen at the final check. No
exception values or tracebacks are deliberately logged by the entry point.

The workflow and checkout are trusted to supply their environment and code;
the observer does not verify the provider, workflow identity, provenance or
workspace custody. The report is layout-only, not acceptance, qualification,
object integrity, availability or evidence of hosted compatibility. Provider
logs, checkout/runtime failures before SIGINT handler installation or outside
the entry point, hostile same-job behavior and forced termination are outside
its output boundary. A signal after the final status check can be too late to
change the exit status; output failures can also prevent or truncate a report.
Do not treat a successful job as an acceptance or qualification claim.

For resource design, the separate `observe_checkout_layout_v2` and
`observe_checkout_layout_v2_report` APIs use the same observation and closed
report boundaries. The v2 schema is `checkout-layout-census-v2`; it retains
the v1 shape, counts and classifications, but omits
`pack_bytes_within_cap_total` and `index_bytes_within_cap_total` (which could
expose an individual pack or index's exact size).
Instead, `pack_size_buckets` is a fixed object of aggregate counts:
`le_8_mib` (0 through 8 MiB), `gt_8_le_16_mib`,
`gt_16_le_32_mib`, `gt_32_le_64_mib`, and `gt_64_mib`. Each upper
boundary is inclusive; MiB is 1,048,576 bytes. Every regular file matching the
pack filename pattern is counted once, including unpaired packs; index and
unexpected files are not. No filenames, IDs, paths, contents or exact
individual pack or index sizes are emitted. Fixed unsupported-feature labels
do not identify or classify the exact unexpected entry.

V2 retains the descriptor, entry and output bounds, no-follow and race checks,
refusal and interruption behavior described above. It does not choose a pack,
raise reader caps, inspect pack contents or establish acceptance. Bucket counts
help inform resource design only; they do not justify a reader limit or show
that a hosted checkout is supported.

For a manual hosted v2 observation, select `v2` in the workflow's
`census_version` choice; the default `v1` preserves the existing hosted
output. Both paths use the same pinned checkout and output boundary, with no
additional tests, verifier or observer network activity. Checkout's network
and workspace mutation remain outside the observer. No dispatch is implied by
these instructions.

Synthetic fixtures:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_checkout_layout.py'
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_hosted_layout_census.py'
```

`source_snapshot_integration._observe_sources(checkout_root, tree, objects)` is
a separate internal, opt-in prerequisite, not connected to the existing
attribution observe/validate paths. The caller supplies an exact absolute `str`
checkout root (with `checkout_head`'s path restrictions), a lowercase 40-hex
tree SHA-1, and an existing exact `provider_attribution._Objects` instance.
It calls `_Objects.files` on that instance once, sharing its existing object
count, byte and identity checks. Grouped lookup and tree parsing dispatch to
the class implementations rather than instance-shadowed methods; tree parsing
also uses class `get` in the existing single-file path. No API is changed.
It returns a path-sorted dictionary mapping each fixed
checkout-relative source path to `{"blob": <Git SHA-1>, "sha256": <hex>}` or
raises `ios_runtime.Refusal`. There is no caller-selected path or module.
The existing aggregate object budget can refuse even when each file fits its
individual cap; acquisition bounds remain the caller's reader responsibility.

The only sources are `source_snapshot_integration.py`,
`provider_attribution.py`, `ios_runtime.py`, `checkout_head.py`,
`git_snapshot_reader.py`, `git_loose.py`, `git_loose_acquire.py`,
`git_pack.py`, `git_pack_acquire.py` and `git_delta.py`, all under
`scripts/test-audit-run`. Each loaded module's exact `__file__` string must
match its source path before and after the read. This is a path observation,
not proof of loaded code integrity. The concrete project-module dependency
references are also checked for identity before and after observation; these
checks do not defend against hostile same-job Python introspection or mutation.
Each call freshly opens the ten files
through descriptor-relative no-follow directory traversal, requires regular
files of at most 128 KiB each, checks before/after metadata and path identity,
and compares every byte with its tracked blob. Cleanup errors refuse without
retrying close; a cleanup refusal's `__cause__` is the close error and its
`original_error` is the concurrent operation error (or `None`). Multiple
cleanup failures nest through `original_error`. The local descriptor owners
avoid helpers that suppress close failures while unwinding. Cleanup
`KeyboardInterrupt` and `SystemExit` propagate with the same `original_error`
attribute rather than being converted to refusals. An active interruption
remains the propagated exception if later closes fail; those errors are retained
in its `cleanup_errors` tuple in close order, without retrying any descriptor.
These checks detect some replacements and mutations but do not exclude races.

The supplied tree is **not** tied to HEAD by this helper alone.
Caller-supplied context projection,
Python/stdlib, loaded bytecode, malicious same-job behavior, custody or
authentication, hosted compatibility and launch authority are explicitly
outside this observation. The synthetic fixtures use Git-format objects and
do not invoke Git, subprocesses, network, iOS tests or hardware:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_source_snapshot_integration.py'
```

#### Opt-in two-snapshot composition

`source_snapshot_integration.observe(checkout_root, pack_id, context_reader)`
returns bounded canonical JSON bytes. `validate(data, checkout_root, pack_id,
context_reader)` performs a new full observation and compares bytes, never
trusting or parsing the candidate. Both are separate from and leave unchanged
the existing `provider_attribution.observe`/`validate` API and v1 schema.
Inputs are an exact absolute checkout root string, one explicit lowercase
40-hex pack ID, and a callable that freshly supplies the closed attribution
context on each call. There is no ambient environment or event-file reader,
pack enumeration, output writer, Git subprocess, command runner, or launch API.
The caller is responsible for fresh, bounded context acquisition.

One new `git_snapshot_reader.Invocation` provides two sequential fresh readers,
one on either side of `ios_runtime.provider_verified_checker` and its cleanup.
Each snapshot validates a freshly supplied context, observes canonical detached
HEAD matching its checkout SHA before accessing objects, then uses a single
`_Objects` for the unchanged attribution checks and all ten fixed sources.
The two attribution source records must also match their duplicate fixed-source
records in each snapshot. The source helper's exact module path and
dependency-graph checks apply.
The second snapshot and the provider output must match the first; failures,
including cleanup failures, return no partial result. Interruptions propagate.
When needed, pack pairs are reacquired per snapshot, not cached across snapshots;
all-loose objects need not cause the named pair to be acquired.

The wrapper has exactly `schema` (`ios-source-snapshot-composition-observation-v1`),
`assurance` (`same-job-unauthenticated-observation-not-custody-or-authority`),
`attribution` (the unchanged complete v1 record), and `sources` (the ten fixed
path/blob/SHA256 records). Both v1 and wrapper encodings are bounded by 32 KiB.
The existing 32 object calls and 1 MiB aggregate object bytes per snapshot,
and 64 invocation calls, are unchanged. A successful ordinary snapshot uses
22 calls without a workflow and 27 with one: one checkout commit, eight for
the two original single-file source walks, optionally five for workflow, and
13 for the grouped sources. Thus a present workflow uses 54 of 64 calls across
both snapshots; aggregate bytes can still refuse even when every object fits.
No new caching is introduced into attribution's single-file walks.

`observe_v2(checkout_root, pack_id, context_reader)` and `validate_v2(data,
checkout_root, pack_id, context_reader)` are separately versioned opt-ins with
the same fixed checks, provider verifier, envelope encoding and attribution
record. Their outer schema is `ios-source-snapshot-composition-observation-v2`;
validation of either version refuses the other's bytes. One shared
`InvocationV2` supplies both fresh snapshots and considers only the explicit
caller-named pair, with a 16 MiB pack cap. There is no pack selection or
discovery. The ten-source set is unchanged: in particular `github_context.py`
and any future runner are not covered.

The same per-snapshot object and source bounds apply. Across both snapshots
v2 reserves at most 17,301,568 loose bytes and 35,651,588 pair bytes
(52,953,156 combined), including detection bytes, with at most 64 object
calls and two pair acquisitions. These are logical I/O reservations, not
peak RSS or elapsed-time limits; the v2 parser/acquisition memory and race
caveats below apply. No hosted acceptance is claimed.

`observe_v3(checkout_root, pack_id, input_reader)` and `validate_v3(data,
checkout_root, pack_id, input_reader)` are a separate source-only opt-in,
using the v2 explicit-pair profile and outer schema
`ios-source-snapshot-composition-observation-v3`. Validation refuses other
versions' bytes. On each snapshot, `input_reader()` supplies an exact tuple
`(environment, event_bytes, checkout_sha)` for `github_context.read_context`.
These are explicit inputs, not an ambient environment or event-file reader.
The callback is invoked on each side of the provider verifier, but two calls do
not prove fresh acquisition: the caller remains responsible for it. Comparison
is of projected context, not all input bytes; changes to ignored event fields can
leave the projection unchanged.

V3 adds `github_context.py` to the ten fixed sources and checks its exact module
path and its `ios_runtime` and `provider_attribution` dependency identities in
addition to the existing graph. It shares the same per-snapshot object and byte
budgets with attribution: ordinary snapshots use 23 calls without workflow
identity and 28 with it, or 46 and 56 across both snapshots, within the unchanged
32-per-snapshot and 64-per-invocation limits. Aggregate bytes can still refuse.
The caller supplies the pack ID; there is no discovery, and the pair is acquired
only when a requested object is not loose. This adds no filesystem event
acquisition, workflow or hosted invocation, or launch.

This is a same-job **unauthenticated observation**, not custody, provenance,
authority, or qualification. Caller code and context acquisition, Python and
stdlib, loaded bytecode, races, hostile job/provider behavior, and hosted layout
compatibility are outside the claim. Module path/graph observations do not prove
the integrity of executing code. The provider verifier may execute its fixed
native probes when invoked in future; the synthetic tests mock it and deny
process, network, enumeration and hardware probes. They do not launch iOS tests.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_source_snapshot_integration_v3.py'
```

#### Integrated no-launch runner

`observation_runner.py` connects private bounded discovery and fresh input
acquisition to the separately versioned
`ios-source-snapshot-composition-observation-v4`. It emits only
`{"status":"observed"}` or a fixed refusal/failure/interruption diagnostic;
the envelope, paths, IDs, environment, exceptions and native command output
are never deliberately emitted. The separately reviewed manual workflow below
is included; its presence does not mean it has been dispatched.
Success is deliberately status-only: exact source, HEAD, runner and toolchain
identity evidence is not emitted and remains separately unresolved for #893.
The v4 runner verifies provider context but does **not** call the preparer's
profile acceptance; even a successful provider observation is not acceptance.
The earlier generic refusal does not establish its cause or profile refusal.

Refusal and unexpected-failure reports include a closed execution-boundary
stage: `input`, `project-checks`, `pack-discovery`, `snapshot-before`,
`provider-enter`, `provider-record`, `provider-exit`, `snapshot-after`,
`consistency`, `encoding`, or `final-check`. Invalid stage state falls back
to `observation`. A stage is not a cause, a guarantee that earlier checks
succeeded, an exact failed syscall, or proof that any provider command ran.
Cleanup may mask an operation error, including during provider exit. No private
exception, path, identity, event, environment, native output or envelope is
included in these diagnostics.
The provider verifier executes up to twelve fixed native commands when actually
run; each has the existing 2 MiB output and 30-second execution limits, plus
bounded cleanup. Synthetic tests mock it and deny subprocess, network and
hardware probes.
It does not launch iOS tests. Output failures can prevent or truncate a report;
interpreter startup, forced termination, hostile same-job code and failures
outside the entry point are not an output boundary.

The runner reads only the closed GitHub context environment keys plus
`GITHUB_WORKSPACE`, `RUNNER_TEMP` and `GITHUB_EVENT_PATH`. It requires the event
path to be exactly `RUNNER_TEMP/_github_workflow/event.json`, with canonical
absolute no-follow directory traversal and a regular file bounded to 1 MiB.
Environment values are bounded before reading; the event file and relevant
environment are freshly read on both snapshots. File and directory metadata,
including path identity, are checked around each read. These checks are a path
policy and observations, not authentication: the same job controls the inputs
and filesystem. Only the projected context is compared across snapshots;
unprojected event changes can be ignored. The reported `GITHUB_SHA` must match
the detached HEAD under the existing HEAD observer.

Each discovery accepts exactly one regular `pack-<sha>.pack` and matching
`.idx`, with no other entries, symlinks or special files, and inclusive 16 MiB
pack and 1 MiB index limits. Names and metadata are checked before and after
the directory scan. The selected pair and its root, directory and entry
metadata are rechecked before and after each snapshot and after composition;
a persistent directory or pair replacement refuses, including between snapshots.
Successful execution uses eight bounded discoveries, each performing at most
two scans of at most three entries. The existing v2 reader still acquires and
validates that pair only when a loose object is absent. Unknown entries are
never whitelisted: the earlier hosted census observed one unexplained extra pack entry, so this path
may honestly refuse that layout. Discovery does not establish pair validity.

V4 covers the runner and acquisition module alongside the eleven v3 sources
and checks their project-module relationships. The existing object limits
remain 32 calls and 1 MiB per snapshot, 64 calls per invocation; the ordinary
workflow case uses 30 and 60 calls respectively. V2's two-pair/64-call I/O
reservations remain 52,953,156 bytes, plus at most 2,097,154 event bytes
including detection bytes and bounded discovery metadata. These are not hard
RSS or elapsed-time limits. The synthetic descriptor test bounds simultaneously
held project `os.open` descriptors at 20 and verifies closure; interpreter,
directory-iterator and native-probe descriptors are additional. Canonical path
length remains bounded to 4096 bytes. Signal handling uses a non-raising SIGINT
flag, checked at observation boundaries; an in-progress bounded operation may finish
before interruption is reported. The final flag read immediately before writing
commits the chosen report and exit-status pair. A SIGINT after that read,
including during or after a complete write, does not alter the committed status;
an earlier SIGINT selects the interruption report and status 130. A short or
failed write can still prevent or truncate a report and exits unsuccessfully.
Cleanup failures refuse.

Persistent replacements visible at the checks refuse, but transient
mutate-and-restore races and changes between checks can escape detection.
The existing HEAD, loose-object and fixed-source primitives retain their
documented race and cleanup limitations; this does not establish universal
replacement detection, custody, authentication, isolation or qualification.
Same-job code, Python, the provider and toolchain remain trusted assumptions.

#### Explicit bounded producer runner (source-only opt-in)

`observation_runner.py --bounded-prepare-v1 ABSOLUTE_INPUT LOWERCASE_SHA256`
selects the separate v5 composition; the existing no-argument runner remains
v4. Unknown, incomplete or extra arguments refuse at the input stage.
Supply exactly one canonical absolute `.xctestrun` path and its 64-digit
lowercase SHA-256 pin. There is no candidate enumeration or compile provenance
claim. This mode is not used by the workflow below and authorizes no dispatch.
It uses the same bounded context and pack discovery and the exact v4 source set
plus `prepare.py` and `bounded_material.py` (15 files), with module path and
dependency identity checks including the preparer's local imports.

Inside a fresh provider context it invokes the actual provider-profile bounded
preparer and its nested bounded validator. It type-sensitively compares the
entire validated intent provider observation with the outer observation.
Provider exit rechecks, the second source/job snapshot, consistency, encoding,
the final pair check and final SIGINT checks must all succeed before the same
status-only `{"status":"observed"}` report. Preparer and material acquisition
errors are closed `prepare`-stage refusals; input shape errors use `input`.
Diagnostics expose no intent, path, exception or provider output. As in v4,
stage is a boundary, not a cause, and cleanup can mask an earlier failure.
Shell history, process arguments, interpreter startup and external logging are
outside this output boundary and may expose the explicit path or pin.
An in-progress bounded preparation can finish after SIGINT before the flag is
checked; the v4 final report-commit semantics are unchanged.

The object limits remain **32 calls and 1 MiB per snapshot, 64 calls total**.
Synthetic workflow-identity snapshots use exactly 32 calls each (64 total),
leaving no call margin; without workflow identity they use 27 each (54 total).
Aggregate object bytes can still refuse. The pair
limits remain 16 MiB pack and 1 MiB index and v2's 52,953,156-byte total
Git I/O reservation. Event reads reserve at most 2,097,154 bytes. Six provider
snapshots run up to 36 fixed commands, each with a 2 MiB plus one detection
byte output limit and 30-second execution deadline; bounded child cleanup can
also wait up to 30 seconds. Their combined output reservation is 75,497,508
bytes and provider file reads reserve 16,649,490 bytes. The producer's four
bounded material reads reserve 8,388,612 bytes and it writes at most 4 MiB.
These separate logical I/O limits, descriptor limits described above, and
deadlines do not guarantee RSS or elapsed time. The existing workflow's
30-minute timeout is not proven sufficient for this mode, even before other
overhead; no workflow timeout or behavior is changed here.

The producer never deletes artifacts: even a failure *after* successful
preparation, such as a later snapshot or final-check refusal, can retain the
complete pair and possibly sensitive material. Repeated attempts can consume
unbounded disk space. Authorized disposable-workspace use and separate
caller-owned cleanup authority are required; this runner does not clean up.
Creating siblings directly in the checkout root can itself change root
metadata and trigger the existing pair identity refusal. A status-only success
is a same-job unauthenticated observation, not custody, source provenance,
actual hosted acceptance, qualification, or launch authority. Python, loaded
code, the job and provider remain trusted; transient races remain possible.
Synthetic tests use only mocked native provider probes, not a real host:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_bounded_observation_runner.py'
```

#### Provider-trusted Products candidate handoff (#893; source-only opt-in)

`observation_runner.py --provider-products-v1 ABSOLUTE_PRODUCTS_ROOT` is an
additional explicit mode that selects the existing v5 composition. The caller
must separately authorize and own a disposable **iOS-only** workspace and
explicitly provide its canonical Products root. The root must be an absolute,
canonical UTF-8 path no longer than 4096 bytes and at most 63 components, so the
selected candidate path remains within 64 components; every path component is
at most 255 UTF-8 bytes. The no-follow directory scan accepts at most 256
entries and refuses on a 257th detection entry, with the same 255-byte name
bound, and requires exactly
one root-level name ending in `.xctestrun`. Zero or multiple candidates,
candidate symlinks, hard links, special files, oversized paths, read errors,
mutation, and candidates larger than the existing inclusive 2 MiB material
limit refuse without trying another candidate. The selected candidate is
opened no-follow, read once with a 2 MiB-plus-one detection bound, and hashed
as lowercase SHA-256. Its canonical path and resulting pin are passed directly
to the existing explicit v5 pipeline; there is no retry or fallback mode.
Unknown arguments and extra inputs still refuse. The no-argument v4 mode and
`--bounded-prepare-v1 ABSOLUTE_INPUT LOWERCASE_SHA256` mode retain their
existing behavior.

The Products enumeration and handoff add no tracked source module: the changed
acquisition logic is already among the runner's snapshotted sources. The
existing v5 source set remains 15 files, and its object budgets remain exactly
32 calls per snapshot (64 total), with no extra source snapshot or object calls.
The only successful runner output remains `{"status":"observed"}`; failures
remain fixed status-only diagnostics. The candidate itself is not printed.

This is only provider-trusted candidate selection, **not** a build operation or
evidence that a candidate is fresh, compile-produced by this checkout, intended
for this run, or has any verified provenance. The v5 provider observation and
source snapshot do not prove Products-root custody, workspace isolation, or
that a human authorized the iOS-only workspace. The caller must establish those
conditions separately. The scan pins bytes, but its descriptors close before
the v5 preparer reopens the path: an identical-byte replacement can occur in
that handoff interval, and transient changes between checks can escape
detection. The preparer's later bounded pin check refuses differing bytes but
does not close all identity or filesystem races. Same-job code, Python,
provider, filesystem semantics, and the caller-controlled workspace remain
trusted; this is not custody, authentication, race freedom, qualification, or
launch authority.

Preparation may retain output and intent siblings on any later failure,
including snapshot, provider-exit, or final-check failure. These files can
contain sensitive metadata; this runner never removes them, retries, or
cleans the workspace. Repeated attempts can accumulate unbounded disk use.
Keep all use within the separately authorized disposable workspace and perform
any cleanup under the caller's own authority. This source-only mode does not
change or dispatch workflows, launch tests, access credentials, or use
hardware.

#### Manual hosted observation procedure

`.github/workflows/ios-provider-observation.yml` permits only a manual
dispatch, without inputs, on `djensenius/FluxKlang` main. Before any later
dispatch, a human/coordinator must independently review the merged workflow
and verify the selected exact main head and its workflow contents; this
source change authorizes no dispatch. The workflow requires a nonempty
workflow SHA equal to the event SHA and checks out that event SHA. Those
in-run checks are not independent evidence of the executing workflow's
identity, nor do they pin a future dispatch against a main-branch change.
Verify the selected head again when dispatching, and do not dispatch if it
cannot be established as the reviewed head.

Run once only, with no retry or artifact collection. The status-only success
does not emit identity evidence and cannot establish exact source, workflow,
runner or toolchain identity, qualification, or launch authority. Report a
refusal or failure as such: the previously observed unknown pack entry may
cause refusal before any provider probe, and refusal is not profile acceptance.
The eventual provider probes are read-only and do not launch iOS tests.

The job trusts the hosted image, checkout action, shell, Python and reviewed
job; it does not protect against a compromised provider or same-job code.
Shell startup is constrained and the runner is started with an allowlisted
environment and Python site initialization disabled (`-S`); its fixed
subprocesses have their own sanitized environment. Interpreter/shell startup,
checkout action logs, GitHub's job logs and forced termination are outside the
runner's closed-output boundary and may include checkout identities or other
diagnostics. No additional secrets are provided. The finite timeout allows
twelve 30-second probes and bounded cleanup, but can still terminate a slow run.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_observation_runner.py'
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_observation_workflow.py'
```

`git_loose.read_object(compressed_bytes, oid)` is an independent, in-memory
SHA-1 Git loose-object decoder. It accepts only plain immutable `bytes` and a
plain `str` containing a full lowercase 40-hex ID, returning `(kind, raw_bytes)`
or raising `ValueError`. It requires exactly one complete zlib stream, with no
trailing or concatenated data, and a canonical `commit`, `tree`, `blob`, or
`tag` header with an unsigned decimal length (zero is `0`, otherwise no leading
zeroes), a NUL separator, exactly that many content bytes and a matching SHA-1.
It does not interpret the contents.

The inclusive content limit is 256 KiB, matching the pack reader and attribution
object limit. Compressed input is capped at 264 KiB before decompression; this
conservative cap leaves 8 KiB for the header and zlib/DEFLATE overhead of a
stored uncompressed object at the content limit. It does not accept every
possible inefficient encoding of an otherwise valid object. Inflate output is
limited to 256 KiB plus the 14-byte maximum canonical header and one detection
byte, before header parsing. Input, inflate work and retained/temporary output
copies are bounded per call, but the caller must bound acquisition separately;
there is no wall-clock or shared multi-call budget.

The decoder reads no files or ambient state, invokes no Git subprocess or
network, and is not integrated into the envelope. SHA-1 consistency is not
authentication or collision resistance. Multi-pack lookup, hosted layout
measurement and iOS launch remain separate; this does not assert hosted checkout
compatibility or launch authority.
The tests use an existing Git-produced loose fixture and do not invoke Git:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_loose.py'
```

`git_loose_acquire.read_object(checkout_root, oid)` is a separate, synchronous
filesystem reader returning the decoder's `(kind, raw_bytes)` or raising
`checkout_head.Refusal` (`ValueError`). It requires an explicit exact `str`
absolute root with the same path restrictions as `checkout_head`, and an exact
lowercase 40-hex SHA-1 ID. It traverses root components and `.git/objects/XX`
using descriptor-relative no-follow directory opens, then opens the remaining
OID component no-follow and nonblocking. Only a regular file is accepted; each
call freshly reopens it, reads at most the 264 KiB compressed limit plus one
detection byte, checks size and before/after descriptor metadata (excluding
access time), and applies the loose decoder's bounds and identity validation.
Missing or unsupported layouts, including linked-worktree `.git` files,
symlinks, nonregular files, malformed objects and detected changes refuse.
The `git_loose_acquire.LooseAbsent` subclass of `Refusal` distinguishes only
an `ENOENT` opening the requested fanout directory or leaf after successfully
traversing the real root and `.git/objects`. Missing root, `.git` or `objects`,
other operations' errors, and cleanup failures remain ordinary refusals.
Existing `Refusal` handlers still catch absence. This is a path observation,
subject to the race limitations below, not proof of repository-wide absence.
It never falls back to packs or alternates: a missing loose object is not proof
that the repository lacks it.

Descriptor owners are registered before opening; registration failures unwind
already-owned descriptors. This is not absolute cleanup safety: asynchronous
Python interruptions can occur between an open returning and recording its
descriptor, or during cleanup (including in the reused checkout helpers).
An interrupted or failed close cannot safely be retried because the descriptor
number might already have been reused.

The metadata checks detect some concurrent changes, not all races: a file or
path can be replaced while its descriptor remains open, and hostile writers
may evade metadata checks. SHA-1 validates object consistency, not custody or
collision resistance. This does not verify HEAD, the complete checkout or
hosted checkout compatibility, and has no envelope integration or launch
authority. It invokes no Git command, subprocess, network or native launcher.
Controlled synthetic fixtures run without Git:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_loose_acquire.py'
```

`git_pack.read_object(pack_bytes, index_bytes, oid)` is an isolated in-memory
SHA-1 Git-object reader returning `(kind, raw_bytes)` for a full lowercase
40-hex ID, or raising `ValueError`. It only consumes the explicitly supplied
plain `bytes` pack and index; it does not read loose objects, files or ambient
state, invoke Git, discover HEAD, fetch, publish output, or consult other packs.
It accepts pack version 2 and index version 2, including ordinary commit, tree,
blob, tag, REF_DELTA and OFS_DELTA entries within the bounds below. It rejects
thin/cross-pack bases, unsupported formats, missing objects, cycles, corrupt
compression, malformed structure, and mismatched checksums, CRCs or object IDs.
It validates the entire supplied pack, including unrequested entries, before
returning; a bad unrelated entry therefore also refuses.
Nonminimal pack object-size headers are refused even if Git `index-pack` accepts
them.

Fixed inclusive limits per call (no caller overrides): pack 8 MiB, index 1 MiB,
4,096 entries, non-delta and reconstructed objects 256 KiB, each delta program
1 MiB, 8 MiB aggregate declared inflated bytes, 8 MiB aggregate reconstructed
bytes, and 32 objects per delta chain including its base. The existing delta
primitive also caps each program at 65,536 instructions and uses minimal size
varints. Input lengths and counts are checked before variable allocation; zlib
output is capped to the declared size plus one byte, and exact stream boundaries
are required. The total inflated-program budget also bounds cumulative delta
instruction work; a single delta's temporary output can add up to two copies of
256 KiB beyond retained results. Index entries and compressed input are bounded
independently. Large-offset index entries cannot describe an accepted pack under
the 8 MiB cap. Unsupported, even otherwise valid, larger packs refuse.

`git_pack.read_object_v2(pack_bytes, index_bytes, oid)` is a separate, opt-in
source-only prototype with the same full-pack validation and return/refusal
contract, but a fixed inclusive 16 MiB pack cap. It takes explicit plain bytes;
there is no caller-selected limit, cache, acquisition, discovery, pair routing,
or integration with `BoundedReader` or the incomplete fixed source observer.
The separate v2 snapshot adapter uses the v2 acquisition API, not this direct
API. All other limits above remain unchanged, including the 1 MiB
index and both 8 MiB aggregate budgets. OFS distances are bounded by the
profile's pack cap before each decoding shift and must point to an earlier
indexed entry; v1 retains its original 8 MiB bound. Large-offset index entries
still cannot describe an accepted pack. Repeated direct calls reparse the pair.

Logical buffer accounting per v2 call, not a hard RSS bound: the caller's pack
and index may occupy 16 MiB and 1 MiB respectively and remain live throughout.
Pack slices used for CRC, checksumming and decompression are views, not full
pack copies. Retained inflated entries total at most 8 MiB; retained resolved
results total at most 8 MiB, with non-delta results sharing their inflated bytes.
An in-progress delta can additionally hold a 256 KiB output bytearray and its
256 KiB bytes copy, including when a result-budget refusal occurs. Inflate may
produce one byte beyond a declared size before refusing; malformed streams may
also materialize `unconsumed_tail` or `unused_data` copies, each bounded by the
compressed entry (at most the pack size). Names, offsets, records, dictionaries,
zlib state and Python object/allocation overhead are additional and unmeasured;
these logical bounds neither measure peak memory nor include caller-held copies
or concurrent calls.

A hosted v2 census observed one pack in the >8–16 MiB bucket, but its content,
availability, unexpected entries, identity and acceptance here are unknown.
These synthetic parser tests do not establish hosted acceptance, qualification,
provenance or hardware behavior, and do not authorize hosted dispatch.

`git_pack.BoundedReader` is an optional synchronous, in-memory adapter for one
`observe` or `validate` invocation, encompassing both envelope snapshots. Its
`read(pack_bytes, index_bytes, oid)` takes fresh, explicitly supplied bytes on
every call, converts parser `ValueError` to `KeyError` (which the envelope
converts to `runtime.Refusal`), and caches only a completely validated pair.
Plain immutable bytes are required. Byte-for-byte equal pairs reuse the results;
changed pack **or** index bytes invalidate the cache and require full validation.
Any refusal permanently disables that instance; it never falls back to prior
results. It allows at most 64 calls and two full validation attempts per instance,
including failed attempts, so repeated requests in the envelope's two snapshots
cannot repeatedly parse an expensive pack. More than two different valid pairs
in one invocation refuse. This bounds parsing but does not bound the caller's
input acquisition or wall-clock time, and the adapter is not thread-safe.

The future caller must create a new adapter for each `observe` or `validate`,
and its `object_reader(oid)` must obtain fresh bounded pack/index bytes on
**every** invocation before calling `adapter.read(pack, index, oid)`. It must
translate any acquisition `ValueError` to `KeyError` or `runtime.Refusal` too;
the envelope does not catch a bare `ValueError`. Never bind a frozen pair once
and reuse it across both snapshots: that conceals later input changes. The
adapter has no input-acquisition function, I/O, or implicit source. The direct
`read_object` API remains independent and raises `ValueError`; repeated direct
calls reparse the whole pack and have no shared invocation-wide budget. Neither
interface detects mutations between acquisitions, changes that are later
reverted, or a changed pack containing the same observed objects: the envelope
compares observations, not pack custody.

This is not a filesystem adapter or a checkout/HEAD observation. A future
reviewed runner must separately acquire fresh bounded bytes and verify actual
checkout HEAD and custody; it must not read credentials, dump environments,
execute data, fetch objects, honor replacement objects, or consult candidate
toolchain paths. SHA-1 checks validate consistency of supplied bytes, not their
origin or authenticity; SHA-1 is not collision-resistant. Provider and same-job
code remain trusted. There is no CLI, output writer, hosted integration or
trigger change, and no provenance or launch authority is conferred.

The static loose and REF/OFS pack/index fixtures were produced by Git; tests do
not invoke Git:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_pack.py'
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_pack_v2.py'
```

`git_pack_acquire.acquire_pair(checkout_root, pack_id)` separately returns fresh
plain `(pack_bytes, index_bytes)` or raises `checkout_head.Refusal`
(`ValueError`). The root must be an exact absolute plain `str`, with the same
unambiguous path restrictions as `checkout_head`; the identifier must be an
exact plain lowercase 40-hex SHA-1 string. Only the explicit real
`.git/objects/pack/pack-<id>.pack` and matching `.idx` are opened. Root and
directory traversal use the existing descriptor-relative no-follow helpers;
files are opened no-follow and nonblocking and must be regular. There is no
enumeration, fallback, alternate-object-store consultation or multiple-pack
routing. Missing files and linked-worktree `.git` files refuse.

Each call opens both files afresh, checks their initial sizes against the
existing inclusive 8 MiB pack and 1 MiB index caps, reads at most each cap plus
one detection byte, and checks both held descriptors' metadata after both reads
(excluding access time) and actual read lengths. It requires the filename ID
to equal the pack trailer, then fully validates the pair with `git_pack`'s
existing parser, including unrequested objects. No parser limits are expanded.
Lookup is separate: the returned pair can be passed to `git_pack.read_object`
or `BoundedReader.read`. Acquisition itself always performs a complete parse;
the subsequent lookup interface incurs its own parsing/budgets. This is not an
invocation-wide acquisition/work or wall-clock budget, nor a ready-made
envelope object reader; the existing envelope error-translation requirements
still apply.

`git_pack_acquire.acquire_validated_pair(checkout_root, pack_id)` instead
performs the same fresh acquisition and exactly one complete validation, returning
an immutable result whose `read(oid)` returns `(kind, bytes)` or raises
`ValueError` for invalid or missing IDs. Missing means only absent from this
explicit pair, not from the repository. Its validated content is retained without
an exposed mutable object map: it uses immutable entries and binary search;
lookup does not parse again. The result type has no public constructor and its
ordinary constructor refuses input; it is not a security boundary against
same-job code using Python introspection or modifying the runtime. Every
acquisition opens and validates anew, including after a prior failure. Reusing
the result is intended only within one future snapshot; a new acquisition is
required for each snapshot. This changes freshness granularity from per-request
acquisition and does not detect intervening or reverted changes. It provides no shared
observation-wide work/call budget, source routing, error translation or envelope
integration; those remain the future caller's responsibility.

`git_pack_acquire.acquire_validated_pair_v2(checkout_root, pack_id)` is a
separate source-only opt-in with the same explicit-pair, fresh-acquisition and
validated-lookup contract, but uses the fixed v2 parser and its inclusive
16 MiB pack cap. The index cap remains 1 MiB and all other parser limits remain
unchanged. Both initial sizes are checked before either read; each read requests
at most its cap plus one detection byte, so a pair can deliver at most
17,825,794 bytes including both detection bytes. Both held files are checked
after both reads. There is no adjustable limit, discovery, selection, fallback
or hosted dispatch. Existing acquisition and snapshot APIs
remain v1 and retain the 8 MiB cap. The v2 result is parsed once per acquisition,
not per lookup; a fresh acquisition is needed for each future snapshot.

Logical memory accounting is not a hard RSS bound: each read can temporarily
hold an `os.read` bytes chunk and a growing bytearray, then a bytes copy; the
pack bytes remain live while reading the index and during validation. Parser
buffers and possible malformed-stream copies are described in the v2 parser
accounting above. Python allocation, object, interpreter and zlib overhead are
unmeasured and not bounded as a hard process-memory claim; caller-held copies
and concurrent calls are additional. Metadata checks and SHA-1 do not establish
custody or provenance. Synthetic source coverage does not establish hosted
acceptance; the eventual explicit caller identity and the hosted pack's
unexpected entry remain unresolved.

Ownership/cleanup patterns are shared with `git_loose_acquire`, with the same
asynchronous interruption and failed-close limitations described above.
Before/after descriptor metadata detects some changes, not all races or path
replacements: replacing a directory while files remain held can return the
original valid pair; a later fresh acquisition sees the replacement. Hostile
writers or changes reverted between acquisitions may evade detection. SHA-1
integrity is consistency, not authentication, collision resistance or custody.
This API does not verify HEAD or the complete checkout, integrate the envelope,
invoke Git/subprocess/network/native tools, claim hosted compatibility, or
confer provenance or launch authority.

Synthetic temporary filesystems and the existing static Git-produced REF/OFS
fixtures exercise this source-only API without invoking Git:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_pack_acquire.py'
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_pack_acquire_v2.py'
```

`git_snapshot_reader.Invocation(checkout_root, pack_id)` is an opt-in,
sequential adapter for one invocation and at most two snapshots. Both arguments
have the same exact-string validation as pack acquisition; `pack_id` explicitly
selects the only pair considered. Call `invocation.snapshot()` once per
snapshot and call the returned reader with each object ID. Creating the next
snapshot invalidates the previous reader. A reader returns `(kind, bytes)` or
raises `KeyError`; invalid construction raises `checkout_head.Refusal`.
Any refusal, invalidated-reader use, limit breach, or interrupted attempt
permanently disables the invocation. It cannot be reset, copied or serialized
through its ordinary API. It is not thread-safe. Use a new invocation for
each separate operation, not a new invocation to evade the limits.

Every object call freshly attempts loose acquisition, including repeated IDs.
Only `LooseAbsent` selects the named pair; corruption, cleanup errors and all
other refusals do not. On first need in a snapshot the adapter freshly acquires
and completely validates the pair once, retaining its immutable lookup result
only for that snapshot. A missing ID in that pair is a refusal, not evidence of
repository-wide absence. No packs or alternates are enumerated or tried.

Across both snapshots, the fixed ceilings are 64 object calls, two pair
acquisition/parse attempts, 17,301,568 bytes of reserved loose compressed I/O,
and 18,874,372 bytes of reserved pack/index I/O. Before each attempt the
adapter reserves the applicable existing per-file cap **plus one detection
byte**, even when the actual read is smaller or fails; it does not depend on
compressed sizes returned by the helpers. Failures are terminal, so retries
cannot repeat expensive work. The existing per-object and parser limits above
remain unchanged. These are conservative work and byte bounds, not a wall-clock
deadline.

The adapter is not integrated into `provider_attribution.observe` or `validate`;
their existing APIs and freshness behavior are unchanged. Composition explicitly
marks each snapshot and shares one invocation across them. Pair contents may
change between reads within a snapshot without being re-acquired; a later
snapshot acquires again only if needed. Loose and pack acquisition retain the
race, cleanup and SHA-1 limitations described above. This is not authenticated
provenance, custody, broad checkout compatibility or launch authority.

`git_snapshot_reader.InvocationV2(checkout_root, pack_id)` is a separate
source-only opt-in with the same lifecycle, refusal and loose-first behavior,
but uses `acquire_validated_pair_v2` for the one explicit caller-named pair.
The original composition remains on `Invocation` and its 8 MiB cap; v2 is not
selected automatically. Its fixed reservation across at most two snapshots
and 64 object calls is 17,301,568 loose bytes and 35,651,588 pack/index bytes,
52,953,156 bytes combined. Each loose attempt reserves 270,337 bytes and each
of at most two pair attempts reserves 17,825,794 bytes before attempting I/O,
including one detection byte per file even on failure. These are conservative
I/O reservations, not RSS or elapsed-time limits.

The v2 acquisition and parser memory caveats above also apply: acquisition
can hold chunks, bytearrays and copies alongside the pack, index, retained
validated results and parser buffers; interpreter overhead, caller-held data
and concurrent invocations are additional. Cached results persist within a
snapshot; previously returned objects can be retained by callers. Fresh reads
and metadata checks do not prove custody or provenance or detect all races or
reverted changes. Synthetic source tests are not hosted acceptance or
qualification and confer no launch authority.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_snapshot_reader.py'
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_snapshot_reader_v2.py'
```

`git_delta.apply_delta(base, program)` is a separate pure byte-to-byte primitive,
not that reader. It applies a single uncompressed Git pack delta as described
in `gitformat-pack(5)`, or raises `ValueError`. It accepts only plain `bytes`:
base and program are each limited to 1 MiB, declared output to 256 KiB, and
instructions to 65,536. Size varints must be minimally encoded and at most
2^63-1; this intentionally rejects nonminimal encodings even if a Git version
accepts them. The program must declare the exact base and output sizes, and
copy and insert operations must fit. Optional copy flag bytes may contain zero,
and zero copy length means 65,536 bytes, as specified by Git.

This primitive itself neither reads packs/indexes nor decompresses, resolves
delta chains, verifies object hashes or HEAD, or observes a checkout. The
separate in-memory pack reader above uses it; filesystem I/O and custody remain
future work. The isolated Git-produced fixture runs without Git or I/O:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_git_delta.py'
```

The exact context keys are `repository`, `event_name`, `event_sha`, `event_ref`,
`checkout_sha`, `pull_request`, `workflow`, `run_id`, `run_attempt`, `job`,
`runner` (`name`, `environment`), and `platform` (`os`, `arch`). Positive bounded
integer IDs/attempts, `github-hosted`, and `macOS`/`ARM64` are required. Push and
workflow_dispatch use branch/tag refs, null PR context, and event=checkout SHA.
Pull requests instead require `refs/pull/N/merge`, separate PR `number`,
`head_sha`/`base_sha`, event=checkout SHA, and exact ordered commit parents
`[base_sha, head_sha]`; the checkout is explicitly `pr-synthetic-merge`, never
relabeled as the PR head. Unsupported contexts, including pull_request_target
and head-only checkouts, refuse.

The envelope has exactly `schema`, `assurance`, `context`, `checkout` (commit,
tree, parents, kind), `workflow`, `executing_sources`, and `provider_runtime`.
Workflow context is either explicitly null (output status `unavailable`, with
SHA/ref/path/blob null), or exactly SHA/ref/path. Its ref must name the same
repository and `.github/workflows/<name>.yml` or `.yaml` path; the workflow
commit/tree/file object is independently content-checked to record its blob.
Workflow SHA remains separate; no assumption that it equals checkout/head/base
or proof that a ref currently resolves to it is made.

The fixed executing-source allowlist is **only** `provider_attribution.py` and
`ios_runtime.py` under `scripts/test-audit-run`. Their SHA256 and Git blob IDs
are recorded after bounded regular-file reads match the checkout tree blobs.
This does not hash `github_context.py`, a future runner, the Git adapter,
Python/stdlib, or loaded code in memory; reviewing that runner and its own fixed
source allowlist is still a required follow-up, not a claim this library makes.
The library checks context,
Git objects and sources before/after the existing provider verifier, which
itself rechecks its runtime observations. These snapshots are not atomic custody
or protection against a hostile provider/job.

Reads cap each source at 128 KiB, each Git object at 256 KiB, object requests at
32 and aggregate object bytes at 1 MiB per snapshot, tree entries at 1024,
commit headers at 16 KiB and parents at two. Unsupported tree modes (including
symlinks/gitlinks), duplicate names, hostile/control strings, mismatched object
IDs/ancestry, malformed or changed records, and noncanonical/tampered outputs
refuse without returning evidence. JSON output is at most 32 KiB. The module
has no process/Git command capability: its only native tool operations are
delegation to the existing fixed, bounded provider verifier probes.

The internal opt-in `_Objects.files(tree, paths)` is a source-only prerequisite,
not integrated into `observe` or `validate` or their fixed allowlist. It accepts a
nonempty list or tuple of at most 32 distinct canonical relative ASCII paths in
one directory, each at most 4096 characters and 32 components (255 characters
per component). Components use only ASCII letters, digits, underscore, dot,
space, and hyphen, and cannot be empty, `.` or `..`. It returns a path-sorted
mapping to `(blob ID, bytes)`, reading shared trees once and each requested blob
separately through the same object and tree limits. It does not enumerate
candidates or cache across calls or snapshots.
This helper makes no claim of hosted compatibility, custody, authenticated
provenance, or launch authority.

Mock-only check (all process/native and source-read operations mocked):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_provider_attribution.py'
```

Context fixture check (no event files or native tools):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_github_context.py'
```

## Explicit opt-in retention requests

Two additional closed profiles reuse the corresponding **original pinned input**,
with both attachment lifetimes still required to be `deleteOnSuccess`:

| Explicit profile | Test targets | Exact parsed leaf changes |
| --- | --- | --- |
| `mac-isolated-unit-retention-request-v1` | `FluxKlangMacTests` | One UUID insertion above, plus both lifetimes: **3** |
| `ios-simulator-isolated-unit-ui-retention-request-v1` | `FluxKlangTests`, `FluxKlangUITests` | Three UUID insertions above, plus both lifetimes on both targets: **7** |

These outputs replace only `SystemAttachmentLifetime` and
`UserAttachmentLifetime` with `keepAlways` on the listed targets, in addition to
the existing UUID insertions. Exactly one fresh UUID4 is copied to those fixed
locations; the third iOS location remains
`FluxKlangUITests.UITargetAppEnvironmentVariables`, **not**
`TestingEnvironmentVariables`. No retention environment keys or other parsed
changes are allowed. Prepared inputs, preexisting UUIDs, altered input
lifetimes, filtering, subsets, and layout drift remain refused.

Retention-request intents use integer `schema_version: 2` and add only
`attachment_policy` to the existing intent fields. Its closed shape is:

```json
{
  "identifier": "request-system-and-user-keepAlways-v1",
  "targets": {
    "FluxKlangMacTests": {
      "SystemAttachmentLifetime": "keepAlways",
      "UserAttachmentLifetime": "keepAlways"
    }
  }
}
```

For the iOS profile, `targets` instead contains exactly `FluxKlangTests` and
`FluxKlangUITests`, each with the same two fields/values. Validation reconstructs
the entire expected output and intent from the pinned original and explicit
profile, never from the supplied policy. Types and nested key sets must match:
even `schema_version: 2.0`, a partial lifetime change, or a relabelled/rehashed
incorrect transformation is refused.

This is **retention requested**, not retained, authorized, or ready. Both
documented attachment categories are requested conservatively; no classification
of Swift Testing or XCTest recording APIs, or precedence between them, is
assumed. Future actual execution might retain unrelated attachments as well,
increasing storage use and privacy exposure. Opt-in is explicit only: the
original profiles retain their `deleteOnSuccess` outputs, exact schema-1 intent
shape, and controlled serialized bytes. No generic retention switch or
post-preparation chain is provided, and no execution is authorized here.

## Commands

From the repository root, with a separately selected compile-produced input and
its explicitly reviewed lowercase SHA256 (replace the example paths/hash):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-audit-run/prepare.py prepare \
  --input /absolute/Build/Products/MacIsolated.xctestrun \
  --expected-sha256 REVIEWED_64_CHARACTER_LOWERCASE_SHA256 \
  --profile mac-isolated-unit
```

Do not derive a new pin merely to bypass a refusal. Success prints JSON containing
the run ID and exact absolute output/intent paths. For input `MacIsolated.xctestrun`
the new siblings are `MacIsolated.audit-run-UUID.xctestrun` and
`MacIsolated.audit-run-UUID.intent.json`. Preparation uses exclusive creation and
never overwrites the input or a previous output; collisions fail rather than
retrying with a repaired identity. The intent is written last, binding schema,
profile, partial-regression label, target set, run ID, its own path, and input/
output paths and byte digests.

Separate **read-only** validation (use the exact paths printed by preparation):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-audit-run/prepare.py validate \
  --input /absolute/Build/Products/MacIsolated.xctestrun \
  --expected-sha256 REVIEWED_64_CHARACTER_LOWERCASE_SHA256 \
  --profile mac-isolated-unit \
  --output /absolute/Build/Products/MacIsolated.audit-run-UUID.xctestrun \
  --intent /absolute/Build/Products/MacIsolated.audit-run-UUID.intent.json
```

Validation generates nothing and never repairs UUIDs, flags, intent, or files.
It rechecks the pinned original and output hashes, canonical UUID4, all parsed
identities and environment values, exact sibling names/locations, and the entire
parsed output against the original plus only the selected profile's fixed
run-key additions and, for retention-request profiles, lifetime replacements.
Final-component file symlinks are refused; resolved parent paths are recorded.
An orphan or partially written pair cannot validate. Exit status is `0` for
metadata success, `1` for refusal/I/O failure, and `2` for invalid CLI arguments.

For the combined iOS metadata, use the same `prepare` and `validate` commands
with `--profile ios-simulator-isolated-unit-ui-v1`, the separately reviewed iOS
input path/hash, and its printed sibling output/intent paths. The CLI never
infers a profile or selects a destination.

To opt into a retention **request**, use those same metadata-only commands with
`--profile mac-isolated-unit-retention-request-v1` or
`--profile ios-simulator-isolated-unit-ui-retention-request-v1`, respectively,
for both preparation and validation. Keep the corresponding original input
path and reviewed pin; do not chain preparation through an existing output.
The profile is required on both commands and unknown choices are refused.

On caught **legacy** preparation failures, newly created files are removed
(intent first); preexisting paths are never removed. Bounded provider
preparation instead retains created files on failure, as described above.
Use a stable caller-controlled directory.
This is not a concurrent-writer, crash-atomic two-file transaction or a durability
guarantee: abrupt termination or filesystem cleanup errors may leave artifacts.
They must not be treated as prepared without separate successful validation.

## Limits and follow-ups

Hashes and metadata consistency do **not** prove product closure, destination
binding, immutable Build contents, external PID/process attribution,
child-process delivery, execution readiness, preflight integration, receipt
retention, or runtime coverage. Intent is neither
a signature nor an execution receipt. Sibling placement preserves metadata path
resolution, not the existence or immutability of any referenced native product.

The canonical UI helper now validates the runner environment and intended app
configuration before setting launch environment/arguments and launching. Its
source explicitly forwards the validated audit UUID with only the intended app
dictionary and unchanged arguments, not the entire runner environment. Explicit
app identity conflicts are refused, not overwritten. The three iOS metadata
insertions and helper source express intended forwarding only; actual
Xcode/helper environment delivery and runtime custody remain unqualified.
Earlier termination/orientation effects remain outside this boundary; this is
not pre-host isolation, factory exclusion, audit coverage, or full #60 acceptance.
The original profiles
preserve the observed `deleteOnSuccess` system/user attachment defaults; the
opt-in profiles only request `keepAlways`. No products or results are opened.
This adds no proof of actual retention, coverage, destination/product closure,
process freshness, or child-process delivery, and no retained receipts. Scheme
script bypass, pre-host timing, and `Test.ID` mapping are not established or
inferred from documentation absence.

This is an intentional fail-closed change: unprepared `make test` and ordinary
isolated-scheme Cmd+U invocations reaching the helper fail for missing
`FLUXKLANG_AUDIT_RUN_ID`. Refusal propagates as an error, not a skip. Execution
authorization alone does not supply identity, and a generated or manually supplied
UUID is neither provenance nor permission. This slice delivers **no replacement
supported execution workflow**. Compilation remains available; Mac/unit adoption
is separate. `UIAuditCaptureSession` remains unused and out of scope.
None of the metadata commands above runs `xcodebuild` or `test-without-building`. Runner integration,
canonical scope adoption, checker/live extraction, iOS/UI runtime handoff, live
profiles, and retained runtime results require separate review/authorization.

All profiles deliberately fix unrelated diagnostic/language/logging
values as well. Broader acceptance requires separate review; this implementation
conservatively refuses that drift rather than inferring a wider supported shape.

## Required unit file-receipt observation guard (#703, prerequisite for #694)

The exact marker is **`FluxKlangAuditRequireFileReceipts-v1`**, an **empty
regular file directly at the unit-test bundle root**:
`FluxKlangTests.xctest/FluxKlangAuditRequireFileReceipts-v1` on iOS, or
`FluxKlangMacTests.xctest/FluxKlangAuditRequireFileReceipts-v1` on Mac (not
`Contents/Resources`, a localized resource, the host app, or the UI bundle).
Only this exact entry opts in; it has no environment-variable equivalent.
An absent entry means ordinary transport selection. A present nonempty file,
directory or symlink, or a bundle/marker lookup error, refuses execution rather
than downgrading to attachments. The scope uses its own unit-bundle class anchor
and verifies the bundle executable against that class's loaded image, so a
`Bundle(for:)` fallback cannot silently inspect the app host instead.

Before each canonical `ProductionAccessScope` body, the marker lookup runs.
When required, the **unprefixed** `FLUXKLANG_AUDIT_RECEIPT_DIR` must be present
and pass the existing sink directory validation: absolute path, existing real
final directory component, effective-user ownership, no group/other bits, no
final symlink or trailing `/`, `/.` or `/..`, and matching opened identity.
Missing, prefix-only (`TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR`), invalid
configuration or marker errors record an Issue with **zero scope-body and
attachment-publisher calls**. Accepted configuration uses the existing file
sink, including fresh publication-time validation and unchanged exclusive
partial-file/no-replace publication. Preflight creates no directory or receipt
and is not a write-permission or persistence probe. Without the marker, ordinary
selection remains unchanged: absent key uses best-effort attachments, present
key uses only the file sink, whose failures occur at publication.

The future observation workflow must create and verify this exact marker
against its **validated unit bundle before launch**, keep the products stable,
and own the fresh per-run **0700 directory preflight** and launch-time forwarding.
No marker or workflow is installed here; closed `prepare.py` profiles and the
UI runner/app transport are unchanged. This is a **process-side pre-body guard,
not pre-host-startup qualification**, a sandbox-access guarantee, test coverage,
or platform delivery proof. Actual iOS forwarding, sandbox access and retained
file receipts remain observational; earlier Mac file receipts do not prove them.

## Hosted CI observation (#693)

`.github/workflows/mac-isolated-observation.yml` runs one sealed
`FluxKlangMacIsolatedTests` observation on the hosted `xcode-27` image. Part of
#693 and #60; #60 remains open. It runs `build-for-testing`, requires exactly one
generated `.xctestrun`, and computes its SHA-256 once in CI. That hash is a
CI-computed pin, not an independently reviewed one: it binds only build,
`prepare` and `validate` within this one run, and is never recomputed or
re-pinned after a refusal. It then runs `prepare` and `validate` with
`--profile mac-isolated-unit` and one `test-without-building`. Its argv follows
the candidate argv under "Single-attempt Mac process library" below, without
`-derivedDataPath` or `-test-iterations 1`: it keeps `-parallel-testing-enabled
NO`, adds no filters or retries, and is recorded exactly. `-test-iterations 1`
is omitted because an actual local Xcode 27.2 invocation rejected it (exit 64;
no tests ran); behavior on Xcode 27.1 is unverified.

A `prepare`/`validate` refusal is an expected possible first result: the
`OBSERVED` allowlist exactly matches an earlier specimen, and Xcode 27.1 output
may differ. A refusal is recorded, not repaired or retried; it is a result about
the profile and toolchain, not evidence about #60. Two deviations are recorded
in the run summary:

- The build uses `CODE_SIGNING_ALLOWED=NO`, as `make test-mac` does. The host is
  ad-hoc signed by the linker without entitlements and runs unsandboxed.
- The fresh 0700 receipt directory is passed as
  `TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR`, not in the xctestrun
  `EnvironmentVariables`, because the closed profile adds only
  `FLUXKLANG_AUDIT_RUN_ID` and the prepared output must not change. Delivery
  through the `TEST_RUNNER_` prefix is unverified; a missing key is a known trap path.

Only a summary is kept: counts, redacted and trimmed failure text, and
receipt-file counts. Receipt filenames (published or `.partial`, including path
forms) and UUIDs other than the run ID are redacted from xcresult text before it
is truncated or stored (`observation_summary.py`). Receipt contents, the result
bundle and DerivedData are not uploaded. This is an
observation, not qualification of #60; the limits above still apply.

## Pure fixture checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/test-audit-run -p 'test_prepare*.py' -v
```

Tests use independently transcribed specimen metadata, `TemporaryDirectory`, and
only the current Python interpreter for CLI subprocess tests. They do not read
or mutate native products, original specimens, Build trees, or repository files.
They cover successful preparation/preservation, distinct identities, non-clobber,
failure cleanup, read-only validation, digest/path binding, and adversarial
layout/environment/parser/identity refusals. Retention-request fixtures also
check exact 3/7 leaf paths and values, old-profile byte preservation, closed
schema/policy validation, rehashed partial changes and relabelled cross-profile
refusals. No Xcode builds are needed.

## Mac compile-product receipt producer (#277; source implementation only)

`build_mac.py` and `build_receipt.py` add a **separate compile-only producer**:
fixed compile → accepted Mac retention-request preparation → whole-Products seal
→ externally SHA-pinned read-only consumer. This is not a test/app launcher,
runtime authorization, sandbox, compiler-input closure, or qualification result.
Neither tool invokes `test-without-building`. Existing preparer APIs, schemes,
Makefile recipes and runtime code are unchanged.

The following describes the interface, **not permission to execute a native
build**. A coordinator must separately provision and authorize a fresh ordinary
local clone and all package checkouts in an exclusively controlled workspace:

```text
W/source
W/Packages/workspace-state.json
W/Packages/checkouts/<each of the nine pinned identities>
```

`W` and every absolute ancestor must be real directories, not symlinks. Use
canonical absolute UTF-8 paths, including `/private/...` rather than a symlinked
temporary-directory spelling on macOS. `W/DerivedData` and `W/build-evidence`
must not exist. Source must match independently reviewed full lowercase
40-hex commit and tree IDs. Each source/package root must have a real `.git`
**directory**. All non-directory `.git` markers are refused before reading
marker contents or invoking Git for that root. File pointers, including wholly
internal linked-worktree and separate-gitdir layouts, are unsupported even when
all referenced storage is inside W. An implementation-development linked
worktree is therefore **not** an eligible producer workspace. Provisioning is
external; the producer never clones, fetches, resolves packages, regenerates
projects, or copies source/products to manufacture provenance. Provisioning
provenance must be retained separately by the coordinator.

For the reviewed installed SDK, the coordinator must preprovision exactly these
nine observed directory paths relative to a fresh, private **0700** W, **before
the baseline observation, preflight and claim**. Every listed directory had
mode **0777**; the required child shapes are:

| Workspace-relative directory | Children |
| --- | --- |
| `source/FluxKlang.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration` | Empty |
| `Packages/checkouts/swift-atomics/.swiftpm` | Only `xcode` |
| `Packages/checkouts/swift-atomics/.swiftpm/xcode` | Empty |
| `Packages/checkouts/swift-collections/.swiftpm` | Only `xcode` |
| `Packages/checkouts/swift-collections/.swiftpm/xcode` | Empty |
| `Packages/checkouts/swift-nio/.swiftpm` | Only `xcode` |
| `Packages/checkouts/swift-nio/.swiftpm/xcode` | Empty |
| `Packages/checkouts/swift-system/.swiftpm` | Only `xcode` |
| `Packages/checkouts/swift-system/.swiftpm/xcode` | Empty |

These are SDK-specific provisioning prerequisites, not inventory exemptions,
producer-created repairs, or a general compatibility guarantee. The directories,
their modes and their child shapes remain covered by the existing exact
inventories and before/after comparisons. Do not create or repair them after a
claim. A consumed workspace, successful or failed, must never be repaired,
retried or relabeled for a different source candidate.

```sh
python3 -B scripts/test-audit-run/build_mac.py produce \
  --workspace /canonical/fresh/W \
  --expected-commit REVIEWED_40_HEX_COMMIT \
  --expected-tree REVIEWED_40_HEX_TREE
```

The one fixed recipe is:

```text
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
  -project W/source/FluxKlang.xcodeproj
  -scheme FluxKlangMacIsolatedTests
  -configuration Debug
  -destination platform=macOS,arch=arm64
  -jobs 2
  -derivedDataPath W/DerivedData
  -clonedSourcePackagesDirPath W/Packages
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  build-for-testing
  CODE_SIGNING_ALLOWED=NO
```

Arguments are passed as an array, without shell expansion. Working directory is
`W/source`. Environment is exactly:

| Key | Value |
| --- | --- |
| `DEVELOPER_DIR` | `/Applications/Xcode.app/Contents/Developer` |
| `PATH` | `/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin` |
| `HOME` | `W/build-evidence/home` |
| `TMPDIR` | `W/build-evidence/tmp/` |
| `LANG`, `LC_ALL` | `C` |
| `PYTHONDONTWRITEBYTECODE` | `1` |
| `USER`, `LOGNAME` | executing account from `pwd.getpwuid(os.getuid())` |

No ambient environment or build override is inherited. HOME/TMP and recipe
flags are configuration, **not filesystem/network confinement**. Xcode/build
scripts still require trusted custody and external execution authorization.

### Defined evidence and refusal boundaries

- Every tracked regular source file has its Git mode, current permission bits and
  streamed SHA256 retained. Working bytes are checked against the Git blob ID;
  staged changes and untracked/ignored files are refused. Root and directories
  are inventoried too. `project.yml`, generated PBX, isolated Mac scheme and
  `Package.resolved` must be tracked. No project regeneration occurs.
- Git control locations and root-inclusive inventories are separate from
  compiled source. All must be inside W. Git-control links, alternates, Gitlinks/submodules,
  shared source/Git regular-file hardlinks (even internal ones), partial/promisor
  repositories, config includes and escaped/multiline local config are refused.
  Git reads use a clean environment, disable global/system configuration,
  optional locks, fsmonitor, hooks, external diff/attributes and lazy fetching;
  they do not refresh the index. Retained local Git config remains a custody
  surface, not a fully analyzed language or execution sandbox.
- Lockfile version 3 supplies the only pin table, without URL normalization.
  Exactly `swift-ascii`, `swift-atomics`, `swift-collections`,
  `swift-data-parsing`, `swift-nio`, `swift-osc`, `swift-osc-core`,
  `swift-osc-io-nio`, `swift-system` are required. Workspace state version 7
  must have empty artifacts/prebuilts and exactly nine unique dependencies:
  `basedOn:null`, matching remote source identity/location, retained nonempty
  name, source-control checkout revision/version, and `subpath == identity`.
  Every checkout receives the same clean Git/source inventory checks.
- The only package fixture-link exception is under the exact root
  `W/Packages/checkouts/swift-nio`, at these two relative paths:

  | Link | Literal target | Required same-parent referent |
  | --- | --- | --- |
  | `Tests/NIOFSIntegrationTests/Test Data/Foo.symlink` | `Foo` | Real directory with a component-delimited tracked regular-file descendant |
  | `Tests/NIOFSIntegrationTests/Test Data/README.md.symlink` | `README.md` | Real independently inventoried, Git-verified regular file |

  The actual reviewed lockfile, workspace state and checkout Git revision remain
  the sole pin authority; there is no second revision table or caller policy.
  Each link is inventoried as exactly `{path, type:"symlink", mode, target}`,
  using its **own** permission bits and literal target, never referent metadata.
  Parent opens and `readlink` are descriptor-relative/no-follow; target bytes
  obey the existing path bound, and the link consumes an entry/depth/path budget.
  Git must record mode `120000` and the blob hash of the literal `readlink` bytes.
  A regular file containing the same bytes is not a link substitute. Referents
  must be real same-parent entries, not links, and retain all normal content,
  hardlink and cleanliness checks. Directory existence or a null tracked-entry
  lookup alone is not proof: a tracked descendant under `Foo/` is required;
  `FooSibling/...` does not count. All referent contents remain at their actual
  paths in the inventory; links are never traversed, flattened or excluded.
  Receipt schema and live evidence reconstruction recompute this same fixed
  root/path/target/type exception; receipt labels cannot grant it.
  Other paths/packages, source, Git control, Products, metadata and generated
  inputs remain link-free. Swift input witnesses still require regular,
  no-follow paths: these test-data aliases, including traversal to a `.swift`
  descendant through `Foo.symlink`, are not compiler-input aliases. This is not
  general link support or a new C/compiler/runtime closure claim.
- Both exact arm64 lists are mandatory and nonempty:
  `Intermediates.noindex/FluxKlang.build/Debug/FluxKlangMac.build/Objects-normal/arm64/FluxKlangMac.SwiftFileList`
  and the corresponding `FluxKlangMacTests.build/.../FluxKlangMacTests.SwiftFileList`.
  All actual `.SwiftFileList` files below `W/DerivedData/Build/Intermediates.noindex`
  are captured by bounded traversal, not guessed target associations.
- Lists are UTF-8 absolute LF-separated `.swift` paths; one final LF is
  optional. Literal spaces remain accepted. In one pass per line, only a
  backslash immediately followed by **ASCII space** decodes to one literal
  space. Every other escape, dangling/doubled backslash and line continuation
  is refused. No meaningful spaces are stripped or shell-split; there is no
  shell expansion, `shlex`, or generic response-file parser. BOM/NUL/CR, quotes,
  nested `@` lists and interior blank lines remain refused. Canonical paths,
  the 4,096-byte UTF-8 path bound and duplicates are checked **after decoding**:
  raw-space and escaped-space aliases in one list are duplicates.
  The 2 MiB raw-list bound and original-byte witness hashes are unchanged;
  decoding is only for path associations and existing regular/no-follow checks.
  Even a raw-byte mutation preserving decoded paths invalidates the pinned
  witness. Every input must be a regular file associated with exactly one
  inventoried tracked source/package file, or a generated Swift file under
  `Intermediates.noindex` or `Build/DerivedSources`. The selected generated
  file set and its parent directory modes are retained; this is **not a whole
  generated-directory inventory**. Validation reconstructs ordering and
  associations rather than trusting category labels.
- This is a **limited Swift-input witness**, not complete C/compiler/SDK or
  runtime input closure. It does not invent or parse response-file evidence.
- Xcode `Contents/Info.plist`, `Contents/version.plist` and the fixed regular
  `xcodebuild` binary have independent raw byte/mode witnesses. Only the fixed
  installed `Info.plist` additionally accepts bytes beginning `bplist00`, using
  stdlib `plistlib` with explicit `FMT_BINARY`. Its dictionary factory refuses
  duplicate/non-string keys, including in nested dictionaries; a dictionary
  root is required before normalization. XML Info and `version.plist` retain
  the accepted strict UTF-8 XML parser. All `.xctestrun` constraints remain
  XML-only and unchanged. Both toolchain plists retain their
  individual `CFBundleShortVersionString`/`CFBundleVersion`; version.plist must
  contain `ProductBuildVersion`. `DTXcodeBuild` and `ProductBuildVersion` are
  separately retained wherever present, never equated across concepts (for
  example, Info `DTXcodeBuild=27B51` versus version `ProductBuildVersion=27B52`).
  The existing 2 MiB raw-read bound and raw witnesses/schema are unchanged.
  Malformed binary parsing, including recursion failures, is refused without
  swallowing interruption exceptions. This does **not** establish generic
  binary-parser heap/time bounds or complete toolchain closure: these installed
  files remain trusted custody surfaces.
- Exactly one strict original Mac `.xctestrun` must be a Products-root sibling.
  Before real preparation, bounded parsing and the actual `output_paths`,
  `transformed`, `intent_record` helpers precompute exact output sizes with a
  fixed-length canonical UUID4 exemplar. XML uses `FMT_XML, sort_keys=False`;
  intent uses indented sorted JSON plus LF. Canonical UUIDs and hashes remain
  fixed-width unescaped ASCII. Actual paths/bytes are bounded and rechecked,
  then **real `prepare.prepare` and real `prepare.validate`** bind the original,
  prepared output, intent, UUID and exact retention-request profile.
- Only after preparation is **all of in-place Products** inventoried: root,
  every directory (including empty ones), every regular file, all permission
  bits, sizes and streamed SHA256. No suffix exclusions or tolerated additions.
  Another valid prepared pair is an unexpected addition. Products cannot be
  relocated, reused, repaired, or prepared again. Whole Products is conservative
  compile-product scope, not proved minimum scope or runtime loader closure.

Fixed inclusive limits, with no caller overrides:

| Resource | Limit |
| --- | --- |
| Receipt bytes (and each bounded Git observation) | 33,554,432 (32 MiB) |
| Each parsed metadata/source-list file | 2,097,152 (2 MiB) |
| Each declared tree, root included | 200,000 entries |
| Depth below tree root | 64 |
| Aggregate regular bytes per declared tree | 68,719,476,736 (64 GiB) |
| Each path, UTF-8 encoded | 4,096 bytes |

Traversal streams directory entries and remaining byte budgets, rejects excess
rather than truncating, and uses ancestor-aware descriptor-relative no-follow
opens. Except for the two fixed package fixture links above, links (including
dangling links and absolute ancestors) and special entries are refused.
The existing preparer's internal reads are unbounded;
bounded pre/post checks **require exclusive custody**, not protection against
a hostile concurrent writer. There is no monkeypatch of production reads or
change to preparer APIs.

### Claim, commit point and external consumption

Exclusive `build-evidence` creation consumes W permanently. Claim, compile
intent, stdout/stderr and directory syncs precede the single spawn. Failure or
interruption preserves the claimed workspace; no retry/cleanup/reuse is
provided. Only the actually spawned process group is eligible for bounded
best-effort termination/reaping. Detached or unreaped descendants require
coordinator reconciliation; termination never proves all descendants are gone.

Source/packages/toolchain are compared before/after compile and at consumption.
Logs and the completed precommit journal are finalized before hashing; the
original pre-spawn intent is separately preserved and hashed. The schema-checked
receipt is exclusively written to `receipt.pending`, handling short and
zero-progress writes, then flushed/fsynced/closed. Bounded reread and full
evidence validation precede atomic no-replace hardlink creation of
`build-evidence/receipt.json`: **that is the single commit point**. Pending may
remain; neither name is written afterward. No partial pending receipt is
accepted. Precommit failures preserve evidence with no newly accepted receipt.
Postcommit sync/report failure means **committed, durability/reporting
uncertain**, never deletion, invalidation or retry. Reconcile interruptions by
inspecting the final name and exact bytes, not by regenerating evidence.

Producer output identifies a SHA; it is **not approval**. After independent
review, a future consumer must receive an externally supplied expected SHA:

```sh
python3 -B scripts/test-audit-run/build_mac.py validate \
  --receipt /canonical/fresh/W/build-evidence/receipt.json \
  --expected-sha256 EXTERNALLY_APPROVED_64_HEX_SHA256
```

Validation checks the bounded bytes against that pin **before trusting paths**,
then enforces duplicate-free closed typed schema, fixed layout/recipe, current
evidence and whole Products, invokes real accepted metadata validation, and
returns the bound intent. It never writes, repairs, compiles, launches tests,
creates approval or computes a replacement expected fingerprint. Bytecode is
disabled before sibling imports. Reads may change access times. CLI statuses:
0 success, 1 refusal/I/O/interruption, 2 argument error, 3 committed/uncertain.

Operational assumptions remain explicit: independently reviewed provisioning,
exclusive coordinator custody through child reconciliation, complete trusted
Xcode/SDK installation, package provenance, installed platform/system/dyld
integrity, arbitrary runtime loading/resource access, future UUID delivery and
host freshness, and receipt persistence. Three Xcode witnesses do not establish
installation integrity. A future separately reviewed runner must validate
before its own one-use execution claim, keep its artifacts outside Products,
and use the exact returned prepared path. No runner or runtime permission is
provided here, and Xcode is not promised to leave Products unchanged at runtime.

### Library-only one-use Mac launch reservation

`mac_launch_claim.claim(receipt_path, expected_sha256)` is a library API only:
no CLI, callback, launcher, override or execution workflow. It first calls the
real externally pinned receipt consumer. From the complete validated intent's
original `W/DerivedData/Build/Products/<original>` path it derives W, cross-checks
the prepared/intent siblings and the exact supplied
`W/build-evidence/receipt.json` path, and reserves only
`W.parent / (W.name + ".mac-launch-evidence")`. It does not derive authority by
stripping a caller pathname, resolve aliases, prepare again, generate a UUID,
compile or launch. Restricted read-only Git observations by the consumer remain
part of validation.

Before creating anything, it checks absolute unambiguous UTF-8 paths, the
4,096-byte ceiling, real no-follow directory ancestors and local component/path
limits (including the suffixed basename, record pathname and syscall NUL).
Unsupported limits refuse. A closed version-1 record, encoded at most 2 MiB,
contains `status: reservation-recorded`, validated W, the fixed reservation
location, exact receipt path/external SHA and the **complete returned intent**.
There is no timestamp or new identity. The intent file's own digest is
transitively receipt-bound; it is not a field invented inside that intent.

Exclusive private directory creation **consumes the attempt**. Any existing
file, directory, partial claim or symlink (including dangling) refuses reuse;
filesystem lookup, not textual alias normalization, arbitrates collisions.
The parent is synced promptly, then fixed `prelaunch.json` is exclusively
written with short-write handling, flushed, fsynced and closed. The claim
directory and parent are synced; bounded no-follow reread must match both bytes
and record, with exactly that one directory entry. Real receipt validation must
again return the unchanged intent before the record is returned. W is not
modified (reads can change access times).

Every post-mkdir failure/interruption preserves the claim, including an empty
directory, zero-length/partial record, failed sync/check and mkdir success
interrupted before reporting. There is no cleanup, repair, resume, overwrite or
retry. Failed/interrupted parent fsync cannot promise power-loss survival.
Ambiguous mkdir/reporting requires **coordinator quarantine even if a later
inspection finds no marker**; absence after uncertainty is not retry permission.

External coordinator custody must cover W, its parent and stable ancestor/name
mappings throughout validation/publication, then preserve the reserved slot:
no deletion, replacement, rename or recreation. This is a local reservation,
not crash-proof persistence, global deduplication, malicious-concurrency
protection or sandboxing. `reservation-recorded` is not authorization, launch,
fresh-host custody, auditing or actual retention. Separate reviewed launcher
integration, execution authorization, reconciliation and retention qualification
remain required; this increment does not complete #60.

Run all pure audit-run fixtures (no native tools or installed product reads):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s scripts/test-audit-run -p 'test_*.py' -v
```

Producer fixtures use disposable synthetic ordinary Git repos, all nine actual
checkout/state associations, both mandatory lists, extra lists and a generated
Swift input. Only compile/toolchain and explicit failure-injection I/O/process
boundaries are substituted; preparation, validation, sealing and consumption
are real. Package-link fixtures include both genuinely tracked NIO links and
referents, mode/blob/type/root/target/permission drift, rehashed receipt
malformations and Swift descendant-alias refusal. Binary Info and XML
regressions remain covered. Native profile compatibility and qualification require separate
review and authorization.

### Single-attempt Mac process library (#294; source-only, unqualified argv)

`mac_launch.launch(receipt_path, expected_sha256)` accepts exactly those two
inputs. It calls the real `mac_launch_claim.claim` once **in this invocation**,
uses the returned record's `reservation` and unchanged `intent.output.path`,
and never continues a prior record/marker. There is no CLI, Makefile integration,
caller configuration, callback/backend, retry or resume.

The fixed candidate argv is:

```text
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
test-without-building -xctestrun <record.intent.output.path>
-destination platform=macOS,arch=arm64
-parallel-testing-enabled NO -test-iterations 1
-derivedDataPath <slot>/DerivedData -resultBundlePath <slot>/result.xcresult
```

**This combined invocation remains unqualified**, particularly
`-derivedDataPath` with scheme-less `-xctestrun`. Installed option help and fake
process tests prove neither compatibility nor incompatibility. Resolve that
separately before any real call; do not investigate by executing/retrying a
consumed attempt, adapting flags, adding a scheme or moving Products. This is
not a supported execution workflow or permission to run tests/apps.

Note: an actual local Xcode 27.2 invocation rejected `-test-iterations 1`
("Must specify -test-iterations with more than 1 iteration.", exit 64) before
any test ran. Do not copy that flag from this candidate argv; `mac_launch.py`
itself is unchanged here.

After claim, every runner path (including the longer `process-outcome.json`)
is checked for literal UTF-8/NUL grammar, the 4,096-byte ceiling and local
component/path limits. A successful claim followed by refusal is consumed.
`prelaunch.json` is preserved. Private exclusive `home`/`tmp` directories and
exclusive regular `stdout.log`/`stderr.log` are created in the slot; both Xcode
destinations must be absent under no-follow checks, including dangling links.
Pre-spawn log flush/fsync and directory syncs leave log descriptors open and
usable. The real externally pinned receipt consumer runs again **after artifact
setup** and must return the complete unchanged claimed intent.

Exactly one no-shell, new-session spawn uses the slot as cwd, `stdin=DEVNULL`,
`close_fds=True`, and direct stdout/stderr file descriptors. Its environment is
closed: `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, private slot
`HOME`/`TMPDIR`, and `LC_ALL=C`. The caller environment is not mutated or copied,
and the prepared target's isolation/UUID environment is not reconstructed.
The prepared xctestrun bytes and location remain unchanged by the library.

Only an observed zero, nonzero or signal exit followed by successful log
finalization and outcome publication returns. The exact nine-field record is:

```text
schema_version: 1
state: process-exited
reservation: <record.reservation>
receipt_sha256: <external expected SHA256>
prepared_xctestrun: <record.intent.output.path>
pid: <obtained positive integer>
returncode: <observed integer, negative signal codes preserved>
descendant_closure: unproven
artifacts_sealed: false
```

Integers exclude booleans. Fixed `process-outcome.json` is exclusively written,
bounded to 2 MiB, with short/zero-write handling, flush/fsync/close, directory
sync and bounded exact byte/type-sensitive reread. No arbitrary exception or
log payload is included. Spawn/wait/timeout/interruption, log finalization and
report failures raise, never return a failure-as-success variant. Partial and
complete-but-unreported outcomes remain in place; nothing is repaired or
removed. Every consumed second invocation refuses.

The process wait is 1800 seconds. Failure triggers bounded best-effort
TERM/5-second grace, then KILL/5-second reap grace only for a successfully
obtained valid positive child/session. There is no PID discovery or kill after
ambiguous spawn without a returned handle, no process-global signal handlers,
and no signaling of zero/negative/unvalidated IDs. Observing/reaping leader
exit stops further signaling: it does **not** reconcile the group. Catchable
interrupts propagate after best-effort cleanup; cleanup errors do not turn
failure into success. Detached descendants, fatal termination, repeated
interrupts, failed cleanup or incomplete reporting require external quarantine,
even if a marker later disappears. Wait limits do not bound filesystem calls,
the whole operation or descendant lifetime.

One Xcode spawn is not one host-process proof. This record asserts no PASS,
qualification, host freshness, UUID delivery, result identity, audit coverage,
retention, descendant closure or sealed output. Direct child writes are not
library-observable: log finalization does not establish complete log capture.
Child logs/results/path growth are **not** bounded by the outcome's 2 MiB limit.
Private HOME/TMP is not a sandbox and intended DerivedData placement is not
confinement. External storage limits, privacy handling, continuous custody and
compiler/runner descendant reconciliation remain mandatory.

Pure tests in `ProducerTests` use real preparation, receipt validation and
claiming in disposable synthetic workspaces. Every launch call, including
refusals, installs a private fake Xcode spawn boundary and a private signal
boundary with fail-fast guards against actual signaling. Production waiting,
cleanup and reporting run with fake handles; shared `subprocess.Popen` and
consumer Git are not mocked. I/O faults cover paths/setup/sync, actual evidence
drift after setup, claims/competition, exits, wait/cleanup uncertainty, log
finalization and bounded publication. Fake whole-W preservation checks
bytes/modes/inode/mtime/ctime (not atime); it is **not proof real Xcode preserves
Products**.

Stop at source acceptance. Actual execution separately needs explicit
authorization, selected source/receipt pins, an eligible unreserved workspace,
compatible invocation, continuous custody, isolation/process attribution and
evidence/storage procedures. W1–W4 and other reserved lanes are not fixtures.
Full #60, both iOS targets, G2, #190 and #191 remain open.
