# Mac and iOS audit-run preparation (partial regression only)

`prepare.py` is an external, Python-standard-library metadata preparer, **never a
launcher**. It generates a fresh UUID4 before any hypothetical future launch.
It imports no app/production modules and performs no subprocess, network,
test-host, UI-event, service, or hardware execution. There is no in-app fallback
or conditional audit no-op.

## Two closed profiles

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

The complete reviewed key/value/type allowlists are `OBSERVED` and
`IOS_OBSERVED` in `prepare.py`. Both intentionally require **all observed values**,
including unrelated diagnostic, logging, environment, timeout, language, and
attachment fields. Their parsed
values and supported Xcode path placeholders are preserved exactly; XML
formatting/key order need not be byte-identical. No placeholder is expanded and
no referenced product is opened. No arbitrary configuration switches exist.

Unknown/missing fields, changed values, alternate layouts, binary plists,
FormatVersion2, duplicate plist/JSON keys, unsupported scalar types, ambiguous
metadata, filters (even empty), extra targets, unreviewed host markers, alternate
audit environments, conflicting schemes, and unresolved audit placeholders are refused,
not silently dropped. Any preexisting run identity is refused, including a valid
UUID, an empty value, or a malformed value. Even matching audit keys in
`TestingEnvironmentVariables` are outside both profiles. Cross-profile inputs
and intents are refused; a rehashed output still must match the full permitted
transformation.

**Explicit exclusions:** other iOS layouts/destinations, full-regression claims,
Release, live Apple qualification, and any other target composition. Existing
app/UI targets are unchanged; this utility never removes tests or presents skipped tests as green.
The retained layout specimens are read-only metadata examples, **not
execution-ready artifacts**.

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
parsed output against the original plus only the authorized run-key additions.
Final-component file symlinks are refused; resolved parent paths are recorded.
An orphan or partially written pair cannot validate. Exit status is `0` for
metadata success, `1` for refusal/I/O failure, and `2` for invalid CLI arguments.

For the combined iOS metadata, use the same `prepare` and `validate` commands
with `--profile ios-simulator-isolated-unit-ui-v1`, the separately reviewed iOS
input path/hash, and its printed sibling output/intent paths. The CLI never
infers a profile or selects a destination.

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

The existing UI helper sets launch flags but does **not** explicitly forward the
audit UUID. The three iOS metadata insertions express intended custody only;
Xcode/helper environment delivery remains unqualified. Both profiles preserve
the observed `deleteOnSuccess` system/user attachment defaults. This change
adds no retained receipts or full audit-coverage guarantee.

Current Makefile launch recipes and raw Cmd+U remain unchanged and unvalidated.
No command here runs `xcodebuild` or `test-without-building`. Runner integration,
canonical scope adoption, checker/live extraction, iOS/UI runtime handoff, live
profiles, and retained runtime results require separate review/authorization.

Both profiles deliberately fix unrelated diagnostic/language/logging
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
layout/environment/parser/identity refusals. No Xcode builds are needed.
