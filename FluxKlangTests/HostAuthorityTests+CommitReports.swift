import Testing
@testable import FluxKlang

// The same host, draft and permission as the `TransactionBench` defaults.
private let hostEpoch = HostEpoch(host: HostID(validated: "host.transactions"), generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let graphID = GraphID(validated: "graph.main")
private let runningPlan = PreparedActivationID(validated: "prep.running")
private let planP = PreparedActivationID(validated: "prep.p")
private let planQ = PreparedActivationID(validated: "prep.q")
private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]

private func request(base: ContractRevision = .initial) -> ActivationRequest {
    ActivationRequest(draft: DraftID(validated: "draft.main"), graph: graphID, baseRevision: base, hostEpoch: hostEpoch,
                      permission: permission, digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human)
}

private func graph(revision: ContractRevision = .initial, nodes ids: [NodeID] = nodes) -> GraphDocument {
    GraphDocument(id: graphID, revision: revision, capabilities: [],
                  nodes: ids.map { GraphNode(id: $0, kind: .plugin, label: $0.rawValue) })
}

/// A one-device document whose free-text `evidence` is `evidence`.
private func capabilities(evidence: String,
                          identity: Set<IdentityEvidence> = [.deviceUID]) throws -> DeviceCapabilityDocument {
    let device = try DeviceDescriptor(
        id: DeviceID(validated: "dev.interface"), kind: .audioInterface,
        layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: .reported,
        identity: DeviceIdentity(.init(uid: "physical-interface-1", evidence: identity)), evidence: evidence
    )
    return try DeviceCapabilityDocument(revision: .initial, host: hostEpoch.host, hostEpoch: hostEpoch.generation,
                                        devices: [device], routes: [])
}

private func report(_ outcome: ActivationCommitOutcome, applied: Set<NodeID>, unapplied: Set<NodeID>,
                    prepared: PreparedActivationID = planP) -> CommitReportDraft {
    CommitReportDraft(prepared: prepared, outcome: outcome, applied: applied, unapplied: unapplied)
}

/// A commit report before the engine names the attempt it answers. Shared
/// with the Transactions suite: attempts cannot be forged, only echoed.
struct CommitReportDraft: Hashable, Sendable {
    let prepared: PreparedActivationID
    let outcome: ActivationCommitOutcome
    let applied: Set<NodeID>
    let unapplied: Set<NodeID>

    func report(for attempt: CommitAttemptID) -> ActivationCommitReport {
        ActivationCommitReport(prepared: prepared, attempt: attempt, outcome: outcome, applied: applied,
                               unapplied: unapplied)
    }
}

extension ActivationTransaction {
    /// Test shorthand: the engine's report on the latest commit attempt. With no
    /// attempt issued yet it refuses as the real transition would in that phase.
    mutating func acknowledged(_ draft: CommitReportDraft) -> Result<[ActivationEffect], ActivationRefusal> {
        guard let lastAttempt else { return .failure(.unexpectedPhase(phase)) }
        return acknowledged(draft.report(for: lastAttempt))
    }

    /// Test shorthand: the engine's answer to the latest `.prepare`, refusing like
    /// `acknowledged(_ draft:)` when none was issued.
    mutating func prepared(
        _ result: Result<PreparedActivationID, PrepareFailure>
    ) -> Result<[ActivationEffect], ActivationRefusal> {
        guard let lastPrepareAttempt else { return .failure(.unexpectedPhase(phase)) }
        return prepared(result, attempt: lastPrepareAttempt)
    }
}

