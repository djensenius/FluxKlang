import Foundation
import Testing
@testable import FluxKlang

private let host = HostID(validated: "host.transactions")
private let hostEpoch = HostEpoch(host: host, generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let oldPermission = PermissionFingerprint(rawValue: "permissions.old")
private let graphID = GraphID(validated: "graph.main")
private let audio = CapabilityID(validated: "cap.audio")
private let draftID = DraftID(validated: "draft.main")
private let digest = ActivationDigest(rawValue: "sha256:activation")
private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let windowA = WindowID(validated: "win.a1")
private let windowB = WindowID(validated: "win.b1")
private let planID = PreparedActivationID(validated: "prep.next")
private let runningPlan = PreparedActivationID(validated: "prep.running")
private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]

private func otherEpoch() throws -> HostEpoch { HostEpoch(host: host, generation: try Generation.initial.next()) }

private func capabilities(epoch: HostEpoch = hostEpoch,
                          presence: DevicePresence = .present) throws -> DeviceCapabilityDocument {
    let device = try DeviceDescriptor(
        id: DeviceID(validated: "dev.interface"), kind: .audioInterface,
        layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: .reported,
        identity: DeviceIdentity(.init(uid: "physical-interface-1", evidence: [.deviceUID])),
        presence: presence, capabilities: [audio]
    )
    return try DeviceCapabilityDocument(revision: .initial, host: epoch.host, hostEpoch: epoch.generation,
                                        devices: [device], routes: [])
}

private func candidate(revision: ContractRevision = .initial, id: GraphID = graphID,
                       requiresReview: Bool = false) -> GraphDocument {
    GraphDocument(id: id, revision: revision, capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
                  nodes: [GraphNode(id: nodes[0], kind: .plugin, label: "FX", requiredCapabilities: [audio]),
                          GraphNode(id: nodes[1], kind: .plugin, label: "EQ"),
                          GraphNode(id: nodes[2], kind: .plugin, label: "Out")],
                  requiresReview: requiresReview)
}

private func request(draft: DraftID = draftID, base: ContractRevision = .initial, epoch: HostEpoch = hostEpoch,
                     digest requested: ActivationDigest = digest, origin: CommandOrigin = .human) -> ActivationRequest {
    ActivationRequest(draft: draft, graph: graphID, baseRevision: base, hostEpoch: epoch, permission: permission,
                      digest: requested, origin: origin)
}

private func request(permission granted: PermissionFingerprint) -> ActivationRequest {
    ActivationRequest(draft: draftID, graph: graphID, baseRevision: .initial, hostEpoch: hostEpoch,
                      permission: granted, digest: digest, origin: .human)
}

private func report(applied: Set<NodeID> = Set(nodes), unapplied: Set<NodeID> = [],
                    outcome: ActivationCommitOutcome = .succeeded,
                    prepared: PreparedActivationID = planID) -> CommitReportDraft {
    CommitReportDraft(prepared: prepared, outcome: outcome, applied: applied, unapplied: unapplied)
}

private func failure<Success>(_ result: Result<Success, ActivationRefusal>) -> ActivationRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

private typealias Bench = TransactionBench

/// One host: a lease registry, its ledger and one project's transaction.
struct TransactionBench {
    var registry = EngineLeaseRegistry()
    var ledger: GenerationLedger
    var transaction: ActivationTransaction
    var activation: ActivationContext

