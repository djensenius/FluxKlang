# Mac and iOS audit-run preparation (partial regression only)

`prepare.py` is an external, Python-standard-library metadata preparer, **never a
launcher**. It generates a fresh UUID4 before any hypothetical future launch.
It imports no app/production modules and performs no subprocess, network,
test-host, UI-event, service, or hardware execution. There is no in-app fallback
or conditional audit no-op.

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

The complete reviewed input key/value/type allowlists are `OBSERVED` and
`IOS_OBSERVED` in `prepare.py`. All profiles intentionally require **all observed values**,
including unrelated diagnostic, logging, environment, timeout, language, and
attachment fields, including `SystemAttachmentLifetime = deleteOnSuccess` and
`UserAttachmentLifetime = deleteOnSuccess` on every test target. Except for the
explicit profile transformations described here, parsed values and supported
Xcode path placeholders are preserved exactly; XML
formatting/key order need not be byte-identical. No placeholder is expanded and
no referenced product is opened. No arbitrary configuration switches exist.

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

The new intents use integer `schema_version: 2` and add only `attachment_policy`
to the existing intent fields. Its closed shape is:

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

On caught preparation failures, newly created files are removed (intent first);
preexisting paths are never removed. Use a stable caller-controlled directory.
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

Only a redacted summary is kept: receipt filenames (published or `.partial`,
including path forms) and UUIDs other than the run ID are redacted from xcresult
text before it is truncated or stored (`observation_summary.py`).

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

Only a summary is kept: counts, trimmed failure text, and receipt-file counts.
Receipt contents, the result bundle and DerivedData are not uploaded. This is an
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
