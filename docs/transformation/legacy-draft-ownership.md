# Legacy pending-draft ownership and migration handoff

**P14b1 / #773 — design/evidence prerequisite for #122 / #48.**
Source baseline: `17045692aaedac5abeb0f79c9893e8081436548d` (P14a #770).
This document implements no exclusion, loader, migration admission or startup wiring.
Current legacy editing, review, acceptance and discard remain unchanged.

## Decision and activation limit

A future **explicitly admitted** migration must terminally revoke both the old
legacy **file-writer lifetime** and its **in-memory publication/acceptance lifetime**.
Protecting only a rename or one store instance cannot satisfy this contract.
Cancellation, repeated load, revalidation, default construction and recovery must
not revive a closed lifetime. There is no automatic resumption after ambiguous IO.

Do not activate this policy until a supported authoritative successor handoff,
or an explicitly designed stopped/read-only outcome with usable failure UI, exists.
Terminal revocation is not permission to silently disable today's legacy workflow.
This document does not invent the successor or claim that inspection is loading.

## Current producer and owner inventory (source-derived)

Paths below are relative to the repository; line references describe the baseline.

| Surface | Current behavior and boundary that future admission must cover |
| --- | --- |
| `Shared/Store/PendingStudioPatchStore.swift:3–34` | `PendingStudioPatchPersisting` returns optional load and Void save. Each initializer creates an independent actor. `load` and save/delete perform synchronous Foundation IO inside that actor; no cross-instance admission or publication control. Default path is `assistant-pending-studio-draft.json`. |
| `Shared/Assistant/AssistantCore.swift:301–467` | MainActor `AssistantCoordinator` defaults to a new store. `load` publishes an awaited result without freshness/lifetime checking. Build and revalidation publish before awaiting persistence. Prepared commit checks cancellation/context/pending equality, then publishes and awaits save; cancellation may restore the old settled draft and save again. Discard clears memory then awaits deletion. The persistence loop can save repeatedly after reentrancy. |
| `Shared/Assistant/AssistantChatController.swift:221,474` | Typed chat creation runs in a tracked task; natural-language preparation awaits interpretation before prepared commit. Response cancellation/identity guards are not migration admission. Post-await replies/cards also need stale-lifetime handling. |
| `Shared/Intents/FluxKlangIntents.swift:181–254` | Siri text preparation and typed draft requests call the same coordinator commit/build paths. `prepareContext` loads equipment, environments and connections, not the pending draft. Intents may arrive before root loading finishes. |
| `Shared/Assistant/AssistantFallbackGenerator.swift:69` | Validation requests call coordinator revalidation and therefore persist. Provider/task cancellation is not a storage ownership boundary. |
| `Shared/Views/App/AppModel+Assistant.swift:49–105` | Review awaits live-reference refresh then revalidates; accept refreshes, revalidates and checks current snapshots before merging. `EnvironmentStore.replaceStudio` (`Shared/Store/EnvironmentStore.swift:273`) schedules separate environment persistence, then pending discard is awaited. Prevent stale draft acceptance as well as file recreation; graph mutation is another effect, not merely a pending-file write. |
| `Shared/Views/Studio/StudioView.swift:483` | Discard launches a task calling coordinator discard. A stale delete must not remove a successor's draft. |
| `Shared/Views/App/AcceptanceLaunchConfiguration.swift:84`; `Shared/Views/Studio/MultiRouteAcceptanceFixture.swift:58` | Acceptance setup also produces drafts through the coordinator; not an alternate pending-file implementation. |
| `Shared/Views/App/AppModel.swift:170–219`; `Shared/Views/App/AppRootView.swift:48` | Root `.task` calls `loadStores`; legacy domain stores load before `assistant.load`. Repeated root tasks are not single-flight. Cloud `reloadStores` does not reload pending. Both app entry points retain `AppModel.shared`, which is not an all-writer exclusion proof. |
| `Shared/Store/JSONFileStore.swift:79,91,113` | Arbitrary filename load/save is an available bypass. No production call targeting the pending filename was found. All found production pending-file writers use `PendingStudioPatchStore`; this is an inventory finding, not an API prohibition. |

Home/connections are cloud-eligible; pending draft and USB mapping are local.
Migration archives local Home bytes as evidence, not proof of cloud freshness.
No implemented document/presenter/FileProvider coordination was found in the app
sources. Claims here cover **supported cooperating production writers**, not all
processes, arbitrary filesystem clients, OS exclusion or a security boundary.
A future additional writer/process must join the contract or remain unsupported;
actor isolation, `inout` filesystem access and an advisory lock alone cannot prove it.

## Current migration mechanisms are not runtime ownership

`Shared/Persistence/Adoption/Migration/LegacyMigrationArchive.swift` preserves
adopted source bytes in `LegacyMigration.fluxklang`. `LegacyDraftRetirement.swift`
requires caller exclusion, compares the archived draft and renames without replacement
to `assistant-pending-studio-draft.retired-legacy1.json`; it does not revoke coordinators.
The store ignores that retired name, but a surviving owner can still save the original.

`LegacyMigrationLaunch.observe` is read-only P14a observation: report, eligible
receipt and inert review derive from one validated archive read. Archive/retire/
observe call sites found outside their implementations are tests, not a production
launch consumer. The source's “before stores load” prerequisite is not implemented
by the current `loadStores` ordering or by a once-per-process boolean.

`Shared/Views/Workspace/Project/PerformanceProjectSession.swift` owns a new unsaved
project; it has no authoritative restore path. `ProjectPackageInspectionLoader`
in `Shared/Persistence/Projects/Inspection/` decodes for inspection only and does
not install a project into that session. Neither supplies a migration successor.
`MigratedDraft`/archived review retain data and provenance with invalid authority;
reviewability, byte preservation and `canApply == false` do not revoke old live objects.

## Required boundary (not implemented)

1. Establish one ownership domain for the actual pending location, covering all
   admitted store/coordinator instances and every construction path. Define its
   scope across windows, intents, process restart and any supported extra process;
   never treat a fresh object or a path spelling as a fresh grant by default.
2. Before migration's protected reads or mutations, close admission to legacy
   load/build/revalidate/commit/restore/discard and their downstream publications.
   Record closure before acknowledging exclusion. Reject queued old operations at
   execution, even if enqueued earlier; actor scheduling is not a FIFO-drain proof.
3. Join already-running synchronous IO before acknowledging exclusion. Cancellation
   does not interrupt that IO or acknowledge its completion. Reject further loop
   saves, stale deletes and delayed operations instead of draining them into the file.
4. Bind every async result to its admitted lifetime. After awaits, check authority
   before publishing a load, result, navigation/review, restoration or acceptance.
   An unchanged draft UUID, equal snapshot or matching routing submission ID is not
   a lifetime grant. Invalidate retained old draft authority, not just on-disk lookup.
5. Hold protection through archive validation/creation, retirement and truthful
   outcome classification. Complete cleanup/join obligations even on cancellation;
   a temporary lock released at return must not reopen the terminal old lifetime.
6. Only a separately specified successor admission may enable fresh editing.
   Define authoritative loading, preserved-data review, graph acceptance, recovery UI
   and restart behavior before startup integration; never recast an archived draft
   as an authorized live draft merely by decoding its preserved bytes.

## Proposed ownership state table (requirements, not current states)

| State / transition | Old file and publication authority | Permitted work / exit |
| --- | --- | --- |
| Legacy open; no migration admitted | Existing workflows unchanged | Ordinary legacy use. Cancellation before admission does not close this lifetime. |
| Explicit migration admission → closing | New/queued legacy work rejected; old publication invalidated | Join synchronous IO already entered; no protected migration reads until exclusion is acknowledged. |
| Closing → excluded/migrating | Terminally revoked, including preexisting owners and delayed results | Archive/retire under exclusion; preserve precise outcomes. No implicit reopen on refusal/cancel. |
| Known pre-rename refusal after closure | Still revoked; preserved originals do not regrant authority | Explain refusal; retain evidence. Follow the designed stopped/recovery path, not old-owner retry. |
| Rename completed; sync/read-back failed or cancellation leaves outcome uncertain | Still revoked; no rollback assumption | Retain bytes and uncertainty; authorized recovery/classification only. Do not silently resume editing. |
| Retirement confirmed / already retired | Old lifetime remains revoked | Inert review and an explicitly admitted supported successor, or designed stopped/read-only outcome. |
| Restart / newly constructed owner after prior admission | Must not infer legacy authority from an original filename or missing file | Classify retained evidence truthfully before any new grant; restart admission mechanism remains to be designed. |

“Excluded” requires both storage completion and publication rejection; it is not
merely a held actor or a cancelled task. Failure before closure and failure after
closure are different user-visible outcomes. Admission itself must be explicit and
observable, so a failed pre-admission attempt cannot accidentally revoke editing.

## Truthful storage and failure policy

Future APIs must distinguish at least:

- load: valid payload, absent, malformed/unsupported, read failure and revoked;
- save/delete: accepted completion under the defined durability policy, failure,
  revoked and any genuinely ambiguous completion; Void is not success;
- cancellation before admission, rejection while queued, and cancellation after
  synchronous IO began. Report observed side effects even when the caller cancels.

Do not convert corrupt/unreadable data into an empty new draft or delete it on load.
A known pre-rename refusal need not have changed the original, but after rename a
failed parent sync/read-back can leave it at the retired name. P12 can rename back
a mismatched moved file without replacement; `restored`, occupied original and
failed restore are different results. Recovery preserves evidence, not necessarily
the requested pathname, durability, prior state or authority.

The archive receipt is validated evidence, not a perpetual archive pathname/version
pin. P14a's retained observation can describe archive A even if B replaces the path
later. Whole-operation archive pinning remains absent; do not promote that receipt
into an ownership token. A retired member takes precedence in launch classification
even when another original exists; `.retired` does not prove that no old owner wrote it.
Do not delete that original on the assumption that it is stale rather than new user data.

## Bounded characterization and evidence status

Session evidence is kept outside the repository as `files/p14b-contract-*`.
The recipe selects real `PendingStudioPatchStore`, `AssistantCoordinator`, advisor,
encoded `StudioPatchDraft` and canonical disk archive/retirement/observation.
Only a forwarding read-result gate controls scheduling. No AppModel, application,
preview, production defaults, provider/cloud/hardware or native MIDI execution.
Both store initializer parameters are injected; specifying only `fileURL` still
evaluates the default `directory` argument. Canonical audit and isolation flags apply.

Executed under an atomically acquired owned reservation after AU8b released it:
isolated SwiftPM Debug, nice 15, one job, pinned Xcode/mise, owned TMPDIR/caches,
three serialized diagnostics with canonical `.productionAccessAudit`. No production
access factory/API violation was reported. These prove current deficits, not exclusion:

| Probe | Observed result |
| --- | --- |
| Two owners / retirement | B overwrote A; old A revalidation overwrote B. Actual encoded A was archived and retired successfully. Old B then revalidated and recreated the original with B; retired/archive A bytes and both in-memory drafts survived. P14a observation still classified `.retired`. |
| Late load | Real read → gate signal → canonical archive/retire → release → join. The old payload published after retirement while the original remained absent. The gate forwards real results; it proves an interleaving, not production exclusion. |
| Storage outcomes | Missing, corrupt and directory reads all returned nil. Save over an owned directory returned Void and left its marker unchanged. Delete of that directory returned Void and recursively removed it: not a delete failure. With a regular file blocking the parent path, save/delete returned Void and preserved the blocker; an independent underlying removal threw `NSCocoaErrorDomain:512`. |

Actual store encoding (1,771 bytes in the recorded run) was accepted unchanged;
no minimal fixture JSON or fabricated authority was substituted. This is one
constructible model, not universal encoding compatibility. No encoding-failure probe.
Cancellation restoration, queued-writer rejection, multiwindow/startup ordering,
cross-process ownership and restart behavior remain source-derived risks here.

Accepted P12 evidence is reused, not rerun: `ProjectMigrationTests+RetireCrash.swift`
(`retireFaultsAreRefusedAndConverge`) distinguishes rename failure from post-rename
sync failure; `ProjectMigrationTests+RetireRace.swift` covers mismatch recovery,
occupied original, failed restore and failed read-back. The accepted P12 handoff
records passing Debug/Release migration validation; that matrix was not executed
by this slice. This does not claim whole-operation pinning or production exclusion.

## Future implementation order and acceptance

1. Independently review this policy, producer coverage and controlled evidence.
   Resolve successor/loader and stopped-state UX obligations; map and budget the
   implementation only after this contract is accepted.
2. Add truthful persistence outcomes and shared lifetime admission/revocation,
   with all construction/bypass surfaces accounted for and failing-before-fix tests.
   Keep runtime migration disabled during these changes.
3. Enforce publication/acceptance freshness at every async boundary, including
   cancellation restoration and old queued operations. Test multiple real owners,
   failure/cancellation cleanup and join behavior, not just a single actor.
4. Implement and qualify supported authoritative handoff or the explicitly designed
   stopped/read-only outcome, including ambiguous retirement and restart handling.
5. Only then integrate explicit migration admission ahead of legacy loading and
   intent/window producers, and validate actual startup/document lifecycle behavior.

Review must not mistake diagnostic unsafe observations for desired regression tests.
No permanent tests asserting those observations are added by P14b1. #122 remains
open for writer exclusion, authoritative loading, failure handoff, bookmarks and
document lifecycle; #48 is not completed by this prerequisite.

## P14b3 / #785 — nonrecursive removal source, qualification pending

Part of #785 and #122; #122/#48 remain open. Historical observations remain above.
Nil-save now uses one `Darwin.unlinkat(AT_FDCWD, path, 0)` with closure-scoped
filesystem representation and immediate failure-errno capture. Non-file URLs and
nil representations return bounded `.other` without a syscall. If Foundation decodes
an embedded NUL into `path`, the guard likewise returns `.other` without a syscall.
On the coordinator-probed Swift 6.4.2 / macOS 27.2.1, `%00` stays literal in both
`path` and the filesystem representation: `unlinkat` targets the literal name
(ENOENT means already absent), never the prefix. Tests select their expectation
from observed decoding; this is not a universal Foundation behavior claim. The
decoded-NUL guard is therefore defense in depth that this platform cannot reach.
Zero means delete completed, ENOENT means already absent; other errors retain the
existing bounded POSIX classification. EPERM is not a directory-specific result.
There is no recursive fallback, retry, type preflight or parent pinning.

Source coverage is added for populated then empty owned directories, final symlinks
to files/directories/missing targets, hard links, malformed URL prefixes and a real
failed discard held after IO while a different real draft commits. Link absence
uses owned-parent enumeration, not follow-link existence alone. Forwarding gates,
coordinator and load/write behavior are unchanged. Initial Debug compiled but failed
the former exact-decoded-NUL fixture assertion; the platform-aware correction was
independently source-reviewed, then rerun in an isolated SwiftPM mirror: clean Debug
and Release passed (19 tests / 23 cases) and four mutation controls failed at their
intended assertions.

The promise is application-level nonrecursive one-name removal, not universal
directory refusal. XNU `xnu-12377.1.9` research is not shipping-OS qualification;
directory-hardlink and compound-filesystem exceptions preclude that guarantee.
Initial Debug observed local directory preservation; parent symlinks, name/parent
races, trailing slashes and arbitrary filesystems remain unqualified. No durability,
writer exclusion, authority, migration activation, failure UI, post-acceptance
rollback or native/provider qualification is added.

## P14b4 / #790 — superseded pending-draft loads do not publish

Part of #122 and #48; both remain open. `AssistantCoordinator.load()` still completes
its own storage attempt with the actual read outcome, then publishes only if that
attempt is still the same coordinator's `latestStorageAttempt` (object identity).
A superseded load leaves the pending draft, settled draft, routing submission and
navigation untouched. Store, outcomes, disk and UI code are unchanged; the observable
pending draft deliberately no longer shows a superseded load. If a newer load fails,
neither publishes: a read older than a failed newer read is intentionally not trusted.

Real-store tests with the existing forwarding gates cover a late load versus a newer
commit, a completed discard (no in-memory resurrection), a newer load, and a later
cancelled commit restoring the newer settled draft retained across the stale load.

The check is per-coordinator identity only; P14b5 below closes the window for a load
that *starts* while a mutation is in flight. Other coordinators, store instances and
processes are not excluded, and no admission/revocation, durability, authority, migration
activation, failure UI, AppModel or provider/card freshness is claimed.

## P14b5 / #797 — loads started during a pending-draft mutation do not publish

Part of #122 and #48; both remain open. `AssistantCoordinator` counts its own
`persistPendingDraft()` calls in flight: incremented on entry, decremented in a `defer`,
so overlapping mutations and failed writes each release only their own count. `load()`
records whether the count was zero before awaiting the store, still completes its own
attempt with the actual read outcome, and publishes only if it started quiescent and is
still the latest attempt (the P14b4 identity check). A skipped load leaves the pending
and settled drafts, routing submission and navigation untouched. Store, outcomes and UI
code are unchanged.

Real-store tests with the existing forwarding gates cover a load during a held commit
(the commit is kept and no catch-up re-saves the older read), during a held discard (no
resurrection; the file stays deleted), during a commit held after its save and then
cancelled (rollback still restores), a mutation that finishes while the load is still
reading (quiescence is decided at load start), and an overlapping `encodingFailed` write.

Memory can be newer than disk. When a skipped load overlaps a write that fails, the
pending draft keeps the unsaved value while disk keeps the older one; the skipped read
is recorded but not published and nothing re-reads automatically. A later load that
starts quiescent publishes disk again, replacing that unsaved value; in the app the only
such load is the next launch's `loadStores()` (`reloadStores()` does not re-read the
pending draft), so until relaunch memory stays ahead of disk and the unsaved value is
lost at the next launch. A save that never completes keeps the count above zero and
suppresses load publication for that coordinator. The count is per coordinator: other coordinators, store instances and processes are not excluded, and no
admission/revocation, durability, authority, migration activation, failure UI, AppModel,
Siri, startup wiring or provider/card freshness is claimed.
