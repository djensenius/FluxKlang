//
//  LeaseFixture.swift
//  FluxKlangTests
//
//  An engine lease registry and its host ledger built through the real lease
//  and ledger APIs, so each fixture state is reached by legal transitions only.
//

@testable import FluxKlang

/// Why a lease fixture could not be built.
enum LeaseFixtureError: Error, Equatable, Sendable {
    case lease(EngineLeaseError)
    case ledger(GenerationLedgerError)
    case ids(FixtureIDSequenceError)
    /// A token about to be recorded as stale was not the one `window` renders under.
    case tokenNotRendering
}

/// One lease registry and the ledger that declares `EngineLeaseRegistry.contextKey`.
///
/// `project` (`fx.project.1`) owns `window` (`fx.window.1`); `otherProject`
/// (`fx.project.2`) owns `otherWindow` (`fx.window.2`). Every lease change applies
/// its context change to `ledger` exactly once. What `make` leaves:
/// - `available`: `project` holds the lease with `window`, which renders (`.running`).
/// - `missing`: nothing was ever acquired; `.stopped`.
/// - `stale`: acquired, released and reacquired by `project` with `window`.
///   `staleToken` is the released token and `contextRequirement` the requirement
///   taken under it; both are stale. The lease itself renders (`.running`).
/// - `failed`: acquired while `.running`, then lost (released); no holder, and the
///   engine is `.running.after(.leaseLost)`, so `.recovering` and muted. A release
///   is the only legal way for the registry to lose the lease.
/// - `pressured`: as `available`, with `fx.window.3…65` also attached, so the
///   lease is at `EngineLeaseRegistry.windowLimit`.
/// `heldByOther()`: `otherProject` holds the lease with `otherWindow`.
/// `lifecycle` is what `window` of `project` observes; in every state but
/// `stale`, `contextRequirement` is current.
struct LeaseFixture: Sendable {
    static var nominalRate: Int { 48_000 }
    static var contextKey: GenerationKey { EngineLeaseRegistry.contextKey }

    let project: ProjectID
    let otherProject: ProjectID
    let window: WindowID
    let otherWindow: WindowID
    var registry: EngineLeaseRegistry
    var ledger: GenerationLedger
    /// The released token in `stale`, otherwise nil.
    let staleToken: EngineLeaseToken?
    /// Derived once, when the fixture is built; it is not updated when a caller later changes `registry`.
    let lifecycle: EngineLifecycle
    var contextRequirement: GenerationRequirement

    static func make(_ state: ContractFixtureState) throws(LeaseFixtureError) -> Self {
        var build = try Build()
        switch state {
        case .missing:
            break
        case .available:
            try build.acquire(build.project, build.window)
        case .stale:
            let old = try build.acquire(build.project, build.window)
            build.staleToken = old
            try build.requireRendering(build.staleToken)
            let oldRequirement = build.requirement
            try build.release(old)
            try build.acquire(build.project, build.window)
            build.requirement = oldRequirement
        case .failed:
            let token = try build.acquire(build.project, build.window)
            try build.release(token)
            build.engine = build.engine.after(.leaseLost)
        case .pressured:
            let token = try build.acquire(build.project, build.window)
            try build.fill(token)
        }
        return Self(build)
    }

    static func heldByOther() throws(LeaseFixtureError) -> Self {
        var build = try Build()
        try build.acquire(build.otherProject, build.otherWindow)
        return Self(build)
    }

    /// The observable state, for comparing fixtures and proving refusals changed
    /// nothing. Token identity is deliberately left out: two fixtures built the
    /// same way hold distinct tokens.
    var snapshot: Snapshot { Snapshot(self) }

    struct Snapshot: Hashable, Sendable {
        let holder: ProjectID?
        let windows: Set<WindowID>
        let generation: Generation?
        let lastIssued: Generation?
        let staleGeneration: Generation?
        let lifecycle: EngineLifecycle
        let generations: [GenerationKey: Generation]
        let contextRequirement: GenerationRequirement

