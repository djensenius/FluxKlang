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