    init(revision: ContractRevision = .initial, epoch: HostEpoch = hostEpoch, nonce: Generation? = nil,
         running prepared: PreparedActivationID? = runningPlan, permission granted: PermissionFingerprint = permission)
    throws {
        ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.main"), musicalClock: nil,
                                      nominalRate: 48_000, declaring: [EngineLeaseRegistry.contextKey])
        transaction = ActivationTransaction(project: projectA, running: RunningGraph(revision: revision,
                                                                                     prepared: prepared),
                                            resumingAfterNonce: nonce)
        activation = ActivationContext(hostEpoch: epoch, activeRevision: revision, permission: granted,
                                       capabilities: try capabilities(epoch: epoch))
    }

    var live: ActivationLiveContext {
        get throws {
            ActivationLiveContext(activation: activation,
                                  engine: try #require(ledger.generation(EngineLeaseRegistry.contextKey)))
        }
    }

    mutating func acquire(_ project: ProjectID, window: WindowID = windowA) throws {
        let grant = try registry.acquire(project: project, window: window)
        try grant.context.apply(to: &ledger)
    }

    mutating func begin(_ request: ActivationRequest = request(),
                        candidate document: GraphDocument = candidate()) throws -> [ActivationEffect] {
        try transaction.begin(request, candidate: document, in: live).get()
    }

    /// Begins `request` and has the engine prepare it as `id`.
    mutating func review(_ request: ActivationRequest = request(), candidate document: GraphDocument = candidate(),
                         as id: PreparedActivationID = planID) throws {
        _ = try begin(request, candidate: document)
        _ = try transaction.prepared(.success(id)).get()
        #expect(transaction.phase == .awaitingReview)
    }

    mutating func authorize() throws -> ActivationAuthorization {
        try transaction.authorize(origin: .human, permission: permission).get()
    }

    /// Acquires the lease for project A and reviews `request`.
    mutating func reviewing(_ request: ActivationRequest = request(),
                            candidate document: GraphDocument = candidate()) throws {
        try acquire(projectA)
        try review(request, candidate: document)
    }

    /// Runs `step` and returns its refusal, expecting a refusal to leave the transaction unchanged.
    mutating func refusal<Success>(
        _ step: (inout ActivationTransaction) throws -> Result<Success, ActivationRefusal>
    ) rethrows -> ActivationRefusal? {
        let before = transaction
        guard case .failure(let refusal) = try step(&transaction) else { return nil }
        #expect(transaction == before)
        return refusal
    }

    /// `reviewing()`, then authorizes and commits.
    mutating func committing() throws {
        try reviewing()
        _ = try commit(try authorize()).get()
    }

    mutating func commit(_ authorization: ActivationAuthorization) throws -> Result<[ActivationEffect],
                                                                                     ActivationRefusal> {
        transaction.commit(authorization, lease: registry.snapshot, context: try live)
    }
}

/// Every H1 rejection, reached through `begin` with otherwise current inputs.
enum RejectedBegin: CaseIterable, Sendable {
    case staleHostEpoch, permissionDenied, permissionChanged, assistantOrigin, controllerOrigin, invalidDigest
    case staleBase, graphMismatch, invalidGraph, invalidCapabilities, missingCapabilities, staleCapabilities
}

// iOS's `FluxKlangTests` type shadows the module name, so these defaults avoid module-qualified calls.
private func currentRequest() -> ActivationRequest { request() }
private func currentCandidate() -> GraphDocument { candidate() }

private struct RejectedAttempt {
    let rejection: ActivationRejection
    var request = currentRequest()
    var candidate = currentCandidate()
}

extension RejectedBegin {
    /// The request and candidate that cause this rejection, if the request is at fault.
    fileprivate func faultyAttempt() throws -> RejectedAttempt? {
        let found = try ContractRevision.initial.next()
        switch self {
        case .staleHostEpoch:
            return RejectedAttempt(rejection: .staleHostEpoch, request: request(epoch: try otherEpoch()))
        case .assistantOrigin, .controllerOrigin:
            let origin: CommandOrigin = self == .assistantOrigin ? .assistant : .controller
            return RejectedAttempt(rejection: .originCannotActivate(origin), request: request(origin: origin))
        case .invalidDigest:
            return RejectedAttempt(rejection: .invalidDigest,
                                   request: request(digest: ActivationDigest(rawValue: "")))
        case .staleBase:
            return RejectedAttempt(rejection: .staleBase(expected: .initial, found: found),
                                   request: request(base: found))
        case .graphMismatch:
            return RejectedAttempt(rejection: .graphMismatch,
                                   candidate: candidate(id: GraphID(validated: "graph.other")))
        case .invalidGraph:
            return RejectedAttempt(rejection: .invalidGraph(.reviewRequired),
                                   candidate: candidate(requiresReview: true))
        default: return nil
        }
    }

