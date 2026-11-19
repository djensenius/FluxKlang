# Kernel mirror (#364, #64)

`.github/workflows/kernel-mirror-tests.yml` runs the pure render-kernel Swift Testing suites
(`FluxKlangTests/RealtimeHandoffTests*`) on the hosted `xcode-27` image, outside the app. The
generator byte-copies the files listed in `manifest.txt` into a throwaway SwiftPM package. The
package has a `FluxKlang` library and a `FluxKlangTests` test target, so the copied tests'
`@testable import FluxKlang` works unchanged. The job then runs, serially:

1. **Debug**: all mirror suites, including the lock source scans.
2. **Release** (`-c release -Xswiftc -enable-testing`): all suites. The log check requires
   `readmissionRenderPathAllocatesNothing()` to report passed, not skipped, so the
   `malloc_logger` allocation probe really ran in an optimized build and counted zero
   render-path allocations. It requires the same of the four `FaultRaiseAllocationBounds` probes
   (`chainTokenRaisePathsAllocateNothing()`, `sysexFaultingAcceptAllocatesNothing()`,
   `retireBacklogAndContendedRetireAllocateNothing()`, `criticalRefusalAllocatesNothing()`): zero
   allocations on the fault-chain raise paths they drive (chain token primitives and the contended
   fallback, SysEx abort and overflow, retire backlog and contended retire, critical refusal and
   contended critical refusal).
   `carryPlanningAndConsumptionAllocateNothing()` must also **pass, not skip**: actual canonical
   `KernelCarryPlan` construction and fixed-result reads into preallocated sinks must count **zero**,
   with a positive control and separate warm-up (not equality to an allocating baseline). The planner/helper
   source scan must pass in Debug and Release. Object/slot construction is deliberately outside this
   guarantee; see [storage and work bounds](../../docs/kernel-carry-plan.md).
3. **Thread Sanitizer**: `--sanitize=thread --filter 'RealtimeHandoffTests.*(Cycle|Stress)'`, three
   times. It fails on a nonzero exit or any `WARNING: ThreadSanitizer` line. Each run must also
   report `readmissionRenderPathAllocatesNothing()` as skipped with its Thread Sanitizer reason. The
   probe skips only when `__tsan_init` is loaded, which proves the TSan runtime was active.

Before running, the job checks that `xcrun --find swift` is the pinned Xcode's toolchain and that
the `swift` on `PATH` reports the same Swift 6.4 version. Every run gets a fresh `FLUXKLANG_AUDIT_RUN_ID=$(uuidgen)`. The `.productionAccessAudit` suite
trait (`FluxKlangTests/ProductionAccessScope.swift`) records an issue without one.
`check-log.sh` checks each log and prints its test count for the step summary. Its
`--expect-skipped <test> <reason>` option requires a named test to be skipped for that reason.

For diagnostics, each hosted invocation also requests Swift Testing events with
`--event-stream-output-path` and xUnit with `--xunit-output`. An `always()` upload retains
the untrimmed merged stdout/stderr logs and available structured outputs for 14 days in
`kernel-mirror-diagnostics-<run_attempt>`: `debug.{log,events.jsonl,xunit.xml}`,
`release.{log,events.jsonl,xunit.xml}` and `tsan-<run>.{log,events.jsonl,xunit.xml}`.
Failed or interrupted invocations may leave partial or missing outputs; later runs still
do not execute after an earlier failure. These diagnostic files do not replace the
required console pass/skip checks or establish a pass from a parent suite or run summary.

## What it does not prove

- It tests the kernel as a **reference model**. It is not real-time certification: there is no
  audio thread, no deadline measurement and no CoreAudio/CoreMIDI. The allocation probes cover only
  the paths the tests drive, only allocations on the calling thread (not `mmap` or other threads),
  and only after a warm-up run that absorbs one-time runtime work. The lock check is a source scan,
  not a proof.
- It is **not #60 qualification**. It never builds or launches the app or an app-hosted test
  bundle, and it says nothing about app startup, services or hardware. `apple-build.yml` stays
  compile-only and `mac-isolated-observation.yml` is unchanged.
- TSan finds only the races that the stress tests' schedules actually hit. Three clean runs are
  bounded evidence, not proof that no race exists.
- The mirror compiles a subset of `Shared/`. A kernel file that compiles here can still fail in
  the app target, and the app-target build still covers that.

## Manifest

`manifest.txt` lists every file that is copied. It contains `Shared/Audio/Kernel/**` minus
`OfflineAudioRoutingProcessor.swift`, which needs the app's project/graph layer. It also contains
four UMP protocol files that `SysExChunk+UMP.swift` needs and `ProductionAccessAudit.swift`. The
tests are every `RealtimeHandoffTests*` file plus their support files. Generation fails loudly if:

- a listed file or tree is missing;
- an `exclude` no longer matches anything;
- a tree gains a non-Swift file;
- a new `FluxKlangTests/RealtimeHandoffTests*.swift` or `KernelRetirementCarryTests*.swift`
  file is not listed.

The non-Swift-file check ignores `.DS_Store` files.

A new kernel dependency outside the manifest shows up as a compile error in the mirror. Add the
file to the manifest after review.

Sources keep their repo-relative paths under `Sources/FluxKlang/`, and tests go flat into
`Tests/FluxKlangTests/`. The source-scan tests resolve
`../../Sources/FluxKlang/Shared/Audio/Kernel/Events` from `#filePath`, so they run in the mirror.
The CI log check requires them to report passed.

## Local use

```sh
dir=$(mktemp -d)                        # must be empty, absolute, yours and outside the repository
scripts/kernel-mirror/generate.sh "$dir"
cd "$dir"
FLUXKLANG_AUDIT_RUN_ID=$(uuidgen) swift test --disable-xctest 2>&1 | tee debug.log
bash "$OLDPWD/scripts/kernel-mirror/check-log.sh" debug.log
rm -rf "$dir"                           # the package is throwaway; never commit it
```

You need Xcode 27 or later (Swift tools 6.4, macOS 27 SDK). Set `DEVELOPER_DIR` if
`xcode-select` points elsewhere.
