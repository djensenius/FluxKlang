import Testing
@testable import FluxKlang

private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let windowA1 = WindowID(validated: "win.a1")
private let windowA2 = WindowID(validated: "win.a2")
private let windowB1 = WindowID(validated: "win.b1")
private let allWindows: [(WindowID, ProjectID)] = [(windowA1, projectA), (windowA2, projectA), (windowB1, projectB)]

private func makeLedger(declaringContext: Bool = true) throws -> GenerationLedger {
    try GenerationLedger(
        primaryClock: ClockID(validated: "smp.main"), musicalClock: nil, nominalRate: 48_000,
        declaring: declaringContext ? [EngineLeaseRegistry.contextKey] : []
    )
}

/// Every project whose window currently renders.
private func renderingProjects(_ registry: EngineLeaseRegistry) -> Set<ProjectID> {
    Set(allWindows.compactMap { window, project in
        if case .renders = registry.role(of: window, project: project) { return project }
        return nil
    })
}

/// One step of an interleaving, issued by `window` of `project` with the token it last saw.
enum LeaseStep: Hashable, Sendable, CustomTestStringConvertible {
    case acquire(Int), attach(Int), detach(Int), release(Int), transfer(Int)

    var testDescription: String {
        switch self {
        case .acquire(let index): "acquire\(index)"
        case .attach(let index): "attach\(index)"
        case .detach(let index): "detach\(index)"
        case .release(let index): "release\(index)"
        case .transfer(let index): "transfer\(index)"
        }
    }
}

/// A step and the refusal the registry must return for it, or nil when it must succeed.
struct ScriptedStep: Hashable, Sendable, CustomTestStringConvertible {
    let step: LeaseStep
    let refusal: EngineLeaseError?

    static func succeeds(_ step: LeaseStep) -> Self { Self(step: step, refusal: nil) }
    static func refused(_ step: LeaseStep, _ refusal: EngineLeaseError) -> Self { Self(step: step, refusal: refusal) }

    var testDescription: String { "\(step.testDescription)\(refusal.map { "!\($0)" } ?? "")" }
}

private let heldByA = EngineLeaseError.heldByOtherProject(projectA)
private let heldByB = EngineLeaseError.heldByOtherProject(projectB)

private let interleavings: [[ScriptedStep]] = [
    [.succeeds(.acquire(0)), .refused(.acquire(2), heldByA), .succeeds(.attach(1)), .refused(.acquire(2), heldByA),
     .succeeds(.transfer(2)), .refused(.attach(0), heldByB), .refused(.release(0), .staleToken)],
    [.succeeds(.acquire(2)), .refused(.acquire(0), heldByB), .refused(.attach(1), heldByB), .succeeds(.transfer(0)),
     .refused(.attach(2), heldByA), .succeeds(.detach(0)), .refused(.acquire(2), heldByA)],
    [.succeeds(.acquire(0)), .succeeds(.attach(1)), .succeeds(.detach(0)), .succeeds(.detach(1)),
     .refused(.acquire(2), heldByA), .succeeds(.release(1)), .succeeds(.acquire(2))],
    [.succeeds(.acquire(0)), .succeeds(.transfer(2)), .refused(.attach(0), heldByB), .refused(.attach(1), heldByB),
     .succeeds(.transfer(1)), .refused(.attach(2), heldByA), .refused(.release(2), .staleToken)],
    [.succeeds(.acquire(1)), .succeeds(.release(1)), .succeeds(.acquire(2)), .refused(.attach(0), heldByB),
     .succeeds(.transfer(0)), .succeeds(.transfer(2)), .refused(.acquire(0), heldByB)],
    [.refused(.attach(0), .notHeld), .refused(.detach(2), .notHeld), .succeeds(.acquire(0)),
     .refused(.acquire(1), .alreadyHeld), .succeeds(.attach(1)), .succeeds(.transfer(2)),
     .refused(.release(1), .staleToken)]
]

