//
//  EngineLease.swift
//  FluxKlang
//
//  The one engine lease per host (status-diagnostics.md "Lifecycle",
//  host-remote-roles.md "One engine lease per host"). Exactly one project holds
//  it; any of that project's attached windows render, every other window may
//  only edit and prepare. A lease change is a `contextChange` (media-contract.md
//  §5.8) that the caller applies to its own `GenerationLedger`.
//

enum WindowTag: ContractIDTag {}
typealias WindowID = ContractID<WindowTag>

/// Opaque process-local lease identity, not an authorization credential.
/// Every issued lease has its own identity, so a token issued by a discarded copy
/// of the registry never equals a token issued by the original, even at the same
/// generation. Retaining the identity prevents address reuse while any token survives.
struct EngineLeaseToken: Hashable, Sendable {
    fileprivate final class Identity: Sendable {}
    fileprivate let instance: Identity
    /// The lease generation; compared for equality only (M2).
    let generation: Generation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instance === rhs.instance && lhs.generation == rhs.generation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(instance))
        hasher.combine(generation)
    }
}

/// The held lease. Only the registry creates one.
struct EngineLeaseSnapshot: Hashable, Sendable {
    let token: EngineLeaseToken
    let project: ProjectID
    let windows: Set<WindowID>
    var generation: Generation { token.generation }

    fileprivate init(token: EngineLeaseToken, project: ProjectID, windows: Set<WindowID>) {
        self.token = token
        self.project = project
        self.windows = windows
    }
}

enum WindowRenderRole: Hashable, Sendable {
    case renders(EngineLeaseToken)
    /// The window's project, or the window itself, is not on the lease.
    case editAndPrepareOnly(heldBy: ProjectID)
    /// No project holds the lease.
    case stopped
}

/// Every refusal leaves the registry unchanged.
enum EngineLeaseError: Error, Hashable, Sendable {
    case heldByOtherProject(ProjectID)
    /// The project already holds the lease; further windows attach instead.
    case alreadyHeld
    case staleToken
    case notHeld
    case windowLimit
    case alreadyAttached
    case unknownWindow
    case overflow
}

/// One `contextChange` bump of the host's engine context counter.
struct ContextChange: Hashable, Sendable {
    let key: GenerationKey

    fileprivate init(key: GenerationKey) {
        self.key = key
    }

    /// Bumps `key` with `.contextChange`, making every requirement on the old
    /// context generation stale. Every call bumps again, so apply each change
    /// exactly once. A refusal (for example an undeclared counter) leaves the
    /// ledger unchanged.
    @discardableResult
    func apply(to ledger: inout GenerationLedger) throws(GenerationLedgerError) -> Generation {
        try ledger.bump(key, reason: .contextChange)
    }
}

/// The result of acquiring or transferring the lease.
struct EngineLeaseGrant: Hashable, Sendable {
    let snapshot: EngineLeaseSnapshot
    let context: ContextChange
}

/// One registry per host process. Sendable does not provide synchronization; the
/// owner serializes access. The lease generation is not part of any command revision.
///
/// Refusals leave the registry unchanged. Token checks run in a fixed order:
/// no lease (`notHeld`), then a token other than the current one (`staleToken`),
/// then the operation's own checks; overflow is checked before any mutation.
///
/// The registry and the caller's ledger are separate values. To change both or
/// neither, stage the operation on copies and commit both only after `apply`
/// succeeds:
///
///     var stagedRegistry = registry
///     var stagedLedger = ledger
///     let grant = try stagedRegistry.acquire(project: project, window: window)
///     try grant.context.apply(to: &stagedLedger)
///     registry = stagedRegistry
///     ledger = stagedLedger
///
/// A discarded staged copy's tokens never match the committed registry.
struct EngineLeaseRegistry: Sendable {
    static let windowLimit = 64
    /// The per-host engine context counter that every lease change bumps.
    static let contextKey = GenerationKey(.context, GenerationSubject(validated: "ctx.engine"))

