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
No command here runs `xcodebuild` or `test-without-building`. Runner integration,
canonical scope adoption, checker/live extraction, iOS/UI runtime handoff, live
profiles, and retained runtime results require separate review/authorization.

All profiles deliberately fix unrelated diagnostic/language/logging
values as well. Broader acceptance requires separate review; this implementation
conservatively refuses that drift rather than inferring a wider supported shape.

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
