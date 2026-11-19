# Host authority sources: epochs, permission, windows and the render lease

| Field | Value |
|---|---|
| Issue | Part of #62 (slice AU8 design); roadmap #48. #62 remains open |
| Status | AU8 design archive plus AU7c1 planned lifecycle composition, the AU7c2 owner close fence, the AU7c3 detach-time fence, the AU7c4 closed-root list, the AU8c-1 open-window set with root `open`, the AU8c-2 gated real-session Studio Apply and the AU8d S1 verified re-read (§12); pure Debug/Release checked, hosted compilation pending |
| Source baseline | Historical citations: `41f69372`; AU7c1 implementation base: `2165503ab27043999cda062c10ba9132a2085262` |
| Scope | Authority input sources, original AU8a plan, and bounded planned replacement/session/detach composition |

## 1. Purpose and status

The gated Studio apply exists in source but had no production inputs at the design baseline; since AU8c-2 (§12)
real-session Studio Apply uses it. `WingApplyGrantMinter` takes a
`HostAuthority`, a `ProjectID`, a `WindowID`, a ticket budget and a `Provider` that returns a
`WingApplyAdmission` (intent and admission context) for every mint (`Shared/WING/WingApplyGrantMinter.swift:12-15`,
`:20-45`). `HostCommandGate.admitDirect` then requires the admission's host epoch and permission to equal the
book's live state and the window's role to be `.renders` (`Shared/Host/Authority/HostCommandGate.swift:100-115`).

Sections 2–11 retain the original design and historical `path:line` citations at `41f69372`, not current
execution claims. Names marked *proposed* describe that baseline. AU8a/AU8b subsequently supplied the canonical
owner and explicit permission gestures. Section 12 records the current AU7c1 source composition and supersedes
the historical AU7c window-to-Apply scope. AU7c1 verification is pure Debug/Release and strict lint only (§12),
not application, native UI or WING execution.

## 2. What existed at the design baseline

This section records the code at the design baseline (`41f69372`). Each statement below, present tense included,
describes that commit, not the current code. Section 12 records the current composition.

- **No production owner.** No file under `Shared/`, `FluxKlang/` or `FluxKlangMac/` constructs `HostAuthority(`,
  `HostLiveState(`, `DeviceCapabilityDocument(`, `GenerationLedger(` or `WingApplyGrantMinter(`. `HostEpoch(` is
  built only from peer wire data (`Shared/Peer/Sync/PeerSyncSnapshot.swift:35`,
  `Shared/Peer/Sync/Message/PeerControlMessage+Command.swift:68`). The lease registry exists only inside the book
  (`Shared/Host/Authority/HostAuthorityBook.swift:21`).
- **Live state.** `HostLiveState` is a host epoch, an optional permission fingerprint and a capability document
  (`Shared/Host/Authority/HostAuthorityTypes.swift:11-16`). The only setter is `HostAuthority.updateLive`, a plain
  replacement (`Shared/Host/Authority/HostAuthority.swift:136-138`).
- **Permission.** `PermissionFingerprint` documents "Callers derive it from the permission owner (#57)"
  (`Shared/Contracts/Commands/CommandContracts.swift:32-37`). The only production maker is the peer trust record
  (`Shared/Peer/Trust/PeerTrustStore.swift:57-71`), plus wire decoding
  (`Shared/Peer/Sync/Message/PeerControlMessage+Decode.swift:208`). Peer roles cannot hold a route scope:
  `remoteController` permits only `.live` on `.parameter` and `observer` permits nothing
  (`Shared/Peer/Trust/PeerGrants.swift:15-31`). There is no local host-user permission owner.
- **No audio engine.** No production source uses `AVAudioEngine`, `AudioUnit` or `AUAudioUnit` (grep at the
  baseline), so nothing renders and nothing can hold an engine lease for audio today.
- **Windows.** Every scene's `AppRootView` mints its own `WindowID` (`Shared/Views/App/AppRootView.swift:16`). All
  scenes share `AppModel.shared` (`FluxKlang/FluxKlangApp.swift:12-15`, `FluxKlangMac/FluxKlangMacApp.swift:14-17`,
  `Shared/Views/App/AppModel+StoreLifecycle.swift:24-38`). The window reaches the Workspace destination but not
  Studio: `StudioView()` is built with no window (`Shared/Views/App/AppRootView.swift:275`; the scout cited `:277`,
  which is the `PerformanceWorkspaceView` call that does get one).
- **Project identity.** The only production `ProjectID` is minted per New Project by
  `PerformanceProjectSession` (`Shared/Views/Workspace/Project/PerformanceProjectSession.swift:67`). Studio has none.
- **Apply path.** `StudioView.applyStudioPatch` (`Shared/Views/Studio/StudioView.swift:400-406`) calls
  `AppModel.applyStudio()` (`Shared/Views/App/AppModel+StudioApply.swift:4`), which calls the ungated
  `wing.applyAndVerify(_:safetySettings:)` (`:17`; `Shared/WING/WingController+VerifiedApply.swift:6`). That paces
  through `apply` (`:32-40`), then `set` and `transport.send` (`Shared/WING/WingController.swift:341`, `:358`,
  `:361`). The gated overload takes a WING `session: UUID` and a minter and has no app callers
  (`Shared/WING/WingController+GatedVerifiedApply.swift:38-50`). Its per-entry send refuses Demo Mode, a
  disconnected controller and a changed session (`Shared/WING/WingController.swift:399-402`).
- **Connection entry points.** Every connect, disconnect and demo change goes through `AppModel`:
  `enterDemoMode()` (`Shared/Views/App/AppModel.swift:419-425`), `connect(host:port:)` (`:428-438`),
  `disconnect()` (`:441-445`) and `showAcceptanceConnectionFailure()` (`:447-451`). Each swaps `wing` for a new
  controller. Connects without a window: the startup reconnect (`:188-189`) and the Connect intent
  (`Shared/Intents/FluxKlangIntents.swift:42`). `WingController.connection` on a live controller changes only in
  `connect` and `disconnect` (`Shared/WING/WingController.swift:104-144`); `preview()` and `acceptanceFailure` set
  it at construction (`:85-97`). A session is a fresh `UUID` per connect attempt (`:108-109`).