    /// The live context that causes this rejection, if the context is at fault.
    fileprivate func context() throws -> (context: ActivationContext, rejection: ActivationRejection)? {
        var offered = try capabilities()
        var current: PermissionFingerprint? = permission
        let expected: ActivationRejection
        switch self {
        case .permissionDenied: current = nil; expected = .permissionDenied
        case .permissionChanged: current = oldPermission; expected = .permissionChanged
        case .invalidCapabilities: offered.devices[0].binding = .measured; expected = .invalidCapabilities
        case .missingCapabilities:
            offered = try capabilities(presence: .missing); expected = .missingCapabilities([audio])
        case .staleCapabilities: offered = try capabilities(epoch: try otherEpoch()); expected = .staleCapabilities
        default: return nil
        }
        return (ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial, permission: current,
                                  capabilities: offered), expected)
    }
}

/// The authorization binding that differs between two otherwise identical transactions.
enum AuthorizationBinding: CaseIterable, Sendable { case draft, base, epoch, digest }

extension HostAuthorityTests {
    struct Transactions {
        @Test func failedPrepareKeepsRunningGraphAndRevision() throws {
            var host = try Bench()
            try host.acquire(projectA)
            let running = host.transaction.running
            let effects = try host.begin()
            let attempt = try #require(host.transaction.lastPrepareAttempt)
            #expect(effects == [.prepare(try #require(host.transaction.validated), attempt)])
            #expect(host.transaction.phase == .preparing && host.transaction.running == running)
            #expect(try host.transaction.prepared(.failure(.capabilityLost(audio))).get().isEmpty)
            #expect(host.transaction.phase == .prepareFailed(.capabilityLost(audio)))
            #expect(host.transaction.running == running && host.transaction.validated == nil)
            #expect(running == RunningGraph(revision: .initial, prepared: runningPlan))
            #expect(host.refusal { $0.authorize(origin: .human, permission: permission) }
                == .unexpectedPhase(.prepareFailed(.capabilityLost(audio))))
            #expect(host.refusal { $0.prepared(.success(planID)) }
                == .unexpectedPhase(.prepareFailed(.capabilityLost(audio))))
            // A new attempt may start over the unchanged running graph.
            try host.review()
            #expect(host.transaction.running == running)
        }

        @Test(arguments: RejectedBegin.allCases)
        func invalidRequestsEmitNoEffects(rejected: RejectedBegin) throws {
            var host = try Bench()
            try host.acquire(projectA)
            let attempt = try rejected.faultyAttempt()
            let contextual = try rejected.context()
            host.activation = contextual?.context ?? host.activation
            let expected = try #require(attempt?.rejection ?? contextual?.rejection)
            let live = try host.live
            #expect(host.refusal {
                $0.begin(attempt?.request ?? request(), candidate: attempt?.candidate ?? candidate(), in: live)
            } == .rejected(expected))
            // Nothing was prepared, so nothing can be authorized or committed.
            #expect(host.refusal { $0.authorize(origin: .human, permission: permission) } == .unexpectedPhase(.idle))
        }

        @Test func contextNotOnRunningRevisionIsStale() throws {
            var host = try Bench()
            let ahead = try ContractRevision.initial.next()
            host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: ahead, permission: permission,
                                                capabilities: try capabilities())
            let live = try host.live
            #expect(host.refusal { $0.begin(request(base: ahead), candidate: candidate(revision: ahead), in: live) }
                == .staleContext)
        }

        @Test func noCommitEffectBeforeAuthorization() throws {
            var other = try Bench()
            try other.reviewing()
            let foreign = try other.authorize()

            var host = try Bench()
            try host.acquire(projectA)
            let effects = try host.begin()
            #expect(effects.allSatisfy { if case .prepare = $0 { true } else { false } } && effects.count == 1)
            #expect(failure(try host.commit(foreign)) == .unexpectedPhase(.preparing))
            #expect(failure(host.transaction.authorize(origin: .human, permission: permission))
                == .unexpectedPhase(.preparing))
            _ = try host.transaction.prepared(.success(planID)).get()
            let reviewing = host.transaction
            // Under review but not authorized here: an authorization from elsewhere is not enough.
            #expect(failure(try host.commit(foreign)) == .authorizationInvalid(.noneOutstanding))
            #expect(host.transaction == reviewing && host.transaction.authorizer.lastNonce == nil)
            let own = try host.authorize()
            #expect(own.nonce == .initial)
            #expect(try host.commit(own).get() == (try host.committed(planID)))
            #expect(host.transaction.phase == .committing)
        }

        @Test func authorizationIsSingleUse() throws {
            var host = try Bench()
            try host.reviewing()
            let first = try host.authorize()
            let second = try host.authorize()
            let two = try Generation.initial.next()
            #expect(first.nonce == .initial && second.nonce == two)
            #expect(first != second)
            // Re-authorizing replaced the first.
            let reviewing = host.transaction
            #expect(failure(try host.commit(first)) == .authorizationInvalid(.notOutstanding))
            #expect(host.transaction == reviewing)
            // A twin transaction issuing the same fields and nonce cannot stand in for it.
            var twin = try Bench()
            try twin.reviewing()
            _ = try twin.authorize()
            let forged = try twin.authorize()
            #expect(forged.nonce == second.nonce && forged.draft == second.draft && forged != second)
            #expect(failure(try host.commit(forged)) == .authorizationInvalid(.notOutstanding))

            _ = try host.commit(second).get()
            #expect(failure(try host.commit(second)) == .unexpectedPhase(.committing))
            _ = try host.transaction.acknowledged(report()).get()
            // The next activation, based on the new revision, does not accept the used authorization.
            let next = host.transaction.running.revision
            host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: next, permission: permission,
                                                capabilities: try capabilities())
            try host.review(request(base: next), candidate: candidate(revision: next), as: runningPlan)
            #expect(failure(try host.commit(second)) == .authorizationInvalid(.noneOutstanding))
            let third = try host.authorize()
            #expect(failure(try host.commit(second)) == .authorizationInvalid(.baseRevision))
            #expect(third.nonce == (try two.next()))
            #expect(try host.commit(third).get().count == 1)
        }

        @Test(arguments: AuthorizationBinding.allCases)
        func draftBaseEpochOrDigestChangeInvalidatesAuthorization(binding: AuthorizationBinding) throws {
            var original = try Bench()
            try original.reviewing()
            let stale = try original.authorize()

            let next = try ContractRevision.initial.next()
            let epoch = binding == .epoch ? try otherEpoch() : hostEpoch
            var changed = try Bench(revision: binding == .base ? next : .initial, epoch: epoch)
            try changed.acquire(projectA)
            let expected: AuthorizationDefect
            switch binding {
            case .draft:
                try changed.review(request(draft: DraftID(validated: "draft.other"))); expected = .draft
            case .base:
                try changed.review(request(base: next), candidate: candidate(revision: next)); expected = .baseRevision
            case .epoch:
                try changed.review(request(epoch: epoch)); expected = .hostEpoch
            case .digest:
                try changed.review(request(digest: ActivationDigest(rawValue: "sha256:other"))); expected = .digest
            }
            let current = try changed.authorize()
            // Same nonce in both transactions: only the changed binding tells them apart.
            #expect(current.nonce == stale.nonce)
            let reviewing = changed.transaction
            #expect(failure(try changed.commit(stale)) == .authorizationInvalid(expected))
            #expect(changed.transaction == reviewing)
            #expect(try changed.commit(current).get() == (try changed.committed(planID)))
        }

        @Test(arguments: [CommandOrigin.assistant, .controller])
        func assistantOrControllerCannotAuthorize(origin: CommandOrigin) throws {
            var host = try Bench()
            try host.reviewing()
            #expect(host.refusal { $0.authorize(origin: origin, permission: permission) }
                == .rejected(.originCannotActivate(origin)))
            // A human gesture still needs the live, matching permission.
            #expect(host.refusal { $0.authorize(origin: .human, permission: nil) } == .rejected(.permissionDenied))
            #expect(host.refusal { $0.authorize(origin: .human, permission: oldPermission) }
                == .rejected(.permissionChanged))
            #expect(host.transaction.authorizer.outstanding == nil)
            // The request's asserted origin cannot be borrowed by a non-human gesture.
            #expect(host.transaction.validated?.request.origin == .human)
            let granted = try host.authorize()
            #expect(granted.nonce == .initial && host.transaction.authorizer.outstanding == granted)
        }

        @Test func commitWithoutCurrentLeaseEmitsNoWrites() throws {
            var host = try Bench()
            try host.review()
            let authorization = try host.authorize()
            let reviewing = host.transaction
            #expect(failure(try host.commit(authorization)) == .leaseNotHeld)
            #expect(host.transaction == reviewing)

            var other = try Bench()
            try other.acquire(projectB, window: windowB)
            try other.review()
            let held = try other.authorize()
            let otherReviewing = other.transaction
            #expect(failure(try other.commit(held)) == .leaseHeldByOtherProject(projectB))
            #expect(other.transaction == otherReviewing)
            // The current lease for this project lets the same authorization through.
            var owner = try Bench()
            try owner.reviewing()
            #expect(try owner.commit(try owner.authorize()).get() == (try owner.committed(planID)))
        }

        @Test func acknowledgeAdvancesRevisionByOne() throws {
            let base = try ContractRevision(41)
            var host = try Bench(revision: base)
            try host.reviewing(request(base: base), candidate: candidate(revision: base))
            _ = try host.commit(try host.authorize()).get()
            #expect(host.transaction.running == RunningGraph(revision: base, prepared: runningPlan))
            #expect(host.refusal { $0.acknowledged(report(prepared: runningPlan)) } == .reportMismatch)
            let effects = try host.transaction.acknowledged(report()).get()
            let expected = try ContractRevision(42)
            #expect(host.transaction.running == RunningGraph(revision: expected, prepared: planID))
            #expect(host.transaction.phase == .acknowledged(expected) && effects == [.discard(runningPlan)])
            #expect(host.refusal { $0.acknowledged(report()) } == .unexpectedPhase(.acknowledged(expected)))
        }

        @Test func partialCommitListsUnapplied() throws {
            var host = try Bench()
            try host.committing()
            let partial = report(applied: [nodes[0]], unapplied: [nodes[1], nodes[2]], outcome: .partial)
            #expect(try host.transaction.acknowledged(partial).get().isEmpty)
            #expect(host.transaction.phase == .partial(planID, applied: [nodes[0]], unapplied: [nodes[1], nodes[2]]))
            #expect(host.transaction.running == RunningGraph(revision: .initial, prepared: runningPlan))
            // Recovery (H4) must resolve a partial commit before another activation begins.
            let live = try host.live
            #expect(host.refusal { $0.begin(request(), candidate: candidate(), in: live) }
                == .unexpectedPhase(host.transaction.phase))
        }

        @Test(arguments: [report(applied: [], unapplied: []), report(applied: [nodes[0]], unapplied: [nodes[1]]),
                          report(applied: [nodes[0]], unapplied: [nodes[0], nodes[1], nodes[2]]),
                          report(applied: Set(nodes).union([NodeID(validated: "node.extra")]))])
        func commitReportMustAccountForEveryPlannedNode(mismatched: CommitReportDraft) throws {
            var host = try Bench()
            try host.committing()
            #expect(host.refusal { $0.acknowledged(mismatched) } == .reportMismatch)
        }

        @Test func preparedIDOfRunningGraphIsRefused() throws {
            var host = try Bench()
            _ = try host.begin()
            #expect(host.refusal { $0.prepared(.success(runningPlan)) } == .preparedIDInUse)
            #expect(host.transaction.phase == .preparing)
        }

        @Test(arguments: [PermissionFingerprint(rawValue: "permissions.cafe\u{301}"),
                          PermissionFingerprint(rawValue: String(repeating: "e\u{301}", count: 100))])
        func permissionIsComparedByteForByte(live: PermissionFingerprint) throws {
            // Canonically equal to `live` under `String ==`, but different UTF-8 bytes.
            let granted = PermissionFingerprint(rawValue: live.rawValue.precomposedStringWithCanonicalMapping)
            #expect(granted == live && !granted.matchesExactly(live) && granted.isWellFormedForActivation)
            let expected: ActivationRejection = live.isWellFormedForActivation ? .permissionChanged : .permissionDenied
            var host = try Bench(permission: granted)
            try host.reviewing(request(permission: granted))
            #expect(host.refusal { $0.authorize(origin: .human, permission: live) } == .rejected(expected))
            let authorization = try host.transaction.authorize(origin: .human, permission: granted).get()
            host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial, permission: live,
                                                capabilities: try capabilities())
            let changed = try host.live
            let lease = host.registry.snapshot
            #expect(host.refusal { $0.commit(authorization, lease: lease, context: changed) } == .staleContext)
        }

        @Test func preparedPlanIsStaleAfterContextChange() throws {
            var host = try Bench()
            try host.reviewing()
            let authorization = try host.authorize()
            // Release and re-acquire by the same project: each lease change bumps ctx.engine.
            let token = try #require(host.registry.snapshot).token
            try host.registry.release(expected: token).apply(to: &host.ledger)
            try host.acquire(projectA)
            let reviewing = host.transaction
            #expect(failure(try host.commit(authorization)) == .staleContext)
            #expect(host.transaction == reviewing)

            var changed = try Bench()
            try changed.reviewing()
            let granted = try changed.authorize()
            let validatedIn = changed.activation
            changed.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial,
                                                   permission: oldPermission, capabilities: try capabilities())
            #expect(failure(try changed.commit(granted)) == .staleContext)
            changed.activation = validatedIn
            #expect(try changed.commit(granted).get().count == 1)
            // A stale plan is withdrawn with a discard, never committed.
            #expect(try host.transaction.cancel().get() == [.discard(planID)])
            #expect(host.transaction.phase == .idle && host.transaction.authorizer.outstanding == nil)
            #expect(failure(try host.commit(authorization)) == .unexpectedPhase(.idle))
        }

        @Test func beginWhileInFlightIsBusy() throws {
            var host = try Bench()
            try host.acquire(projectA)
            _ = try host.begin()
            let live = try host.live
            for step in 0..<3 {
                #expect(host.refusal { $0.begin(request(), candidate: candidate(), in: live) } == .busy)
                if step == 0 { _ = try host.transaction.prepared(.success(planID)).get() }
                if step == 1 { _ = try host.commit(try host.authorize()).get() }
            }
        }

        @Test func nonceAndRevisionOverflowAreRefused() throws {
            let maximum = try Generation(Generation.maximumValue)
            var exhausted = try Bench(nonce: maximum)
            try exhausted.reviewing()
            #expect(exhausted.refusal { $0.authorize(origin: .human, permission: permission) } == .overflow)

            let last = try ContractRevision(ContractRevision.maximumValue)
            var full = try Bench(revision: last)
            try full.reviewing(request(base: last), candidate: candidate(revision: last))
            _ = try full.commit(try full.authorize()).get()
            // Left committing for H4 recovery: the engine applied a plan the revision cannot name.
            #expect(full.refusal { $0.acknowledged(report()) } == .overflow)
            #expect(full.transaction.phase == .committing)
        }
    }
}
