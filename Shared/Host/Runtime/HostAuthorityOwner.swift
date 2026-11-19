//
//  HostAuthorityOwner.swift
//  FluxKlang
//
//  The process-wide owner of the gated WING apply's inputs (#62 AU8a,
//  docs/transformation/host-authority-sources.md §3): the host epoch, the Studio
//  project, the `HostAuthority`, the WING session, the render lease and the live
//  permission. Kept out of `Shared/Host/Authority` (§4). `AppModel` injects
//  `shared` into `HostWingLifecycle` (#62 AU7c1), which calls it, as do
//  `StudioApplyRoute` (#62 AU8c-2) and `HostUserPermissionOwner` (#62 AU8b).
//

import Foundation

actor HostAuthorityOwner {
    /// Why an apply gesture cannot render.
    enum ApplyRefusal: Error, Equatable, Sendable {
        /// No real WING session: disconnected, dropped or in Demo Mode.
        case noSession
        /// Another window renders the Studio lease (decision 6).
        case otherWindowRenders
        /// The applying window closed while the apply was in flight.
        case windowClosed
        case authority(HostAuthorityRefusal)
    }

    private static let sharedOwner: HostAuthorityOwner = {
        do { return try HostAuthorityOwner() } catch {
            preconditionFailure("Invalid host authority owner: \(error)")
        }
    }()

    /// The one owner in the process (decision 1).
    static var shared: HostAuthorityOwner { sharedOwner }

    /// The host monotonic clock (`ContinuousClock`): a label and a declared nominal
    /// rate, not a time source (decision 9). The ledger accepts only media rates.
    static let primaryClock = ClockID(validated: "host.monotonic")
    static let nominalRate = 48_000

    /// Minted once, in init (decision 1).
    nonisolated let hostEpoch: HostEpoch
    /// The app-scoped Studio project (decision 4).
    nonisolated let studio: ProjectID
    nonisolated let authority: HostAuthority
    /// No devices and no routes: the apply route lives in `WingDirectSendScope` (decision 9).
    nonisolated let capabilities: DeviceCapabilityDocument
    /// Apply, disconnect/demo, drop, window close and admission await the Studio open.
    let opened: Task<Result<Void, HostAuthorityRefusal>, Never>
    /// nil when disconnected, dropped or in Demo Mode.
    private(set) var session: UUID?
    /// The session whose state re-read succeeded (decision 7; AU8d supplies the signal).
    private var verifiedSession: UUID?
    /// nil at launch and after a revoke (decision 2).
    private(set) var permission: PermissionFingerprint?
    /// The last grant's revision; the first grant is 1. Never reset.
    private(set) var grantRevision: UInt64
    private var sessionVersion = UUID()
    /// In-flight `beginApply` calls only, each removed on return: its window and whether that
    /// window closed meanwhile. Window identity across calls lives in `openWindows`.
    private var applies: [UUID: (window: WindowID, closed: Bool)] = [:]
    /// Windows opened and not closed or fenced since (AU8c-1); no permission or authority. Any other
    /// window, including one never opened, is closed, so a closed window needs no entry.
    private(set) var openWindows: Set<WindowID> = []
    /// Per window, the highest sequencer detach generation fenced and not yet released by a close; a
    /// lower-generation open is stale. Generations come from the one `HostWingLifecycle`'s monotonic
    /// counter; no second sequencer may share a `WindowID`. Only windows with a fenced detach still
    /// before its close have an entry.
    private(set) var closureGenerations: [WindowID: UInt64] = [:]
    private var lifecycleBusy = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Internal, init-only test seam; production never suspends at these checkpoints.
    enum Checkpoint: Sendable { case applyStarting, leaseRead, leaseChecked, leaseReady, restoreAcknowledging }
    private let checkpoint: (@Sendable (Checkpoint) async -> Void)?
    private let sessionInvalidated: (@Sendable () -> Void)?
    private let lifecycleQueued: (@Sendable () -> Void)?
    private var publication: Task<Void, Never>?
    /// Init-only test observation of the single publisher and its joining callers.
    enum PublicationCheckpoint: Sendable {
        case captured(PermissionFingerprint?), published(PermissionFingerprint?), joining
    }
    private let publicationCheckpoint: (@Sendable (PublicationCheckpoint) async -> Void)?

    /// `resumingGrantsAfter` is for tests only (exercising exhaustion), like
    /// `EngineLeaseRegistry(resumingAfter:)`; production starts at 0.
    init(host: HostID = HostID(uuid: UUID()), studio: ProjectID = ProjectID(uuid: UUID()),
         resumingGrantsAfter lastGrant: UInt64 = 0,
         checkpoint: (@Sendable (Checkpoint) async -> Void)? = nil,
         sessionInvalidated: (@Sendable () -> Void)? = nil,
         lifecycleQueued: (@Sendable () -> Void)? = nil,
         publicationCheckpoint: (@Sendable (PublicationCheckpoint) async -> Void)? = nil) throws {
        hostEpoch = HostEpoch(host: host, generation: .initial)
        self.studio = studio
        grantRevision = lastGrant
        self.checkpoint = checkpoint
        self.sessionInvalidated = sessionInvalidated
        self.lifecycleQueued = lifecycleQueued
        self.publicationCheckpoint = publicationCheckpoint
        capabilities = try DeviceCapabilityDocument(revision: .initial, host: host, hostEpoch: .initial,
                                                    devices: [], routes: [])
        let ledger = try GenerationLedger(primaryClock: Self.primaryClock, musicalClock: nil,
                                          nominalRate: Self.nominalRate)
        let live = HostLiveState(hostEpoch: hostEpoch, permission: nil, capabilities: capabilities)
        let authority = try HostAuthority(host: ledger, live: live, sendScope: WingDirectSendScope())
        self.authority = authority
        let studioGraph = RunningGraph(revision: .initial, prepared: nil)
        opened = Task { await authority.open(project: studio, running: studioGraph) }
    }

    /// Connect records the session and acquires nothing (decision 8).
    func connected(session: UUID) async {
        await lockLifecycle()
        defer { unlockLifecycle() }
        self.session = session
        sessionVersion = UUID()
        verifiedSession = nil
    }

    /// A planned loss (Disconnect, controller swap): `release`, so no mute is owed (decision 7).
    func disconnected() async -> Result<Void, HostAuthorityRefusal> {
        invalidateSession()
        sessionInvalidated?()
        await lockLifecycle()
        defer { unlockLifecycle() }
        invalidateSession()
        _ = await opened.value
        switch await authority.release(project: studio) {
        case .success, .failure(.lease(.notHeld)): return .success(())
        case .failure(let refusal): return .failure(refusal)
        }
    }

    /// Entering Demo Mode is a planned loss; leaving it is a connect (decision 5).
    func enteredDemoMode() async -> Result<Void, HostAuthorityRefusal> {
        await disconnected()
    }

    /// An unplanned drop (transport failure): `leaseLost`, so the project recovers (decision 7).
    func dropped() async -> Result<Void, HostAuthorityRefusal> {
        invalidateSession()
        sessionInvalidated?()
        await lockLifecycle()
        defer { unlockLifecycle() }
        invalidateSession()
        _ = await opened.value
        guard let token = await authority.snapshot().lease?.token else { return .success(()) }
        return await authority.leaseLost(token).map { _ in () }
    }

    /// `session` is connected and its state re-read; only then is a restore completed (decision 7).
    func verifiedReconnect(session verified: UUID) async {
        await lockLifecycle()
        defer { unlockLifecycle() }
        guard verified == session else { return }
        verifiedSession = verified
        await completeRestore()
    }

    /// `window`'s apply gesture: acquires a free lease, keeps its own, or attaches to an
    /// unattached one; another rendering window refuses it (decision 6). Returns the session.
    /// A loss or a close of `window` while it is in flight refuses it, the loss first; so does a
    /// `window` that is not open, until `windowOpened` (re)opens it.
    func beginApply(window: WindowID) async -> Result<UUID, ApplyRefusal> {
        guard let session, openWindows.contains(window) else {
            return .failure(session == nil ? .noSession : .windowClosed)
        }
        let version = sessionVersion
        let apply = UUID()
        applies[apply] = (window, false)
        defer { applies[apply] = nil }
        await checkpoint?(.applyStarting)
        await lockLifecycle()
        defer { unlockLifecycle() }
        _ = await opened.value
        if let refusal = staleness(of: apply, version) { return .failure(refusal) }
        let lease = await authority.snapshot().lease
        await checkpoint?(.leaseRead)
        if let refusal = staleness(of: apply, version) { return .failure(refusal) }
        await checkpoint?(.leaseChecked)
        let result: Result<EngineLeaseSnapshot, HostAuthorityRefusal>
        switch lease {
        case nil: result = await authority.acquire(project: studio, window: window)
        case let held? where held.windows.contains(window): result = .success(held)
        case let held? where held.windows.isEmpty: result = await authority.attach(window, project: studio)
        case _?: return .failure(.otherWindowRenders)
        }
        await checkpoint?(.leaseReady)
        if let refusal = staleness(of: apply, version) { return .failure(refusal) }
        if case .failure(let refusal) = result { return .failure(.authority(refusal)) }
        await completeRestore()
        if let refusal = staleness(of: apply, version) { return .failure(refusal) }
        return .success(session)
    }

    private func staleness(of apply: UUID, _ version: UUID) -> ApplyRefusal? {
        guard version == sessionVersion else { return .noSession }
        guard let entry = applies[apply] else { return nil }
        // Defence in depth: any close or fence after registration also flags the entry, so the set never decides.
        return entry.closed || !openWindows.contains(entry.window) ? .windowClosed : nil
    }

    /// Marks `window`'s in-flight applies closed, so each is refused at its next recheck, and closes
    /// `window` until a `windowOpened` of at least `generation`. Takes no lock. A queued detach sends
    /// this before its turn with its submission generation; 0 raises no recorded generation.
    func fenceApplies(for window: WindowID, generation: UInt64) {
        openWindows.remove(window)
        if generation > closureGenerations[window, default: 0] { closureGenerations[window] = generation }
        for (id, apply) in applies where apply.window == window { applies[id]?.closed = true }
    }

    /// The root of `window` (re)appeared: later applies may render again. Takes no lock; the sequencer
    /// FIFO orders it after a queued detach. Applies fenced in an earlier lifetime stay refused.
    /// `generation` is the open's view of detach submissions: a stale open, whose hop lands after a
    /// later detach's fence, leaves `window` closed. Checked and inserted in one actor job.
    func windowOpened(_ window: WindowID, generation: UInt64) {
        guard generation >= closureGenerations[window, default: 0] else { return }
        openWindows.insert(window)
    }

    /// Window close: a rendering window detaches, dropping its tickets; the lease stays held.
    /// Before any wait it fences `window`'s in-flight applies, which are then refused; this close
    /// then detaches whatever one holding the lock attached. `window` stays closed until reopened.
    /// `generation` is the closing detach's (0 outside the sequencer). Every open submitted before that
    /// detach ran on an earlier turn and any later one carries at least `generation`, so its entry is
    /// released unless a later detach's fence already raised it; that detach's close releases it.
    func windowClosed(_ window: WindowID, generation: UInt64 = 0) async {
        fenceApplies(for: window, generation: 0)
        if closureGenerations[window, default: 0] <= generation { closureGenerations[window] = nil }
        await lockLifecycle()
        defer { unlockLifecycle() }
        _ = await opened.value
        guard await authority.snapshot().lease?.windows.contains(window) == true else { return }
        _ = await authority.detach(window)
    }

    /// Drains the lane once the current session is verified: mutes reach no hardware
    /// (§7) and a queued restore is acknowledged.
    private func completeRestore() async {
        guard let session, verifiedSession == session, await authority.snapshot().lease != nil else { return }
        while let command = await authority.nextEngineCommand() {
            guard self.session == session, verifiedSession == session else { return }
            guard case .restore(let attempt, let revision, let target, let token) = command else { continue }
            await checkpoint?(.restoreAcknowledging)
            _ = await authority.restoreCompleted(attempt: attempt, revision: revision, target: target, token: token)
        }
    }

    private func invalidateSession() {
        (session, verifiedSession) = (nil, nil)
        sessionVersion = UUID()
    }

    /// A loss invalidates immediately, but its release waits for in-flight lease work.
    /// No stale apply releases by project: that could release a replacement's lease.
    private func lockLifecycle() async {
        if !lifecycleBusy {
            lifecycleBusy = true
            return
        }
        await withCheckedContinuation {
            lifecycleWaiters.append($0)
            lifecycleQueued?()
        }
    }

    private func unlockLifecycle() {
        if lifecycleWaiters.isEmpty { lifecycleBusy = false } else { lifecycleWaiters.removeFirst().resume() }
    }

    /// Raises the revision and publishes atomically with respect to the owner's storage.
    func grant(_ role: HostUserRole) async -> Result<PermissionFingerprint, HostGrantRefusal> {
        guard grantRevision < .max else { return .failure(.revisionExhausted) }
        grantRevision += 1
        let fingerprint = Self.fingerprint(role, revision: grantRevision)
        permission = fingerprint
        await publishLive()
        return .success(fingerprint)
    }

    /// Clears the live permission; the revision stays (decision 2).
    func revoke() async {
        permission = nil
        await publishLive()
    }

    /// All callers await one publisher; no older update can remain after it completes.
    private func publishLive() async {
        if let publication {
            await publicationCheckpoint?(.joining)
            await publication.value
            return
        }
        let publication = Task { await flushLive() }
        self.publication = publication
        await publication.value
    }

    private func flushLive() async {
        var sent: PermissionFingerprint?
        repeat {
            sent = permission
            await publicationCheckpoint?(.captured(sent))
            await authority.updateLive(HostLiveState(hostEpoch: hostEpoch, permission: sent,
                                                     capabilities: capabilities))
            await publicationCheckpoint?(.published(sent))
        } while sent != permission
        // Only the publisher clears its slot, in the same turn as the final comparison.
        publication = nil
    }
}