## 3. Sources

| Value | Owner | Created when | Invalidated when | Cited code |
|---|---|---|---|---|
| `HostID` | Process-wide owner (*proposed* `HostAuthorityOwner`) | Once, in the owner's init | Never during the process; a new launch is a new host | `DeviceCapability.swift:35-36` |
| `HostEpoch` | Owner | Once, in init: the new `HostID` with `Generation.initial` | Never during the process (decision 1) | `CommandContracts.swift:19-22`, `Revisions.swift:98` |
| `PermissionFingerprint?` (live) | Owner, minted from the AU8b grant owner's role with a never-reused grant revision (decision 2) | `nil` at launch; set by an explicit Host-role grant gesture | Revoke clears it to `nil`; every grant mints new bytes, so any change, including revoke then regrant, stales tickets (`staleLive`) | `HostAuthorityTypes.swift:13-14`, `HostCommandGate.swift:109-111`, `:132-134` |
| `DeviceCapabilityDocument` | Owner | In init, for the same `host` and `hostEpoch` generation; minimal (decision 9) | Not during the process in AU8 | `DeviceCapability.swift:288-292` |
| `GenerationLedger` | `HostAuthority`, seeded by the owner | In init, primary clock per decision 9; the actor declares the context key | Context bumps on every lease grant, release and loss | `GenerationLedger.swift:70`, `:83`; `HostAuthorityBook.swift:53-58`, `:202-214`, `:218-228` |
| `HostAuthority` | Owner | Once, in init, with `sendScope: WingDirectSendScope()` | Never replaced during the process | `HostAuthority.swift:48-54`; `WingDirectSendScope.swift:56-59`, `:76` |
| Studio `ProjectID` | Owner | Once per owner lifetime; opened in the authority at init | Never during the process (decision 4) | `HostAuthority.swift:76-80` |
| Engine lease token | `HostAuthority` (registry) | `acquire` by the applying window, at apply time, from a user gesture, while a real WING session is connected (decision 8) | `release` on a planned loss (Disconnect, controller swap, Demo Mode); `leaseLost` on an unplanned drop (decision 7) | `HostAuthority.swift:83-90`, `:217-219`; `HostAuthorityBook.swift:139-150`; `HostAuthorityBook+LeaseLoss.swift:52-63` |
| WING `session` | `WingController` | Each `connect` attempt | The next `connect`; the controller swap in `AppModel`; `disconnect` or a failed connect clears it (`WingController.swift:139`, `:129`, `:441`) | `WingController.swift:37`, `:108-109` |
| `WindowID` (rendering) | Scene (`AppRootView`), threaded by AU7c | Scene init; renders once it acquires at apply time | Scene disappears: `detach`, which drops its tickets | `AppRootView.swift:16`, `:37-39`; `HostAuthorityBook.swift:179-190` |
| `WingApplyTicketBudget` | Each apply | Per apply, sized from the plan | End of the apply | `WingApplyTicketBudget.swift:18`, `:36` |
| `WingApplyAdmission` | Owner's provider, read per mint | Each mint, from the owner's live state and the applying window | Every mint re-reads; nothing is cached | `WingApplyGrantMinter.swift:21`, `:32` |

`DeviceCapability.swift`, `CommandContracts.swift`, `GenerationLedger.swift` and `Revisions.swift` are under
`Shared/Contracts/`. `WingDirectSendScope.swift`, `WingApplyTicketBudget.swift` and `WingApplyGrantMinter.swift`
are under `Shared/WING/`. The other files are under `Shared/Host/Authority/` or named in section 2.

The authority must be built with `WingDirectSendScope`: its default `DenyAllDirectSendScope` admits no target
(`HostAuthority.swift:47-50`), and only `WingDirectSendScope` admits the `.route(applyRoute)` addresses.

## 4. Where the owner lives

`scripts/test-audit-coverage/README.md:747-753` records that the production closure of the fourteen fixture suites
takes in value types from `Shared/Host/Authority`: the files that closure takes in import only Foundation, have only
computed `static var` members and no classes besides three stateless `fileprivate final class Identity` tokens.
The directory as a whole has more (`final class DirectWriteAuthorization` at `DirectWriteAuthorization.swift:45`,
`private final class Identity` at `HostAuthorityTypes.swift:250`). A stateful, process-wide owner therefore must
not live in `Shared/Host/Authority`. It goes in a new directory, `Shared/Host/Runtime/` (*proposed*), beside the
existing `Shared/Host/Ownership/`. Nothing in `Shared/Host/Authority` may reference it, so the closure does not
grow. `Shared` is a folder source in `project.yml` (`:32`, `:84`), but a new file still needs the coordinator's
project regeneration.

The single instance follows the pattern `AppModel` already uses: a lazily initialized `private static let`
construction read through a computed `static var shared` (`Shared/Views/App/AppModel+StoreLifecycle.swift:24-38`).
The initializer stays internal so tests can build isolated owners with an injected `HostID`; only `shared` is used
in production. AU8b may lazily access it for permission gestures only; AU7c owns lifecycle, window and session
composition. Production permission producers use the process-wide `HostUserPermissionOwner` facade. Its report
is historical outcome/last-checked presence only, never authority; canonical APIs remain callable internally.

## 5. Lifecycle sequences

These sequences describe the original full AU8a–AU8c design, not the implemented subset; see §12.

**Launch.** First access to `HostAuthorityOwner.shared` mints a `HostID`, the epoch `(host, .initial)`, a capability
document and ledger for that epoch, the Studio `ProjectID`, and the `HostAuthority` with `permission: nil`. It
opens the Studio project with an empty running graph. No lease is held, so every window observes `.stopped`.