        init(_ fixture: LeaseFixture) {
            holder = fixture.registry.snapshot?.project
            windows = fixture.registry.snapshot?.windows ?? []
            generation = fixture.registry.snapshot?.generation
            lastIssued = fixture.registry.lastIssued
            staleGeneration = fixture.staleToken?.generation
            lifecycle = fixture.lifecycle
            generations = fixture.ledger.current
            contextRequirement = fixture.contextRequirement
        }
    }

    private init(_ build: Build) {
        project = build.project
        otherProject = build.otherProject
        window = build.window
        otherWindow = build.otherWindow
        registry = build.registry
        ledger = build.ledger
        staleToken = build.staleToken
        lifecycle = EngineLifecycle.observed(by: build.window, of: build.project, in: build.registry,
                                             engine: build.engine)
        contextRequirement = build.requirement
    }

    /// The fixture under construction; only legal lease and ledger operations change it.
    private struct Build {
        let project: ProjectID
        let otherProject: ProjectID
        let window: WindowID
        let otherWindow: WindowID
        var windowIDs: FixtureIDSequence<WindowTag>
        var registry = EngineLeaseRegistry()
        var ledger: GenerationLedger
        var staleToken: EngineLeaseToken?
        var engine = EngineLifecycle.stopped
        var requirement: GenerationRequirement

        init() throws(LeaseFixtureError) {
            do {
                var projects = try FixtureIDSequence<ProjectTag>(prefix: "project", limit: 2)
                windowIDs = try FixtureIDSequence(prefix: "window", limit: EngineLeaseRegistry.windowLimit + 1)
                (project, otherProject) = (try projects.next(), try projects.next())
                (window, otherWindow) = (try windowIDs.next(), try windowIDs.next())
            } catch { throw .ids(error) }
            do {
                ledger = try GenerationLedger(
                    primaryClock: ContractFixtureIDs.primaryClock, musicalClock: nil,
                    nominalRate: LeaseFixture.nominalRate, declaring: [LeaseFixture.contextKey]
                )
            } catch { throw .ledger(error) }
            requirement = GenerationRequirement(key: LeaseFixture.contextKey, generation: .initial)
        }

        @discardableResult
        mutating func acquire(_ holder: ProjectID, _ first: WindowID) throws(LeaseFixtureError) -> EngineLeaseToken {
            let grant: EngineLeaseGrant
            do { grant = try registry.acquire(project: holder, window: first) } catch { throw .lease(error) }
            try apply(grant.context)
            engine = .running
            return grant.snapshot.token
        }

        /// Proves `token` is the current lease token: `window` of `project` renders under it.
        func requireRendering(_ token: EngineLeaseToken?) throws(LeaseFixtureError) {
            guard let token, registry.role(of: window, project: project) == .renders(token) else {
                throw .tokenNotRendering
            }
        }

        mutating func release(_ token: EngineLeaseToken) throws(LeaseFixtureError) {
            let change: ContextChange
            do { change = try registry.release(expected: token) } catch { throw .lease(error) }
            try apply(change)
        }

        /// Attaches the project's remaining windows up to `windowLimit`; attaching changes no context.
        mutating func fill(_ token: EngineLeaseToken) throws(LeaseFixtureError) {
            while let held = registry.snapshot, held.windows.count < EngineLeaseRegistry.windowLimit {
                let next: WindowID
                do { next = try windowIDs.next() } catch { throw .ids(error) }
                do { try registry.attach(next, project: project, expected: token) } catch { throw .lease(error) }
            }
        }

        private mutating func apply(_ change: ContextChange) throws(LeaseFixtureError) {
            let generation: Generation
            do { generation = try change.apply(to: &ledger) } catch { throw .ledger(error) }
            requirement = GenerationRequirement(key: change.key, generation: generation)
        }
    }
}