extension TransactionBench {
    /// The single `.commit` effect expected for `prepared`: the current lease
    /// token and this transaction's latest attempt, which must be `generation`.
    func committed(_ prepared: PreparedActivationID, generation: Generation = .initial) throws -> [ActivationEffect] {
        let attempt = try #require(transaction.lastAttempt)
        #expect(attempt.generation == generation)
        return [.commit(prepared, attempt, try #require(registry.snapshot).token)]
    }

    /// Begins the default request at the initial revision, returning the attempt
    /// named by the single `.prepare` effect.
    fileprivate mutating func preparing() throws -> PrepareAttemptID {
        if registry.snapshot == nil { try acquire(transaction.project) }
        let effects = try begin(request(), candidate: graph())
        guard effects.count == 1, case .prepare(_, let attempt) = effects[0] else {
            Issue.record("Expected one prepare, got \(effects)")
            throw CancellationError()
        }
        return attempt
    }

    /// Reviews `ids` at the running revision as `prepared`, then authorizes and
    /// commits it, returning the attempt named by the single `.commit` effect.
    fileprivate mutating func attempt(_ prepared: PreparedActivationID,
                                      nodes ids: [NodeID] = nodes) throws -> CommitAttemptID {
        let base = transaction.running.revision
        activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: base, permission: permission,
                                       capabilities: activation.capabilities)
        if registry.snapshot == nil { try acquire(transaction.project) }
        try review(request(base: base), candidate: graph(revision: base, nodes: ids), as: prepared)
        let effects = try commit(try authorize()).get()
        let token = try #require(registry.snapshot).token
        guard effects.count == 1, case .commit(prepared, let attempt, token) = effects[0] else {
            Issue.record("Expected one commit of \(prepared), got \(effects)")
            throw CancellationError()
        }
        return attempt
    }
}

extension HostAuthorityTests {
    struct CommitReports {
        @Test func duplicateReportOfReusedPreparedIDIsStale() throws {
            var host = try TransactionBench()
            let first = try host.attempt(planP)
            let delivered = report(.succeeded, applied: Set(nodes), unapplied: []).report(for: first)
            #expect(try host.transaction.acknowledged(delivered).get() == [.discard(runningPlan)])
            let second = try host.attempt(planQ)
            let toQ = report(.succeeded, applied: Set(nodes), unapplied: [], prepared: planQ).report(for: second)
            #expect(try host.transaction.acknowledged(toQ).get() == [.discard(planP)])
            // The engine reuses P's ID; same nodes, so only the attempt tells the reports apart.
            let third = try host.attempt(planP)
            #expect(second.generation == (try first.generation.next()) && first != second)
            #expect(third.generation == (try second.generation.next()) && first != third)
            let twoAcknowledged = try ContractRevision.initial.next().next()
            #expect(host.transaction.running == RunningGraph(revision: twoAcknowledged, prepared: planQ))
            // A delayed duplicate of the first report changes nothing and emits nothing.
            #expect(host.refusal { $0.acknowledged(delivered) } == .staleReport)
            #expect(host.transaction.phase == .committing && host.transaction.running.prepared == planQ)
            let current = report(.succeeded, applied: Set(nodes), unapplied: []).report(for: third)
            #expect(try host.transaction.acknowledged(current).get() == [.discard(planQ)])
            #expect(host.transaction.running == RunningGraph(revision: try twoAcknowledged.next(), prepared: planP))
        }

        @Test func reportFromAnotherTransactionIsStale() throws {
            var old = try TransactionBench()
            let oldFirst = try old.attempt(planP)
            // A new transaction (another project, recovery or reopening) commits the same P as its first attempt.
            var current = try TransactionBench()
            let first = try current.attempt(planP)
            #expect(first.generation == oldFirst.generation && first != oldFirst)
            let late = report(.succeeded, applied: Set(nodes), unapplied: []).report(for: oldFirst)
            #expect(current.refusal { $0.acknowledged(late) } == .staleReport)
            #expect(current.transaction.phase == .committing)
            #expect(current.transaction.running == RunningGraph(revision: .initial, prepared: runningPlan))
            let own = report(.succeeded, applied: Set(nodes), unapplied: []).report(for: first)
            #expect(try current.transaction.acknowledged(own).get() == [.discard(runningPlan)])
        }

        @Test(arguments: [Result<PreparedActivationID, PrepareFailure>.success(planP), .failure(.engineRefused)])
        func delayedPrepareResponseAfterCancelIsStale(delayed: Result<PreparedActivationID, PrepareFailure>) throws {
            var host = try TransactionBench()
            let first = try host.preparing()
            _ = try host.transaction.prepared(.success(planP), attempt: first).get()
            #expect(try host.transaction.cancel().get() == [.discard(planP)])
            let retry = try host.preparing()
            #expect(retry.generation == (try first.generation.next()) && retry != first)
            // A's delayed success or failure neither names B's plan nor ends B's preparation.
            #expect(host.refusal { $0.prepared(delayed, attempt: first) } == .stalePrepareResponse)
            #expect(host.transaction.phase == .preparing)
            _ = try host.transaction.prepared(.success(planQ), attempt: retry).get()
            #expect(try host.commit(try host.authorize()).get() == (try host.committed(planQ)))
        }