struct EngineLeaseTests {
    @Test func firstWindowAcquiresLease() throws {
        var registry = EngineLeaseRegistry()
        #expect(registry.snapshot == nil && registry.role(of: windowA1, project: projectA) == .stopped)
        let grant = try registry.acquire(project: projectA, window: windowA1)
        #expect(grant.snapshot.project == projectA && grant.snapshot.windows == [windowA1])
        #expect(grant.snapshot.generation == .initial && registry.snapshot == grant.snapshot)
        #expect(grant.context.key == EngineLeaseRegistry.contextKey)
        #expect(EngineLeaseRegistry.contextKey.description == "context/ctx.engine")
        #expect(registry.role(of: windowA1, project: projectA) == .renders(grant.snapshot.token))
    }

    @Test func secondWindowOfSameProjectJoinsWithoutSecondEngine() throws {
        var registry = EngineLeaseRegistry()
        let token = try registry.acquire(project: projectA, window: windowA1).snapshot.token
        #expect(registry.role(of: windowA2, project: projectA) == .editAndPrepareOnly(heldBy: projectA))
        #expect(throws: EngineLeaseError.alreadyHeld) { try registry.acquire(project: projectA, window: windowA2) }
        let joined = try registry.attach(windowA2, project: projectA, expected: token)
        #expect(joined.token == token && joined.generation == .initial)
        #expect(joined.windows == [windowA1, windowA2] && registry.lastIssued == .initial)
        #expect(registry.role(of: windowA2, project: projectA) == .renders(token))
        #expect(renderingProjects(registry) == [projectA])
        #expect(throws: EngineLeaseError.alreadyAttached) {
            try registry.attach(windowA2, project: projectA, expected: token)
        }
    }

    @Test func windowOfOtherProjectIsEditAndPrepareOnly() throws {
        var registry = EngineLeaseRegistry()
        let token = try registry.acquire(project: projectA, window: windowA1).snapshot.token
        #expect(throws: EngineLeaseError.heldByOtherProject(projectA)) {
            try registry.acquire(project: projectB, window: windowB1)
        }
        #expect(registry.role(of: windowB1, project: projectB) == .editAndPrepareOnly(heldBy: projectA))
        let before = registry.snapshot
        // Even with A's current token, a project B window cannot join A's lease.
        #expect(throws: EngineLeaseError.heldByOtherProject(projectA)) {
            try registry.attach(windowB1, project: projectB, expected: token)
        }
        #expect(registry.snapshot == before && before?.windows == [windowA1])
        #expect(registry.role(of: windowB1, project: projectB) == .editAndPrepareOnly(heldBy: projectA))
    }

    @Test(arguments: interleavings)
    func atMostOneProjectRendersAcrossInterleavings(_ script: [ScriptedStep]) throws {
        var unrelated = EngineLeaseRegistry()
        let ghost = try unrelated.acquire(project: projectA, window: windowA1).snapshot.token
        var registry = EngineLeaseRegistry()
        var seen: [EngineLeaseToken] = [ghost, ghost, ghost]
        var issued: [EngineLeaseToken] = []
        for scripted in script {
            let before = registry.snapshot
            let issuedBefore = registry.lastIssued
            let result = Result { () throws(EngineLeaseError) -> Bool in
                try perform(scripted.step, on: &registry, seen: &seen)
            }
            switch result {
            case .success(let issues):
                #expect(scripted.refusal == nil, "\(scripted.step) succeeded")
                if issues {
                    let snapshot = try #require(registry.snapshot)
                    let expected = try issuedBefore?.next() ?? .initial
                    #expect(registry.lastIssued == expected && snapshot.generation == expected)
                    #expect(!issued.contains(snapshot.token) && snapshot.token != ghost)
                    issued.append(snapshot.token)
                } else {
                    #expect(registry.lastIssued == issuedBefore)
                }
            case .failure(let error):
                #expect(error == scripted.refusal, "\(scripted.step) refused")
                #expect(registry.snapshot == before && registry.lastIssued == issuedBefore)
            }
            #expect(renderingProjects(registry).count <= 1)
            if let snapshot = registry.snapshot {
                #expect(issued.last == snapshot.token)
                #expect(snapshot.windows.allSatisfy { window in
                    allWindows.first { $0.0 == window }?.1 == snapshot.project
                })
            }
        }
    }

    /// Issues `step` with the token its window last saw. Attach and transfer use the live token when any window
    /// observed it, else the window's own. Returns whether the step issues a new lease.
    private func perform(
        _ step: LeaseStep, on registry: inout EngineLeaseRegistry, seen: inout [EngineLeaseToken]
    ) throws(EngineLeaseError) -> Bool {
        func observed(_ index: Int) -> EngineLeaseToken {
            seen.first { $0 == registry.snapshot?.token } ?? seen[index]
        }
        switch step {
        case .acquire(let index):
            seen[index] = try registry.acquire(project: allWindows[index].1, window: allWindows[index].0).snapshot.token
            return true
        case .attach(let index):
            let (window, project) = allWindows[index]
            let token = observed(index)
            seen[index] = try registry.attach(window, project: project, expected: token).token
        case .detach(let index):
            try registry.detach(allWindows[index].0, expected: seen[index])
        case .release(let index):
            _ = try registry.release(expected: seen[index])
        case .transfer(let index):
            let token = observed(index)
            seen[index] = try registry.transfer(
                to: allWindows[index].1, window: allWindows[index].0, expected: token
            ).snapshot.token
            return true
        }
        return false
    }

    @Test func staleTokenCannotAttachDetachReleaseOrTransfer() throws {
        var registry = EngineLeaseRegistry()
        let old = try registry.acquire(project: projectA, window: windowA1).snapshot.token
        let current = try registry.transfer(to: projectB, window: windowB1, expected: old).snapshot.token
        let before = registry.snapshot
        #expect(throws: EngineLeaseError.staleToken) { try registry.attach(windowA2, project: projectA, expected: old) }
        #expect(throws: EngineLeaseError.staleToken) { try registry.detach(windowB1, expected: old) }
        #expect(throws: EngineLeaseError.staleToken) { try registry.release(expected: old) }
        #expect(throws: EngineLeaseError.staleToken) {
            try registry.transfer(to: projectA, window: windowA1, expected: old)
        }
        var other = EngineLeaseRegistry()
        let otherFirst = try other.acquire(project: projectA, window: windowA1).snapshot.token
        let foreign = try other.transfer(to: projectB, window: windowB1, expected: otherFirst).snapshot.token
        #expect(foreign.generation == current.generation && foreign != current)
        #expect(throws: EngineLeaseError.staleToken) { try registry.release(expected: foreign) }
        #expect(registry.snapshot == before && registry.snapshot?.token == current)
    }

    @Test func transferIsExplicitAndAdvancesGeneration() throws {
        var registry = EngineLeaseRegistry()
        let first = try registry.acquire(project: projectA, window: windowA1).snapshot
        _ = try registry.attach(windowA2, project: projectA, expected: first.token)
        #expect(throws: EngineLeaseError.alreadyHeld) {
            try registry.transfer(to: projectA, window: windowA2, expected: first.token)
        }
        let grant = try registry.transfer(to: projectB, window: windowB1, expected: first.token)
        #expect(grant.snapshot.project == projectB && grant.snapshot.windows == [windowB1])
        #expect(grant.snapshot.generation == (try first.generation.next()))
        #expect(grant.snapshot.token != first.token && registry.lastIssued == grant.snapshot.generation)
        #expect(registry.role(of: windowA1, project: projectA) == .editAndPrepareOnly(heldBy: projectB))
        #expect(registry.role(of: windowA2, project: projectA) == .editAndPrepareOnly(heldBy: projectB))
        #expect(renderingProjects(registry) == [projectB])
    }

    @Test func leaseChangeBumpsContextAndStalesOldRequirements() throws {
        var registry = EngineLeaseRegistry()
        var ledger = try makeLedger()
        let key = EngineLeaseRegistry.contextKey
        var requirement = GenerationRequirement(key: key, generation: try #require(ledger.generation(key)))
        let acquire = try registry.acquire(project: projectA, window: windowA1)
        let token = acquire.snapshot.token
        let changes: [ContextChange] = [
            acquire.context,
            try registry.transfer(to: projectB, window: windowB1, expected: token).context,
            try registry.release(expected: try #require(registry.snapshot).token)
        ]
        for change in changes {
            #expect(ledger.isCurrent(requirement))
            let generation = try change.apply(to: &ledger)
            #expect(!ledger.isCurrent(requirement) && ledger.generation(key) == generation)
            requirement = GenerationRequirement(key: key, generation: generation)
            #expect(ledger.isCurrent(requirement))
        }
        #expect(ledger.generation(key) == (try Generation(4)))
        #expect(throws: EngineLeaseError.notHeld) { try registry.attach(windowA2, project: projectA, expected: token) }
    }

    @Test func refusedOperationsLeaveRegistryAndLedgerUnchanged() throws {
        var registry = EngineLeaseRegistry()
        var undeclared = try makeLedger(declaringContext: false)
        let grant = try registry.acquire(project: projectA, window: windowA1)
        let ledgerBefore = undeclared.current
        #expect(throws: GenerationLedgerError.undeclaredCounter(EngineLeaseRegistry.contextKey)) {
            try grant.context.apply(to: &undeclared)
        }
        #expect(undeclared.current == ledgerBefore)
        let token = grant.snapshot.token
        let before = registry.snapshot
        let issued = registry.lastIssued
        #expect(throws: EngineLeaseError.heldByOtherProject(projectA)) {
            try registry.acquire(project: projectB, window: windowB1)
        }
        #expect(throws: EngineLeaseError.alreadyHeld) { try registry.acquire(project: projectA, window: windowA2) }
        #expect(throws: EngineLeaseError.alreadyAttached) {
            try registry.attach(windowA1, project: projectA, expected: token)
        }
        #expect(throws: EngineLeaseError.unknownWindow) { try registry.detach(windowA2, expected: token) }
        #expect(throws: EngineLeaseError.alreadyHeld) {
            try registry.transfer(to: projectA, window: windowA2, expected: token)
        }
        #expect(registry.snapshot == before && registry.lastIssued == issued)

        var exhausted = EngineLeaseRegistry(resumingAfter: try Generation(Generation.maximumValue - 1))
        let last = try exhausted.acquire(project: projectA, window: windowA1).snapshot
        #expect(last.generation.value == Generation.maximumValue)
        #expect(throws: EngineLeaseError.overflow) {
            try exhausted.transfer(to: projectB, window: windowB1, expected: last.token)
        }
        #expect(exhausted.snapshot == last && exhausted.lastIssued == last.generation)
        _ = try exhausted.release(expected: last.token)
        #expect(throws: EngineLeaseError.overflow) { try exhausted.acquire(project: projectB, window: windowB1) }
        #expect(exhausted.snapshot == nil && exhausted.lastIssued == last.generation)

        var empty = EngineLeaseRegistry()
        #expect(throws: EngineLeaseError.notHeld) { try empty.release(expected: token) }
        #expect(throws: EngineLeaseError.notHeld) { try empty.attach(windowA1, project: projectA, expected: token) }
        #expect(throws: EngineLeaseError.notHeld) { try empty.detach(windowA1, expected: token) }
        #expect(throws: EngineLeaseError.notHeld) {
            try empty.transfer(to: projectA, window: windowA1, expected: token)
        }
        #expect(empty.snapshot == nil && empty.lastIssued == nil)
    }

    @Test func windowLimitIsBounded() throws {
        #expect(EngineLeaseRegistry.windowLimit == 64)
        var registry = EngineLeaseRegistry()
        let token = try registry.acquire(project: projectA, window: WindowID(validated: "win.0")).snapshot.token
        for index in 1..<(EngineLeaseRegistry.windowLimit - 1) {
            _ = try registry.attach(try WindowID("win.\(index)"), project: projectA, expected: token)
        }
        // Other projects' windows never occupy a slot.
        #expect(throws: EngineLeaseError.heldByOtherProject(projectA)) {
            try registry.attach(windowB1, project: projectB, expected: token)
        }
        _ = try registry.attach(windowA2, project: projectA, expected: token)
        let full = registry.snapshot
        #expect(full?.windows.count == EngineLeaseRegistry.windowLimit)
        #expect(throws: EngineLeaseError.windowLimit) {
            try registry.attach(windowA1, project: projectA, expected: token)
        }
        #expect(registry.snapshot == full)
        _ = try registry.detach(WindowID(validated: "win.0"), expected: token)
        let refilled = try registry.attach(windowA1, project: projectA, expected: token)
        #expect(refilled.windows.count == EngineLeaseRegistry.windowLimit)
    }

    @Test func discardedStagedCopyTokenIsNeverCurrent() throws {
        var registry = EngineLeaseRegistry()
        var staged = registry
        let ghost = try staged.acquire(project: projectA, window: windowA1).snapshot.token
        let real = try registry.acquire(project: projectB, window: windowB1).snapshot
        #expect(ghost.generation == real.generation && ghost != real.token)
        let before = registry.snapshot
        #expect(throws: EngineLeaseError.staleToken) { try registry.release(expected: ghost) }
        #expect(throws: EngineLeaseError.staleToken) {
            try registry.attach(windowA2, project: projectB, expected: ghost)
        }
        #expect(throws: EngineLeaseError.staleToken) { try registry.detach(windowB1, expected: ghost) }
        #expect(throws: EngineLeaseError.staleToken) {
            try registry.transfer(to: projectA, window: windowA1, expected: ghost)
        }
        #expect(registry.snapshot == before && registry.role(of: windowB1, project: projectB) == .renders(real.token))
    }

    @Test func discardedStagedCopyTransferTokenIsNeverCurrent() throws {
        var registry = EngineLeaseRegistry()
        let first = try registry.acquire(project: projectA, window: windowA1).snapshot.token
        var staged = registry
        let ghost = try staged.transfer(to: projectB, window: windowB1, expected: first).snapshot.token
        let real = try registry.transfer(to: projectB, window: windowB1, expected: first).snapshot
        #expect(ghost.generation == real.generation && ghost != real.token)
        let before = registry.snapshot
        #expect(throws: EngineLeaseError.staleToken) { try registry.release(expected: ghost) }
        #expect(throws: EngineLeaseError.staleToken) {
            try registry.transfer(to: projectA, window: windowA1, expected: ghost)
        }
        #expect(registry.snapshot == before && registry.lastIssued == real.generation)
    }

    @Test func detachingLastWindowKeepsLeaseUntilExplicitRelease() throws {
        var registry = EngineLeaseRegistry()
        let token = try registry.acquire(project: projectA, window: windowA1).snapshot.token
        let detached = try registry.detach(windowA1, expected: token)
        #expect(detached.windows.isEmpty && detached.token == token && registry.snapshot == detached)
        #expect(registry.role(of: windowA1, project: projectA) == .editAndPrepareOnly(heldBy: projectA))
        #expect(throws: EngineLeaseError.heldByOtherProject(projectA)) {
            try registry.acquire(project: projectB, window: windowB1)
        }
        #expect(try registry.attach(windowA1, project: projectA, expected: token).windows == [windowA1])
    }

    @Test func releasedTokenNeverBecomesCurrentAgain() throws {
        var registry = EngineLeaseRegistry()
        var released: [EngineLeaseToken] = []
        for _ in 0..<4 {
            let token = try registry.acquire(project: projectA, window: windowA1).snapshot.token
            #expect(!released.contains(token))
            _ = try registry.release(expected: token)
            #expect(registry.snapshot == nil && registry.role(of: windowA1, project: projectA) == .stopped)
            #expect(throws: EngineLeaseError.notHeld) { try registry.release(expected: token) }
            released.append(token)
        }
        let current = try registry.acquire(project: projectA, window: windowA1).snapshot.token
        #expect(current.generation == (try Generation(5)))
        for token in released {
            #expect(token != current)
            #expect(throws: EngineLeaseError.staleToken) {
                try registry.attach(windowA2, project: projectA, expected: token)
            }
            #expect(throws: EngineLeaseError.staleToken) { try registry.release(expected: token) }
        }
    }
}
