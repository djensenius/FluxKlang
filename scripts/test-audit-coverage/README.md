# Unit audit source inventory

This standalone SwiftParser checker compares reviewed unit-target membership with
the generated PBX source phases, inventories supported Swift Testing owners, and
requires the canonical `.productionAccessAudit` trait on each owner. It does not
execute application code or tests, discover runtime tests, or validate receipts.
Unsupported discovery contexts (including XCTest ancestry) fail closed.

## Build and run

Run from the repository root using Bash or Zsh. The qualified configuration is
Apple Silicon, Swift 6 language mode, Swift 6.4.2 and macOS SDK 27.2, targeting
macOS 27. Use one Xcode toolchain consistently for the compiler, SDK and matching
`SwiftParser`/`SwiftSyntax` host libraries. No package download is needed.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ulimit -c 0
root="$PWD"
work="$(mktemp -d "${TMPDIR:-/tmp}/fluxklang-test-audit.XXXXXX")"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
host="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host"
sources=(scripts/test-audit-coverage/*.swift)
common=(-swift-version 6 -target arm64-apple-macosx27.0 -sdk "$sdk"
        -I "$host" -L "$host" -Xlinker -rpath -Xlinker "$host"
        -module-cache-path "$work/module-cache")

xcrun swiftc "${common[@]}" "${sources[@]}" -o "$work/Check"
"$work/Check" --root "$root" --mode inventory > "$work/inventory.json"
"$work/Check" --root "$root" > "$work/enforcement.json"
```

`--root` is absolute. The optional `--manifest` is root-relative and defaults to
`scripts/test-audit-coverage/registrations.json`. `--format text` selects a
human-readable report; JSON is the default. Modes and exit codes are:

| Exit | Meaning |
| --- | --- |
| 0 | Enforcement satisfied, **or explicitly non-enforcing inventory completed** |
| 1 | Structurally complete but registration/annotation obligations are unsatisfied |
| 2 | Invalid inputs or unsupported/incomplete structural analysis |

Always inspect `analysisComplete` and `enforcementSatisfied`. The initial
registration manifest is complete, but the roots are not yet annotated:
inventory intentionally exits 0 with `enforcementSatisfied: false`, while
default enforcement exits 1. Inventory success is not coverage or isolation.

## Headless fixtures

Using the same shell variables, compile fixture mode and copy the four required
reference inputs from the reviewed checkout. The fixtures parse these files;
they do not compile or execute their test bodies.

```bash
xcrun swiftc "${common[@]}" -D AUDIT_CHECK_TESTS \
    "${sources[@]}" -o "$work/CheckTests"
mkdir "$work/reference-sources"
cp FluxKlangTests/ProductionAccessScope.swift \
   FluxKlangTests/ProductionAccessScopeTests.swift \
   FluxKlangTests/AssistantMixerExecutionTests.swift \
   FluxKlangTests/AssistantActionPlanningTests.swift \
   "$work/reference-sources/"
"$work/CheckTests" --scratch "$work/fixtures" \
    --u1-root "$work/reference-sources"
```

Despite its historical name, `--u1-root` must contain all four files directly.
Use a fresh scratch directory for each fixture run: fixtures deliberately create
malformed projects, alternate sources and symlinks, and will not overwrite an
existing fixture world. The suite has 119 checks, including regressions
for unsupported XCTest discovery, nested PBX roots, standard macro handling,
opaque return types, specialized ancestry and erased generic-alias initializers.
The actual-source expectations currently reflect unadopted audit traits; review
those expectations when adopting or otherwise changing the reference sources.

Retain command output, source/input hashes and the reviewed manifest for evidence.
After the commands finish, remove only the generated scratch directory you
created, if its outputs are no longer needed; do not remove shared Xcode caches.

## Reviewed manifest maintenance

`specification.review: "REVIEWED"` records a review assertion, not authorization
or an automatic trust operation. The checker verifies the exact `project.yml`
SHA256, but does not parse YAML itself. After a project change:

1. Review the YAML unit-target directory/file memberships and target/configuration
   matrix, and regenerate/review the PBX project using the repository's process.
2. Update the membership transcription and specification digest only after that
   review. The supported PBX location is one repository-root
   `NAME.xcodeproj/project.pbxproj`, not a nested project.
3. Run explicit inventory and require `analysisComplete: true`. Review its
   `derivedRegistrations` against the intended owners before updating
   `registrations`; do not create an exemption baseline or hide missing traits.
4. Run default enforcement and preserve its actual result. Source adoption and
   later CI enforcement are separate work, not implied by manifest completion.

Rows identify source owners per target/module, Debug/Release configuration and
consistent symbolic `canImport(FluxKlangMac)`/`canImport(FoundationModels)`
assignments. They are not public `Test.ID`, parameterized case IDs, SDK
availability claims or expected runtime receipts. Input rechecks detect observed
changes, not an atomic filesystem transaction or adversarial change-and-restore.

Generic ancestry is handled conservatively: unsupported initializer chains fail
closed, without generic argument substitution or inferring ordinary ancestry
from rejection-only traversal. This inventory is not a Swift type checker.