        @Test func duplicatePrepareResponseIsRefused() throws {
            var host = try TransactionBench()
            let attempt = try host.preparing()
            _ = try host.transaction.prepared(.success(planP), attempt: attempt).get()
            #expect(host.refusal { $0.prepared(.success(planQ), attempt: attempt) }
                == .unexpectedPhase(.awaitingReview))
            #expect(host.refusal { $0.prepared(.failure(.cancelled), attempt: attempt) }
                == .unexpectedPhase(.awaitingReview))
            #expect(try host.commit(try host.authorize()).get() == (try host.committed(planP)))
        }

        @Test func staleSuccessNamingRunningPlanIsStaleNotInUse() throws {
            var host = try TransactionBench()
            let first = try host.preparing()
            _ = try host.transaction.prepared(.failure(.engineRefused), attempt: first).get()
            let retry = try host.preparing()
            // Attempt before content: the stale answer is refused as stale, not as `preparedIDInUse`.
            #expect(host.refusal { $0.prepared(.success(runningPlan), attempt: first) } == .stalePrepareResponse)
            #expect(host.transaction.phase == .preparing && host.transaction.lastPrepareAttempt == retry)
        }

        @Test func prepareResponseFromAnotherTransactionIsStale() throws {
            var other = try TransactionBench()
            let foreign = try other.preparing()
            var host = try TransactionBench()
            let own = try host.preparing()
            #expect(own.generation == foreign.generation && own != foreign)
            #expect(host.refusal { $0.prepared(.success(planP), attempt: foreign) } == .stalePrepareResponse)
            #expect(host.refusal { $0.prepared(.failure(.engineRefused), attempt: foreign) } == .stalePrepareResponse)
            _ = try host.transaction.prepared(.success(planQ), attempt: own).get()
            #expect(host.transaction.phase == .awaitingReview && host.transaction.validated != nil)
        }

        @Test func prepareAttemptOverflowIsRefused() throws {
            var host = try TransactionBench()
            let last = try Generation(Generation.maximumValue)
            let running = host.transaction.running
            host.transaction = ActivationTransaction(project: host.transaction.project, running: running,
                                                     resumingAfterPrepareAttempt: last)
            let live = try host.live
            #expect(host.refusal { $0.begin(request(), candidate: graph(), in: live) } == .overflow)
            #expect(host.transaction.phase == .idle && host.transaction.lastPrepareAttempt?.generation == last)
        }