**Grant (AU8b).** A user gesture in a host window grants the Host role. The grant owner passes the role. The owner
raises its grant revision, mints the fingerprint (decision 2) and calls `updateLive` with the same epoch and the new
permission. Revoking calls `updateLive` with `nil` and leaves the revision as it is. Because no two grants share a
fingerprint, each change stales every outstanding ticket (`HostCommandGate.swift:132-134`), including a ticket left
over from before a revoke and regrant. Until AU8b exists the permission stays `nil` and every gated write is refused.

**Connect.** `AppModel.connect` establishes the WING session and nothing else in the authority: the owner records the
controller's `sessionID` as the live session. It never acquires the render lease (decision 8). This holds for the
connect from a window, the startup reconnect (`AppModel.swift:188-189`) and the Connect intent
(`Shared/Intents/FluxKlangIntents.swift:42`).

**Apply.** The user's apply gesture in window `w` comes with `w`'s `WindowID` (threaded by AU7c). If no lease is
held and a real session is connected, the owner calls `acquire(project: studio, window: w)`
(`HostAuthority.swift:83-85`) and the grant bumps the context. If `w` already renders, it proceeds. If the Studio
lease is held with no window attached, the owner calls `attach(w, project: studio)` (`HostAuthority.swift:98-100`).
If another window renders, `w` is refused (decision 6). The rendering window then builds a `WingApplyGrantMinter`
with the owner's authority, the Studio project, its own `WindowID`, a budget and the owner's provider, and calls the
gated `applyAndVerify(_:safetySettings:session:minting:)` with the recorded session. Each mint re-reads the
provider. A `nil` provider result is `.staleLive` (`WingApplyGrantMinter.swift:32`).

**Planned loss: Disconnect, controller swap.** Before `AppModel` stops or swaps the controller
(`AppModel.swift:428-451`), the owner calls `release(project: studio)` (`HostAuthority.swift:87-90`). The book
removes the lease with one context bump and queues nothing (`HostAuthorityBook.swift:139-150`, `:218-228`); it
refuses only while a delivered commit is unreported (`:146`), which the WING path never creates; with no lease held
it returns `.lease(.notHeld)` (`HostAuthorityBook.swift:147`), which the owner treats as already released.
Outstanding tickets then redeem as `.staleLease` (`HostCommandGate.swift:135`).

**Unplanned drop.** On a transport failure the owner calls `leaseLost(token)`. The book moves the holder through
table T1 into `.recovering`, bumps the context and owes a mute (`HostAuthorityBook+LeaseLoss.swift:42-63`,
`:78-99`). Tickets redeem as `.recovering`, which is checked before the lease (`HostCommandGate.swift:130-135`), and
new admissions are `.gate(.unavailable(.recovering))` (`FluxKlangTests/HostAuthorityTests+DirectWrite.swift:334-340`).

**Reconnect after a planned loss.** A new connect records a new session. The next apply gesture acquires a new
token and context; outputs were never muted, so no recovery starts (`HostAuthorityBook+Restore.swift:222-225`) and
writes are admitted again. The existing test shows release then acquire returning to `.running` with the old ticket
`.staleLease` (`HostAuthorityTests+DirectWrite.swift:208-217`).

**Reconnect after an unplanned drop.** The next acquire finds outputs muted, re-enters recovery and queues one
restore (`HostAuthorityBook+Restore.swift:222-225`, `:174-177`). For the Studio project's empty running graph the
restore target is `.empty` (`:374-383`). The owner drains its own lane with `nextEngineCommand()`
(`HostAuthority.swift:254-258`): the fail-closed `.setOutputsMuted(true)` and the `.restore` command
(`EngineCommandQueue.swift:21`, `:28`). It calls `restoreCompleted` (`HostAuthority.swift:239-245`) with that
command's attempt, revision, target and token only after the new WING session is connected and its state re-read
succeeded (decision 7), then drains the `.setOutputsMuted(false)` that follows. This is the order the existing test
uses: an acknowledgement before delivery is `.staleRestore`, delivery is mute then restore, and the unmute follows
the acknowledgement (`FluxKlangTests/HostAuthorityTests+ActorUnmute.swift:41-61`). Until then every gated write is
`.gate(.unavailable(.recovering))`.

**Demo enter and exit.** Entering Demo Mode is a planned loss: `release`, and nothing is acquired while the
controller is a demo one. Studio apply uses the ungated, demo-only path (decision 5). Leaving Demo Mode is a connect.

**Window close.** `AppRootView` already runs window-close work on disappear (`AppRootView.swift:37-39`). For the
rendering window the owner calls `detach`, which drops that window's tickets (`HostAuthorityBook.swift:187-188`).
Removing the last window keeps the lease (`Shared/Host/Authority/EngineLease.swift:149-157`); with no attached
window no scene renders, so gated writes are refused until a window attaches through an apply gesture.

**Quit.** Nothing is persisted. The next launch has a new `HostID` and epoch, so no ticket, fingerprint or epoch from
a previous process can match.

## 6. Decisions

The user delegated these choices ("make your best assumption"); the coordinator made them. They are fixed for AU8.

1. **Host identity.** One per-launch `HostID` with epoch generation `.initial`, minted exactly once when the single
   process-wide owner is created. Persisting a host identity (for example in the Keychain) is a later, separate
   decision.