    private(set) var snapshot: EngineLeaseSnapshot?
    /// The last issued lease generation; it never repeats, so a released or
    /// replaced token never becomes current again.
    private(set) var lastIssued: Generation?

    /// For diagnostics and test continuity only (for example exercising overflow),
    /// not persistence: tokens are process-local. nil starts at generation 1.
    init(resumingAfter lastIssued: Generation? = nil) {
        self.lastIssued = lastIssued
    }

    mutating func acquire(project: ProjectID, window: WindowID) throws(EngineLeaseError) -> EngineLeaseGrant {
        if let snapshot {
            throw snapshot.project == project ? .alreadyHeld : .heldByOtherProject(snapshot.project)
        }
        return try issue(project: project, window: window)
    }

    /// Adds a window of the holding project to the lease. Windows of other
    /// projects are refused and never occupy one of the `windowLimit` slots.
    @discardableResult
    mutating func attach(
        _ window: WindowID, project: ProjectID, expected: EngineLeaseToken
    ) throws(EngineLeaseError) -> EngineLeaseSnapshot {
        let held = try current(expected)
        guard held.project == project else { throw .heldByOtherProject(held.project) }
        guard !held.windows.contains(window) else { throw .alreadyAttached }
        guard held.windows.count < Self.windowLimit else { throw .windowLimit }
        return replaceWindows(of: held, with: held.windows.union([window]))
    }

    /// Removing the last window keeps the lease; only `release` ends it.
    @discardableResult
    mutating func detach(
        _ window: WindowID, expected: EngineLeaseToken
    ) throws(EngineLeaseError) -> EngineLeaseSnapshot {
        let held = try current(expected)
        guard held.windows.contains(window) else { throw .unknownWindow }
        return replaceWindows(of: held, with: held.windows.subtracting([window]))
    }

    mutating func release(expected: EngineLeaseToken) throws(EngineLeaseError) -> ContextChange {
        _ = try current(expected)
        snapshot = nil
        return ContextChange(key: Self.contextKey)
    }

    /// Explicitly hands the lease to another project under a new generation.
    /// The previous project's windows stop rendering.
    mutating func transfer(
        to project: ProjectID, window: WindowID, expected: EngineLeaseToken
    ) throws(EngineLeaseError) -> EngineLeaseGrant {
        let held = try current(expected)
        guard held.project != project else { throw .alreadyHeld }
        return try issue(project: project, window: window)
    }

    func role(of window: WindowID, project: ProjectID) -> WindowRenderRole {
        guard let snapshot else { return .stopped }
        guard snapshot.project == project, snapshot.windows.contains(window) else {
            return .editAndPrepareOnly(heldBy: snapshot.project)
        }
        return .renders(snapshot.token)
    }

    private func current(_ expected: EngineLeaseToken) throws(EngineLeaseError) -> EngineLeaseSnapshot {
        guard let snapshot else { throw .notHeld }
        guard snapshot.token == expected else { throw .staleToken }
        return snapshot
    }

    private mutating func issue(project: ProjectID, window: WindowID) throws(EngineLeaseError) -> EngineLeaseGrant {
        let generation: Generation
        if let lastIssued {
            do { generation = try lastIssued.next() } catch { throw .overflow }
        } else {
            generation = .initial
        }
        let token = EngineLeaseToken(instance: EngineLeaseToken.Identity(), generation: generation)
        let granted = EngineLeaseSnapshot(token: token, project: project, windows: [window])
        lastIssued = generation
        snapshot = granted
        return EngineLeaseGrant(snapshot: granted, context: ContextChange(key: Self.contextKey))
    }

    private mutating func replaceWindows(
        of held: EngineLeaseSnapshot, with windows: Set<WindowID>
    ) -> EngineLeaseSnapshot {
        let updated = EngineLeaseSnapshot(token: held.token, project: held.project, windows: windows)
        snapshot = updated
        return updated
    }
}