        @Test(arguments: [[NodeID](), nodes])
        func failedCommitKeepsRunningGraphAndRevision(planned: [NodeID]) throws {
            var host = try TransactionBench()
            _ = try host.attempt(planP, nodes: planned)
            let before = host.transaction.running
            let failed = report(.failed, applied: [], unapplied: Set(planned))
            #expect(try host.transaction.acknowledged(failed).get().isEmpty)
            #expect(host.transaction.phase == .commitFailed(planP) && host.transaction.running == before)
            #expect(before == RunningGraph(revision: .initial, prepared: runningPlan))
            // Recovery (H4) must resolve the failure before another activation begins.
            let live = try host.live
            #expect(host.refusal { $0.begin(request(), candidate: graph(), in: live) }
                == .unexpectedPhase(.commitFailed(planP)))
        }

        @Test func emptyGraphActivatesOnlyOnSuccess() throws {
            var host = try TransactionBench()
            _ = try host.attempt(planP, nodes: [])
            // Nothing can be both applied and unapplied, so an empty plan cannot be partial.
            #expect(host.refusal { $0.acknowledged(report(.partial, applied: [], unapplied: [])) } == .reportMismatch)
            let succeeded = report(.succeeded, applied: [], unapplied: [])
            #expect(try host.transaction.acknowledged(succeeded).get() == [.discard(runningPlan)])
            let next = try ContractRevision.initial.next()
            #expect(host.transaction.running == RunningGraph(revision: next, prepared: planP))
            #expect(host.transaction.phase == .acknowledged(next))
        }

        @Test(arguments: [report(.succeeded, applied: [nodes[0]], unapplied: [nodes[1], nodes[2]]),
                          report(.failed, applied: Set(nodes), unapplied: []),
                          report(.failed, applied: [nodes[0]], unapplied: [nodes[1], nodes[2]]),
                          report(.partial, applied: Set(nodes), unapplied: []),
                          report(.partial, applied: [], unapplied: Set(nodes))])
        func outcomeMustAgreeWithNodeSets(mismatched: CommitReportDraft) throws {
            var host = try TransactionBench()
            _ = try host.attempt(planP)
            let before = host.transaction.running
            #expect(host.refusal { $0.acknowledged(mismatched) } == .reportMismatch)
            #expect(host.transaction.phase == .committing && host.transaction.running == before)
        }

        /// `count` × U+00E9 reviewed; the live document has the decomposed twin (e + U+0301),
        /// equal under `String ==`. At 1.5M the twin's encoding crosses the 4 MiB limit.
        @Test(arguments: [1, 1_500_000])
        func capabilityTextIsComparedByEncodedBytes(count: Int) throws {
            let reviewed = try capabilities(evidence: String(repeating: "\u{E9}", count: count))
            let twin = try capabilities(evidence: String(repeating: "e\u{301}", count: count))
            let liveBytes = try? twin.encoded()
            let reviewedBytes = try reviewed.encoded()
            #expect(twin == reviewed && liveBytes != reviewedBytes)
            #expect((liveBytes == nil) == (count > 1))
            var host = try TransactionBench()
            host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial,
                                                permission: permission, capabilities: reviewed)
            try host.acquire(host.transaction.project)
            try host.review(request(), candidate: graph(), as: planP)
            let authorization = try host.authorize()
            let reviewedContext = host.activation
            host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial,
                                                permission: permission, capabilities: twin)
            let changed = try host.live
            let lease = host.registry.snapshot
            #expect(host.refusal { $0.commit(authorization, lease: lease, context: changed) } == .staleContext)
            #expect(host.transaction.phase == .awaitingReview && host.transaction.lastAttempt == nil)
            // The reviewed bytes themselves still commit.
            host.activation = reviewedContext
            let effects = try host.commit(authorization).get()
            #expect(effects == (try host.committed(planP)))
        }

        /// The live document is the reviewed one decoded from its bytes, or rebuilt
        /// with an equal identity-evidence set in another order and capacity. Each
        /// must commit: byte-exact staleness needs a canonical encoding.
        @Test func decodedOrRebuiltCapabilityTwinCommits() throws {
            let kinds: [IdentityEvidence] = [.deviceUID, .endpointUID, .transport, .channelLayout, .modelUID]
            let reviewed = try capabilities(evidence: "probe", identity: Set(kinds))
            for trial in 0..<8 {
                var rebuilt = Set<IdentityEvidence>(minimumCapacity: 8 * (trial + 1))
                for kind in kinds.reversed() { rebuilt.insert(kind) }
                let twin = try trial.isMultiple(of: 2)
                    ? DeviceCapabilityDocument.decode(from: reviewed.encoded())
                    : capabilities(evidence: "probe", identity: rebuilt)
                #expect(twin == reviewed)
                var host = try TransactionBench()
                host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial,
                                                    permission: permission, capabilities: reviewed)
                try host.acquire(host.transaction.project)
                try host.review(request(), candidate: graph(), as: planP)
                let authorization = try host.authorize()
                host.activation = ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial,
                                                    permission: permission, capabilities: twin)
                let effects = try host.commit(authorization).get()
                #expect(effects == (try host.committed(planP)))
            }
        }

        @Test func commitAttemptOverflowIsRefused() throws {
            var host = try TransactionBench()
            let last = try Generation(Generation.maximumValue)
            let running = host.transaction.running
            host.transaction = ActivationTransaction(project: host.transaction.project, running: running,
                                                     resumingAfterAttempt: last)
            try host.reviewing(request(), candidate: graph())
            let authorization = try host.authorize()
            let live = try host.live
            let lease = host.registry.snapshot
            #expect(host.refusal { $0.commit(authorization, lease: lease, context: live) } == .overflow)
            #expect(host.transaction.phase == .awaitingReview && host.transaction.lastAttempt?.generation == last)
            #expect(host.transaction.authorizer.outstanding == authorization)
        }
    }
}