2. **Local permission.** The live permission is `nil` at launch. Only an explicit Host-role grant made by a user
   gesture sets it: "The role is chosen explicitly when a project is opened or a peer is paired"
   (`docs/transformation/workspace-ux/host-remote-roles.md:16-17`), and admission refuses a `nil` permission
   before any other running-set check (`CommandAdmission.swift:124-126`). Nothing is granted because a caller is
   local or in-process. Revoking clears it. Until the grant UI exists, gated writes refuse; that is why AU8a changes
   no caller. Each grant gets a fingerprint that is never reused in the process. Tickets and redemption compare
   fingerprints by value (`HostCommandGate.swift:132-134`), and `updateLive` drops no ticket
   (`HostAuthority.swift:136-138`). So if a regrant of the same role produced the same bytes, grant → revoke →
   grant would make an untouched pre-revoke ticket redeemable again whenever its lease and context are unchanged.
   The owner therefore mints the live fingerprint itself, the way the peer fingerprint includes its record
   revision (`PeerTrustStore.swift:57-71`): a digest of the granted role plus a process-lifetime `UInt64` grant
   revision. The revision starts at 1, rises on every grant, including a regrant of the same role, is never reset by
   a revoke, and refuses a grant rather than wrap. The grant owner (AU8b) passes the role, not a fingerprint.
3. **Render lease without an audio engine.** The connected WING session is the leased output. The lease is
   acquired at apply time (decision 8) and ends on a planned loss with `release` or on an unplanned drop with
   `leaseLost` (decision 7). Each new lease has a new token and context, so old tickets go stale. (Amended by
   decisions 7 and 8; the first draft acquired on connect and raised `leaseLost` on every loss.)
4. **Studio `ProjectID`.** One app-scoped ID per owner lifetime, until Studio has a document identity.
   `PerformanceProjectSession`'s per-New-Project ID (`PerformanceProjectSession.swift:67`) is a separate workspace
   identity and is not reused for Studio.
5. **Demo Mode.** The simulator path stays ungated and is documented as demo-only (no hardware). It is never a bypass
   for a real session: the gated send already refuses Demo Mode (`WingController.swift:401`), and AU8c must keep
   the ungated path reachable only while `wing.isDemo` (`:50`).
6. **Windows.** The window that applies must be the one holding `.renders`; every other scene is edit and prepare
   only. The `WindowID` is threaded from the scene into `StudioView` and `applyStudio` by AU7c (coordinator-owned
   wiring).
7. **Planned and unplanned loss (G1).** A user Disconnect, a controller swap and entering Demo Mode
   (`AppModel.swift:419-451`) are planned: the owner calls `release(project:)` (`HostAuthority.swift:87-90`;
   `HostAuthorityBook.swift:139-150`), the existing voluntary API, so no mute is owed and no restore is queued. AU8a
   adds no new release API. An unplanned drop (transport failure) raises `leaseLost`; the project goes
   `.recovering`. The owner itself drains its queued restore through `nextEngineCommand()` and calls
   `restoreCompleted` only after the new WING session is connected and its state re-read succeeded. WING has no
   engine graph, so restore means a verified reconnect. Until then gated writes refuse with
   `.gate(.unavailable(.recovering))`, which is the truthful outcome.
8. **Windowless connect (G2).** Connecting (including the startup reconnect, `AppModel.swift:188-189`, and the
   Connect intent, `Shared/Intents/FluxKlangIntents.swift:42`) only establishes the WING session and the live
   context; it never acquires the render lease. The lease is acquired by the window that applies, at apply time,
   from a user gesture, with the `WindowID` AU7c threads. A windowless caller can never hold `.renders`, so the
   intent and startup paths cannot write.
9. **Capability document and ledger clock (G3). Decided default, AU8a confirms against code.** No production code
   builds a WING capability or route document: the device contract has only a WING USB channel layout
   (`DeviceCapability.swift:109-110`) and a `.consoleCompatibility` device kind (`:163`), and the apply route scope
   lives in `WingDirectSendScope` (`WingDirectSendScope.swift:59`, `:76`), not in any capability document. So AU8a
   builds the minimal valid document for its host and epoch that covers exactly the WING apply route scope and
   nothing more. Because that scope is not expressed in the document, minimal means no devices and no routes unless
   the document's validation requires otherwise (not checked here); its scout confirms that, and that no richer
   source exists. Direct-write admission does not read
   `capabilities` (`HostCommandGate.swift:109`). The ledger's `primaryClock` is a `ClockID` label plus a declared
   nominal rate, not a time source (`GenerationLedger.swift:81-83`). No production ledger exists; the tests use
   labels such as `smp.main` at 48,000 (`FluxKlangTests/Fixtures/Authority/HostAuthorityBench.swift:72-73`). The
   default is a `ClockID` naming the host monotonic clock (`ContinuousClock`, mach continuous time); AU8a's scout
   confirms the label and rate.
10. **Refusal names (G4).** A second scene's window of the Studio project sees
    `.gate(.unavailable(.heldByOther(studio)))`, **not** `windowCannotWrite`: an off-lease window of the holder's
    project observes `.heldByOther`
    (`Shared/Host/Authority/ActivationRecovery.swift:82-90`, `:50-55`; `HostAuthorityTests+DirectWrite.swift:113-115`).
    `windowCannotWrite(.stopped)` is the refusal only when no lease is held. A provider admission with
    `permission: nil` is `.gate(.refused(.rejected(.permissionDenied)))`
    (`Shared/Contracts/Commands/CommandAdmission.swift:124-126`); an admission carrying a fingerprint while the live
    permission is `nil` is `.staleLive` (`HostCommandGate.swift:109-111`). These names assume a granted permission
    that matches the live one; while the live permission is `nil` (until AU8b), every running-set admission is first
    refused `.gate(.refused(.rejected(.permissionDenied)))` (`HostCommandGate.swift:25`).

## 7. Notes for AU8a and AU7c

- **No unplanned-drop signal exists today.** `WingController.connection` on a live controller changes only in
  `connect` and `disconnect` (`Shared/WING/WingController.swift:104-144`), and the keep-alive ignores send errors
  (`:458-460`). AU8a exposes and tests the owner's drop hook; detecting a transport failure in production is a
  follow-up outside AU8.
- **"State re-read succeeded" had no signal at this baseline.** The connect starts a bulk refresh task (`:462-467`)
  that reports no completion. AU8a takes the verified reconnect as an explicit input to the owner. AU8d S1 (§12) now
  supplies it: after every published live connect, `WingController.verifyReread(session:)` must see a fresh reply
  from every `WingLiveObservations.addresses` entry on that session within 2 s, and only then does the lifecycle
  call `verifiedReconnect(session:)`. Drop detection (S2) is still open.
- **Mute commands reach no hardware.** The lane's `.setOutputsMuted` commands model engine outputs, which do not exist
  (section 2). The owner consumes them so the lane can progress and sends nothing to the WING for them.
- **A pending recovery survives a planned release.** If an unplanned drop's restore is never completed, outputs stay
  muted, and the next acquire re-enters recovery even after a planned release
  (`HostAuthorityBook+Restore.swift:222-225`).
- **Handing rendering to another window** is not designed here. Under decision 6 that window is refused until the
  rendering window detaches or the lease is released.

## 8. Slices

| Slice | Owner | Content | Limits |
|---|---|---|---|
| AU8a | Worker | `Shared/Host/Runtime/HostAuthorityOwner.swift` (*proposed*): the owner of section 3, its `shared` instance, the session, apply-time acquire, attach, release, drop, verified-reconnect restore, demo and window hooks, the role grant and revoke input that only AU8b calls, which mints the live fingerprint with the grant revision (decision 2, *proposed*), and the admission provider. No caller changes | Owner at most 150 lines; `FluxKlangTests/HostAuthorityTests+Owner.swift` at most 250 lines, registered by the coordinator |
| AU8b | Worker | The host-user permission grant owner and a minimal grant and revoke gesture; the only path to a non-`nil` live permission | No peer path, no automatic grant |
| AU7c1 | Worker; coordinator registers | Shared owner injection, serialized planned replacements, exact session publication and existing root-ID detach (§12) | No StudioView/applyStudio/window-to-Apply wiring; no verified reconnect or activation |
| AU7c2 | Worker | Owner-only close fence (§12): `windowClosed` fences in-flight applies for its window before waiting; `beginApply` refuses `.windowClosed` | No sequencer, root-lifetime or AppRootView change; no closed-window history |
| AU7c3 | Worker | Detach-time fence (§12): the owner's lock-free `fenceApplies(for:)`, which `windowClosed` still calls first; `HostWingLifecycle.detach` sends it when submitted, while the detach itself keeps its FIFO turn; `Completion.fenced()` joins it | No queue-order change or early detach; no root lifetime, `windowOpened` or closed-window history; no AppRootView, AppModel or WingController change |
| AU7c4 | Worker | Closed root (§12): the owner's `closedWindows` set, filled by `fenceApplies`/`windowClosed` and cleared by a lock-free `windowOpened`; `beginApply` and `staleness` refuse a closed root `.windowClosed` (`.noSession` first); `HostWingLifecycle.open(_:)` reopens on its FIFO turn unless the owner has fenced a later detach generation, and a detach's turn awaits its early fence | No production `windowOpened`/`open` caller (AU8c); never-opened windows are not refused; no AppRootView, AppModel or WingController change |
| AU8d | Worker (S1 #878; S2 later) | S1: the verified-reconnect signal (§12). After every published live connect, the lifecycle runs the WING state re-read off its FIFO turn and feeds a successful, current re-read to the owner's verified-reconnect input. S2: the drop producer | S1 ships the signal first, which satisfies D2 for S2: production still calls no `dropped()`. S2 (drop detection and the first `dropped()` caller) waits for the #62 decisions |
| AU8c-1 | Worker | Root `open` and the open-window set (§12): `AppRootView` calls `wingLifecycle.open` on every appear; the owner's strict `openWindows` replaces `closedWindows`, so `beginApply`/`staleness` refuse any window not open `.windowClosed` (`.noSession` first), including one never opened; a detach's close releases its window's generation entry unless a later detach's fence raised it; the sequencer's per-window `detachSubmissions` becomes one monotonic counter | Prerequisites AU8a, AU8b and AU7c are merged; AU8d is not an AU8c prerequisite, so the earlier AU8d → AU8c order is relaxed for this slice only. Ships `open` before any production `beginApply` caller, which keeps the AU8c invariant. No `beginApply` caller, `applyStudio`, `StudioView`, minter or `WingController` change; no automatic grant |
| AU8c-2 | Worker | `applyStudio` calls the gated overload for real sessions; the ungated `applyAndVerify(_:safetySettings:)` stays only for Demo Mode; `StudioView` threads the root window; production minter (§12) | Needs AU8c-1 (root `open` already wired); must not ship without it. The AU8d → AU8c relaxation extends to this slice: production calls no `dropped()`, so `.recovering` is unreachable and a drop cannot block Apply. Whichever slice adds the first production `dropped()` caller must ship AU8d with it |

## 9. AU8a test plan

Each test names the mutation that must make it fail. Mutations are applied to production code in a throwaway mirror
only and restored. Except the first row, each test first grants the Host role through that input.

| Test | Expectation | Mutation that must fail it |
|---|---|---|
| Permission is `nil` at launch | A connected owner with a rendering window and no grant: a provider admission without a fingerprint is `.gate(.refused(.rejected(.permissionDenied)))`; one carrying any well-formed fingerprint that the intent also carries is `.staleLive` | Owner init sets a non-`nil` live permission |
| Connect acquires nothing | After a connect, with or without a window, no lease is held; an admission from any window is `.windowCannotWrite(.stopped)` until an apply gesture acquires | Owner acquires the lease on connect |
| Only the rendering window writes | Two scenes on the Studio project; the window that applied first renders, the other is `.gate(.unavailable(.heldByOther(studio)))`, never `windowCannotWrite` | Owner attaches every applying scene to the lease |
| Planned disconnect, then reconnect | Ticket under session 1; Disconnect releases; the old ticket is `.staleLease`; connect session 2; the next apply gesture re-acquires and a new ticket is admitted, with no recovery | Owner raises `leaseLost` instead of `release` on Disconnect (the project stays `.recovering`), or skips the release (the next acquire is `.lease(.alreadyHeld)`, `EngineLease.swift:129-134`) |
| Unplanned drop, then verified reconnect | After the drop hook, admissions are `.gate(.unavailable(.recovering))`; after a new session, apply-time acquire and the verified-reconnect input, the owner completes its restore and a new ticket is admitted | Owner never drains its lane or never calls `restoreCompleted` (writes stay refused) |
| No restore without a verified reconnect | With the new session connected but no verified re-read, the project stays `.recovering` and admissions are refused | Owner calls `restoreCompleted` as soon as it acquires, without the verified reconnect |
| Demo Mode holds no lease | After entering Demo Mode no lease is held, earlier tickets are `.staleLease`, and nothing is queued | Owner keeps the lease, or raises `leaseLost`, on entering Demo Mode |
| Revoke then regrant stales old tickets | Grant the Host role and admit ticket T, leaving it unredeemed; revoke; grant the same role again with the lease and context unchanged; T redeems `.staleLive`, and the two grants' fingerprints differ | Owner mints the fingerprint without the grant revision, or resets the revision on revoke |
| The epoch is minted once | `live.hostEpoch` is unchanged across connect, disconnect, drop, demo, grant and revoke | Owner mints a new epoch outside its init (for example on connect) |
| One owner per process | `HostAuthorityOwner.shared` returns the identical instance on every read, with the same `HostID` | `shared` becomes a computed property that builds a new owner |
| A new window attaches to an unattached lease | After the rendering window closes, the lease is held with no window; a new window's apply gesture attaches it and a ticket is admitted, with no `.lease(.alreadyHeld)` | Owner calls `acquire` instead of `attach` (refused `.lease(.alreadyHeld)`; the window stays `.heldByOther`) |
| Window close drops its tickets | `detach` of the rendering window makes its tickets `.notOutstanding`; the lease stays held | Owner releases the lease on window close, or does not detach |

Tests use `AuthorityBench` patterns from the existing `HostAuthorityTests+DirectWrite.swift` and touch no WING,
network or UI.

## 10. Risks

- **Double render.** Two windows attached to one lease could both apply. Decision 6 and the second test keep exactly
  one window attached; `windowLimit` alone (`EngineLease.swift:145`) does not prevent it.
- **Stale epochs.** Any second source of `HostEpoch` would let a stale admission match. The epoch test pins the one
  source; a persisted identity (decision 1 follow-up) must keep the same rule.
- **iOS multi-scene and suspension.** iPad scenes are separate `WindowID`s on one `AppModel`. iOS declares no
  background modes and the OSC link may lapse while suspended (`docs/transformation/permissions.md:186-197`). No
  production signal reports that lapse (section 7), so the lease stays held until the next planned loss; the gated
  send still refuses a disconnected controller or a changed session (`WingController.swift:401`).
- **Demo Mode.** The ungated path must stay demo-only. AU8c must prove a real session never reaches it.
- **Recovery after a drop.** Until the verified-reconnect input exists in production, a drop leaves gated writes
  refused. That is the truthful outcome (decision 7), but it blocks Studio apply until AU8d supplies the signal.

## 11. Non-goals

- No code, test, project or registration change in this document.
- No audio engine and no render lease for audio. The owner's lane draining is for the WING session only.
- No transport-failure detection and no WING re-read completion signal (section 7 follow-ups).
- No persisted host identity, peer host role or remote grant of route scope.
- No migration of the other direct WING write paths listed in `docs/transformation/baseline.md` (Dispatch gap).
- No change to `HostAuthority`, the book, the gate or the minter.

## 12. AU7c1 lifecycle composition, AU7c2 close fence, AU7c3 detach-time fence, AU7c4 closed root, AU8c-1 open roots, AU8c-2 gated Apply, AU8d S1 verified re-read

Part of #62 and roadmap #48; both remain open. Source implementation follows the approved #779 plan.
Approval was design/source feasibility only. The exact 71-input closure now compiles without missing dependencies.
Clean Debug/Release each pass 43 canonical tests (57 cases), including 17 lifecycle tests (26 cases); strict lint
passes all 19 changed Swift files. Canonical root receipts report zero access across all 14 audit operations.
Independent source/runtime review and hosted AppModel/SwiftUI/AppIntents compilation remain required.

### Actual ownership and callers

- `AppModel+StoreLifecycle.sharedConstruction` explicitly injects
  `HostWingLifecycle(owner: HostAuthorityOwner.shared)`. Ordinary AppModel initialization instead creates
  an owner-nil sequencer, including previews/tests; it does not implicitly construct production authority.
- `AppModel` keeps every controller assignment and its private setter. Its four replacement methods return
  typed outcomes. Routing/preset methods moved unchanged to `AppModel+Routing`.
- `HostWingLifecycle` owns ordering, not permission, a lease registry or an engine. `isBusy` and
  `lastReplacementOutcome` are observable presentation; the latter is historical, never an admission input.
- Root and menu-bar surfaces present the shared failure. Intents inspect their returned result, not a mutable
  later controller. Acceptance setup stops before dependent seeding on lifecycle failure.
- AppModel, MacCommands and MenuBarMixer agree that connecting OR connected offers Disconnect, independently
  of remembered host. Faders remain connected-only. Safety Disconnect is never busy-disabled: it queues and
  does not preempt earlier work. ConnectionView's connect/demo controls use the shared busy state.

### Replacement and detach order

Reservation precedes busy notifications. Replacements stay in their caller's structured task and capture the
old controller only on their FIFO turn. A cancelled queued replacement keeps its place but performs no teardown.
After teardown begins, canonical `disconnected` and captured-old stop both finish, even on cancellation/refusal.
Initial release refusal wins over concurrent cancellation and prevents construction, start and publication.

After assigning live/demo, AppModel checks cancellation before entering `connect`/`connectDemo`, returning
the candidate cleanup handle if cancelled. The final cancellation/current-identity check is the publication
commit boundary. Live success requires the exact current connected session UUID; natural failure retains its
detailed failed-controller presentation without publishing or remembering a host.

After canonical publication, identity is rechecked before remembering the host and awaiting the existing
temporary-move verification. Later cancellation alone does not undo committed success. Identity mismatch stops
the candidate and calls canonical `disconnected`; any cleanup refusal remains distinct from initial refusal:

- Initial: “The previous connection was stopped. No replacement was started because host release was refused.”
- Published cleanup refusal: “A replacement connection was published, then stopped after its identity changed.
  Host-session cleanup was refused.”

The FIFO reservation survives report and busy-reset Observation callbacks, including synchronous detach
submissions. `detach(existing WindowID)` submits synchronously and returns a retained, joinable completion.
The outer root uses its existing ID independently of workspace-close success. Detach keeps the lease, removes
the window/tickets, and does not erase the last replacement outcome.

### Proof boundary and remaining work

`LifecycleComposition` and `LifecycleCompositionRaces` under the canonical HostAuthorityTests root use real
isolated owners/authorities/minters and inert operation closures. The real refusal fixture opens another project
with `RunningGraph(prepared: nil)` and acquires its lease; it fabricates no preparation or retirement.
The post-publication fixture observes the actual published session through a candidate-stop handshake, then
checks invalidation, exact cleanup refusal, unchanged other-project lease and queue advancement.
Assignment-cancellation tests use the same `startUnlessCancelled` guard as the actual live/demo adapters,
with inert start closures. Actual AppModel/SwiftUI/AppIntents compilation remains separate pending qualification.

The dependency-light moves retain unchanged WingNodeKind and WingOutputConnectorBank in one WingAddressTypes
file, and unchanged direct phase/protocol and budget declarations. The closure retains the real validator,
PendingPreparation, offline processor/compiler/admission/ScratchArena, FaderMath, ActionPolicy, clocks,
CryptoKit identity and canonical audit/receipt sink. No shadow declarations or SwiftOSC dependency are allowed.

AU7c1 introduces no beginApply, dropped, verifiedReconnect, completeRestore, production minter construction,
lease acquisition, engine installation/retirement or recovery execution. Under AU7c1 Apply/mixer remained ungated
and their permission warnings were true; AU8c-2 below gates real-session Apply, and the mixer stays ungated. AU8d
and AU8c remain separate.
AU7c2 (#792) fences close-before-paused-Apply ordering inside the owner only. `windowClosed(w)` marks every
in-flight `beginApply(w)` before it waits for the lifecycle lock; each apply registers before its first suspension
and unregisters on return, so the per-apply fence itself caches no closed-window history, permission or authority
(AU7c4 adds an identity-only `closedWindows` set). Every session recheck,
including the one before `completeRestore`, then refuses `.windowClosed` (`.noSession` first). A close queued behind
an apply's lease work still detaches after the refused apply, so the closed window ends unattached. Under AU7c2
alone, a later apply on the same `WindowID` (AppRootView reuses it on reappear) was not fenced; AU7c4 below refuses
it until the root is reopened. An apply whose window closes during
`completeRestore` is refused only after that restore is acknowledged (pinned at the test-only
`.restoreAcknowledging` checkpoint); other in-flight applies of `w` queued behind it are refused at their first
recheck. Mirror-run `OwnerRaces` tests cover this.
AU7c3 (#795) applies that fence when the detach is requested, not on its FIFO turn. `HostWingLifecycle.detach(w)` starts
a task that calls the owner's lock-free `fenceApplies(for: w)`, which `windowClosed` still calls first (history-free in
AU7c3; AU7c4 also records `w` in `closedWindows`), then reserves its turn as before; the detach itself (`windowClosed`)
still waits behind earlier queued replacements, and queue order is unchanged. `Completion.fenced()` joins only the
fence; `wait()` joins both. An apply for `w` already in flight when the fence lands is refused `.windowClosed`; one
paused after its lease check may already have acquired or attached, and stays attached until the detach's turn. The
fence is a task started at submission (a MainActor job, then one owner hop). An owner-nil sequencer's fence and detach
are inert. Mirror-run `LifecycleComposition` tests cover this; `beginApply` then had no production caller.
AU7c4 (#804) keeps a closed root closed until it is reopened. The owner keeps `closedWindows`, a set of window
identities only (no permission, authority or session): `fenceApplies(for: w)`, and so `windowClosed(w)`, inserts `w`,
and the lock-free `windowOpened(w)` removes it. `beginApply(w)` refuses a closed `w` `.windowClosed` at entry, and every
recheck refuses it too (`.noSession` first). `windowOpened` does not clear the per-apply fence flags, so an apply fenced
in an earlier lifetime stays refused. A reused `WindowID` (AppRootView keeps it on reappear) is therefore refused after
the fence lands until `HostWingLifecycle.open(w)` runs on its own FIFO turn; `open` has a no-op fence, and with an
owner-nil sequencer it is inert. The sequencer counts detach submissions per window. A `detach(w)` passes its count as
a generation to `fenceApplies(for: w, generation:)`, and the owner records the highest generation fenced for `w`. An
`open(w)` captures the count at submission and passes it to `windowOpened(_:generation:)`. The owner reopens `w` only
if no higher generation was fenced, checked and removed in one actor job. So a later detach wins even when its fence
reaches the owner before the open's hop does (actor jobs need not run in submission order), and only an open
submitted after that detach reopens `w`. Generations come from the one `HostWingLifecycle` (`AppModel.shared`): a
second sequencer or a direct owner caller must not share a `WindowID` with it. There is no separate MainActor
check: until a later detach's fence lands, `w` races it like any apply races an in-flight fence (the fence flags
in-flight applies, and the detach's turn detaches `w`). Under AU7c4 alone, `closedWindows`, the owner's generation
map and the per-window `detachSubmissions` were never pruned; AU8c-1 below bounds them. A detach's turn awaits its early
fence before `windowClosed`, so a late fence cannot re-close a root reopened after it; no test pins this ordering (it
would need a production hook to delay the fence task). Mirror-run `Owner`, `OwnerRaces` and
`LifecycleComposition(Races)` tests cover this. Under AU7c4 a window that was never closed was not refused; AU8c-1
refuses it.
AU8c-1 (#874) wires root `open` and replaces `closedWindows` with a strict open-window set. `AppRootView.onAppear`
submits `wingLifecycle.open(workspaceWindow)` before its other appear work, so first appear and every reappear reopen
the retained `WindowID` on its FIFO turn; `onDisappear` still submits `detach`. The owner's `openWindows` holds window
identities only: `windowOpened` inserts `w` (unless stale), and `fenceApplies`, and so `windowClosed`, removes it.
`beginApply(w)` refuses any `w` not in the set `.windowClosed`, never-opened included, and `staleness` too (`.noSession`
first). A closed window therefore needs no entry. The sequencer's per-window `detachSubmissions` map is now one
counter of detach submissions across all windows, never reset: a detach fences and closes with its new value, and an
`open` captures the value at submission. The owner's `closureGenerations` keeps, per window, the highest fenced
generation (generation 0 records nothing), and `windowClosed(w, generation: g)` releases the entry, in the same actor
job as its fence, when it is at most `g`; an entry a later detach's fence raised stays until that detach's own close
releases it. So after a detach's turn with no later detach pending, the owner keeps nothing for `w`, and the
sequencer keeps nothing per window; across open/detach cycles the state stays bounded by the open roots and the
detaches still queued. Pruning cannot let a stale open reopen `w`: an open is stale only if a detach of `w` was
submitted after it. Every open submitted before the releasing detach ran on an earlier FIFO turn, and an open's turn
awaits its owner hop, so none is still pending. An open submitted after it carries at least `g`. If it precedes a later
detach `g'`, that detach's fence either landed before the release (the entry is `g'`, which is not released) or lands
after it (recording `g'` > the open's generation, so its hop is refused), or after the open's hop, which is the
fence race AU7c4 already accepts. Because the counter never restarts, a detach submitted after a release cannot reuse a
generation an earlier open captured. An owner-nil sequencer only counts and serializes. Mirror-run `Owner`,
`OwnerRaces` and `LifecycleComposition(Races)` tests cover this; `beginApply` had no production caller until AU8c-2.
AU8c-2 (#876) routes Studio Apply. `AppRootView` passes `workspaceWindow` to `StudioView`, whose Listen calls
`applyStudio(window:)`, which delegates to `StudioApplyRoute.apply` in `HostWingLifecycle.swift`. While `wing.isDemo`
it calls the ungated `applyAndVerify(_:safetySettings:)` and never touches the owner (decision 5). Otherwise it sends
nothing and returns a `.failed` verification (zero confirmed, a typed `Refusal` message) when the owner or window is
missing, when the owner's live permission is `nil` (a read-only check before `beginApply`, so an ungranted tap
claims no lease), when `beginApply(window:)` refuses, or when the owner's session differs from `wing.sessionID`.
Otherwise it builds one `WingApplyGrantMinter` (owner authority, Studio project, the window, `directApplyBudget`
of the same plan, the owner's provider) and calls the gated overload; a refused mint is that overload's `.failed`
result and never falls back. A revoke between the check and the mint is refused by the mint. A session mismatch
after `beginApply` leaves the window rendering, as any later refusal does. Real-session Apply therefore needs a
Host-role grant each launch, the root window open, and that window to be the only one rendering; Demo Mode and the
mixer are unchanged. Production still calls no `dropped()`; AU8d S1 below adds the verified reconnect. Mirror-run
`StudioApplyRouting` tests cover this; the Views/AppModel wiring needs hosted compilation.
AU8d S1 (#878) verifies every live connect. `connected(session:)` clears the owner's verified session on each
connect, so after `candidate.finish()` for a published `.connected(session)` the lifecycle starts a task it owns
that runs `Candidate.reread(session)`; the next replacement's turn cancels it, and it holds no FIFO turn, so a
later replace, detach or open never waits for it. It calls `owner.verifiedReconnect(session:)` only when the
re-read returned true, the task was not cancelled and the candidate is still current; the owner's own session check
is defence in depth. `Candidate.reread` defaults to never verifying; AppModel passes
`WingController.verifyReread(session:)` for connected outcomes only, and Demo, disconnected and failed outcomes
never re-read. `verifyReread` reads all 144 `WingLiveObservations.addresses` through `readFreshConfirmed`
(GET-only, 2 s, paced `bulkRefreshBatchSize`/`bulkRefreshBatchDelay`): only replies received after the request, on
that session, count, and Demo Mode, a disconnect, a session change, a timeout or cancellation is false. Existing
`readFreshConfirmed` callers keep the unpaced 750 ms default, and shared Listen/Temporary Move confirmations are not
invalidated. Mirror-run `LifecycleReread` and `WingStateReread` tests cover this; the AppModel wiring needs hosted
compilation. Production still calls no `dropped()` (S2).
A failed re-read is not retried: one lost UDP reply or a console slower than 2 s leaves the project recovering until
the next connect, and `beginApply` cannot complete that restore because the owner has no verified session. A Listen
confirmation started during the 2 s window can also clear an observed address's confirmation and fail the re-read.
Both outcomes refuse rather than allow. Neither can strand a project today: only `dropped()` owes a restore, and
production calls no `dropped()`.
Still open: window liveness beyond root appear/disappear, and AU8d S2 (drop detection). S2 must settle a re-read
retry or re-trigger policy before it adds any production `dropped()` caller.
Root disappearance is not native close qualification, and native close remains unqualified.
WingController.disconnect cancels but does not join its tasks; awaited socket stop is not callback quiescence.
Nothing here qualifies #191/G2 native reclamation.
