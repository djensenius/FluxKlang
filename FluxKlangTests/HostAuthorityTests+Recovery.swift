import Testing
@testable import FluxKlang

// The same host, draft, permission and plan IDs as the `TransactionBench` defaults.
private let hostEpoch = HostEpoch(host: HostID(validated: "host.transactions"), generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let graphID = GraphID(validated: "graph.main")
private let audio = CapabilityID(validated: "cap.audio")
private let meter = CapabilityID(validated: "cap.meter")
private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let windowA = WindowID(validated: "win.a1")
private let windowB = WindowID(validated: "win.b1")
private let planID = PreparedActivationID(validated: "prep.next")
private let runningPlan = PreparedActivationID(validated: "prep.running")
private let value = ParameterValue(value: 0.5, unit: .normalized)
private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]
private let liveParameter = ParameterID(validated: "parameter.live")
private let draftID = DraftID(validated: "draft.main")

/// One case per `EngineLifecycle` case; `init(_:)` has no `default`, so a new lifecycle fails to compile here.
private enum LifecycleKind: CaseIterable {
    case stopped, preparing, running, degraded, recovering, heldByOther

    init(_ lifecycle: EngineLifecycle) {
        switch lifecycle {
        case .stopped: self = .stopped
        case .preparing: self = .preparing
        case .running: self = .running
        case .degraded: self = .degraded
        case .recovering: self = .recovering
        case .heldByOther: self = .heldByOther
        }
    }

    var lifecycle: EngineLifecycle {
        switch self {
        case .stopped: .stopped
        case .preparing: .preparing(.initial)
        case .running: .running
        case .degraded: .degraded([audio])
        case .recovering: .recovering
        case .heldByOther: .heldByOther(projectB)
        }
    }
}

private let lifecycles = LifecycleKind.allCases.map(\.lifecycle)
/// Hard-coded: the lifecycles in which the running set must not change.
private let blocking: [EngineLifecycle] = [.recovering, .heldByOther(projectB)]

/// One case per `RecoveryEvent` case, exhaustive like `LifecycleKind`.
private enum EventKind: CaseIterable {
    case commitFailed, partialCommit, commitOutcomeUnknown, revisionOverflow, processorCrashed, leaseLost
    case capabilityLost

    init(_ event: RecoveryEvent) {
        switch event {
        case .commitFailed: self = .commitFailed
        case .partialCommit: self = .partialCommit
        case .commitOutcomeUnknown: self = .commitOutcomeUnknown
        case .revisionOverflow: self = .revisionOverflow
        case .processorCrashed: self = .processorCrashed
        case .leaseLost: self = .leaseLost
        case .capabilityLost: self = .capabilityLost
        }
    }

    var event: RecoveryEvent {
        switch self {
        case .commitFailed: .commitFailed
        case .partialCommit: .partialCommit
        case .commitOutcomeUnknown: .commitOutcomeUnknown
        case .revisionOverflow: .revisionOverflow
        case .processorCrashed: .processorCrashed(nodes[0])
        case .leaseLost: .leaseLost
        case .capabilityLost: .capabilityLost(audio)
        }
    }
}

private func request(base: ContractRevision = .initial) -> ActivationRequest {
    ActivationRequest(draft: draftID, graph: graphID, baseRevision: base, hostEpoch: hostEpoch,
                      permission: permission, digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human)
}

private func candidate(revision: ContractRevision = .initial) -> GraphDocument {
    GraphDocument(id: graphID, revision: revision, capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
                  nodes: [GraphNode(id: nodes[0], kind: .plugin, label: "FX", requiredCapabilities: [audio]),
                          GraphNode(id: nodes[1], kind: .plugin, label: "EQ"),
                          GraphNode(id: nodes[2], kind: .plugin, label: "Out")])
}

private func report(_ outcome: ActivationCommitOutcome, applied: Set<NodeID> = Set(nodes),
                    unapplied: Set<NodeID> = []) -> CommitReportDraft {
    CommitReportDraft(prepared: planID, outcome: outcome, applied: applied, unapplied: unapplied)
}

private let partial = report(.partial, applied: [nodes[0]], unapplied: [nodes[1], nodes[2]])

private func restore(_ revision: ContractRevision) -> ActivationRecoveryStep {
    ActivationRecoveryStep(cause: .commitFailed, decisions: [.restorePrevious(revision)], effects: [.discard(planID)])
}

private func mutedRecovery(_ cause: RecoveryEvent) -> ActivationRecoveryStep {
    ActivationRecoveryStep(cause: cause, decisions: [.recover(muteOutputs: true)], effects: [])
}

extension TransactionBench {
    /// Reviews, authorizes and commits the plan at `base`, returning the attempt the engine was given.
    mutating func committedAttempt(base: ContractRevision = .initial) throws -> CommitAttemptID {
        try reviewing(request(base: base), candidate: candidate(revision: base))
        _ = try commit(try authorize()).get()
        return try #require(transaction.lastAttempt)
    }

    /// An attempt issued by another transaction, which this one must treat as stale.
    static func foreignAttempt() throws -> CommitAttemptID {
        var other = try TransactionBench()
        return try other.committedAttempt()
    }

    /// Expects a restoring `resolveRecovery` refused, unchanged, without this project's lease.
    mutating func expectRestoreNeedsLease(_ attempt: CommitAttemptID) throws {
        #expect(refusal { $0.resolveRecovery(attempt, lease: nil) } == .leaseNotHeld)
        var moved = registry
        if let token = moved.snapshot?.token { _ = try moved.release(expected: token) }
        _ = try moved.acquire(project: projectB, window: windowB)
        #expect(refusal { $0.resolveRecovery(attempt, lease: moved.snapshot) } == .leaseHeldByOtherProject(projectB))
    }

    /// Expects `transaction` settled in `phase` over `running`, holding no plan and
    /// keeping `before`'s attempts and authorizer: a recovery exit issues and revokes nothing.
    func expectSettled(_ phase: ActivationPhase, running: RunningGraph, since before: ActivationTransaction,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let now = transaction
        #expect(now.phase == phase && now.running == running && now.validated == nil, sourceLocation: sourceLocation)
        #expect(now.lastAttempt == before.lastAttempt && now.lastPrepareAttempt == before.lastPrepareAttempt
            && now.authorizer == before.authorizer && now.project == before.project, sourceLocation: sourceLocation)
    }
}

/// One case per `CommandOperation` case; `init(_:)` has no `default`, so a new operation fails to compile here.
private enum OperationKind: CaseIterable {
    case set, ramp, bind, recall, trigger, start, stop, locate, panic, safeMute, propose, editDraft

    // swiftlint:disable:next cyclomatic_complexity
    init(_ operation: CommandOperation) { // One case per operation, deliberately without `default`.
        switch operation {
        case .set: self = .set
        case .ramp: self = .ramp
        case .bind: self = .bind
        case .recall: self = .recall
        case .trigger: self = .trigger
        case .start: self = .start
        case .stop: self = .stop
        case .locate: self = .locate
        case .panic: self = .panic
        case .safeMute: self = .safeMute
        case .propose: self = .propose
        case .editDraft: self = .editDraft
        }
    }

    var operation: CommandOperation {
        switch self {
        case .set: .set(liveParameter, value)
        case .ramp: .ramp(liveParameter, value, milliseconds: 50)
        case .bind: .bind(RouteID(validated: "route.main"))
        case .recall: .recall(PatchID(validated: "patch.main"))
        case .trigger: .trigger(ActionID(validated: "action.main"))
        case .start: .start
        case .stop: .stop
        case .locate: .locate(ticks: 0)
        case .panic: .panic
        case .safeMute: .safeMute
        case .propose: .propose(draftID)
        case .editDraft: .editDraft(draftID)
        }
    }

    /// Hard-coded: whether the operation changes what the engine renders.
    var changesRunningSet: Bool {
        switch self {
        case .set, .ramp, .bind, .recall, .trigger, .start, .stop, .locate: true
        case .panic, .safeMute, .propose, .editDraft: false
        }
    }

    var isSafety: Bool { self == .panic || self == .safeMute }

    func intent(epoch: HostEpoch = hostEpoch, revisions: CommandRevisions = CommandRevisions(),
                origin: CommandOrigin = .human, granted: PermissionFingerprint = permission) throws -> CommandIntent {
        try CommandIntent(.init(
            id: CommandID(validated: "command.recovery"), commandClass: operation.controlClass ?? .live,
            origin: origin, hostEpoch: epoch, connectionEpoch: nil, revisions: revisions, operation: operation,
            permission: granted
        ))
    }
}

/// Admission for every operation's scope, or only `scopes` when given.
private func admission(scopes: Set<CommandScope>? = nil) throws -> AdmissionContext {
    let descriptor = try ParameterDescriptor(.init(
        id: liveParameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8, curve: .linear,
        ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
        controlClass: .live, verification: .reported
    ))
    return AdmissionContext(
        hostEpoch: hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(), permission: permission,
        allowedScopes: scopes ?? Set(OperationKind.allCases.map(\.operation.scope)),
        allowedClasses: Set(ControlClass.allCases), catalog: try ParameterCatalog([descriptor])
    )
}

private func gate(_ kind: OperationKind, in lifecycle: EngineLifecycle, epoch: HostEpoch = hostEpoch)
throws -> HostCommandDecision {
    HostCommandGate.admit(try kind.intent(epoch: epoch), admission: try admission(), lifecycle: lifecycle)
}

/// Every operation in `lifecycle`: running-set changes are unavailable while blocking, all else admitted.
private func expectGate(in lifecycle: EngineLifecycle, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(OperationKind.allCases.allSatisfy { OperationKind($0.operation) == $0 })
    for kind in OperationKind.allCases {
        let expected: HostCommandDecision = blocking.contains(lifecycle) && kind.changesRunningSet
            ? .unavailable(lifecycle) : .admitted
        #expect(try gate(kind, in: lifecycle) == expected, "\(kind)", sourceLocation: sourceLocation)
    }
}

extension HostAuthorityTests {
    struct Recovery {
        @Test func commitFailureRestoresPreviousPreparedRevision() throws {
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            #expect(try host.transaction.acknowledged(report(.failed, applied: [], unapplied: Set(nodes)))
                .get().isEmpty)
            let foreign = try TransactionBench.foreignAttempt()
            let lease = host.registry.snapshot
            #expect(host.refusal { $0.resolveRecovery(foreign, lease: lease) } == .staleReport)
            try host.expectRestoreNeedsLease(attempt)
            let before = host.transaction
            #expect(try host.transaction.resolveRecovery(attempt, lease: lease).get() == restore(.initial))
            host.expectSettled(.idle, running: RunningGraph(revision: .initial, prepared: runningPlan), since: before)
            #expect(host.refusal { $0.resolveRecovery(attempt, lease: lease) } == .unexpectedPhase(.idle))
            #expect(EngineLifecycle.running.after(.commitFailed) == .running)
            // Recovered: another activation may begin over the unchanged running graph.
            #expect(try host.begin(request(), candidate: candidate()).count == 1)
        }

        @Test func partialCommitKeepsActivePlanWithMissingPlaceholders() throws {
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            #expect(try host.transaction.acknowledged(partial).get().isEmpty)
            let lease = host.registry.snapshot
            let foreign = try TransactionBench.foreignAttempt()
            #expect(host.refusal { $0.resolveRecovery(foreign, lease: lease) } == .staleReport)
            let before = host.transaction
            let next = try ContractRevision.initial.next()
            #expect(try host.transaction.resolveRecovery(attempt, lease: lease).get() == ActivationRecoveryStep(
                cause: .partialCommit,
                decisions: [.keepActivePartial, .missingPlaceholder(nodes[1]), .missingPlaceholder(nodes[2])],
                effects: [.discard(runningPlan)]
            ))
            host.expectSettled(.acknowledged(next), running: RunningGraph(revision: next, prepared: planID),
                               since: before)
            #expect(host.refusal { $0.resolveRecovery(attempt, lease: lease) } == .unexpectedPhase(.acknowledged(next)))
        }

        @Test(arguments: [CommitAbandonment.outcomeUnknown, .leaseLost])
        func unknownCommitOutcomeFailsClosedIntoMutedRecovery(reason: CommitAbandonment) throws {
            var host = try TransactionBench()
            try host.reviewing(request(), candidate: candidate())
            let foreign = try TransactionBench.foreignAttempt()
            #expect(host.refusal { $0.abandonCommit(foreign, reason: reason) } == .unexpectedPhase(.awaitingReview))
            _ = try host.commit(try host.authorize()).get()
            let attempt = try #require(host.transaction.lastAttempt)
            #expect(host.refusal { $0.abandonCommit(foreign, reason: reason) } == .staleReport)
            // An overflow claim is checked: this revision can still advance.
            #expect(host.refusal { $0.abandonCommit(attempt, reason: .revisionOverflow) }
                == .unexpectedPhase(.committing))
            let before = host.transaction
            #expect(try host.transaction.abandonCommit(attempt, reason: reason).get() == mutedRecovery(reason.event))
            host.expectSettled(.recovering(planID), running: before.running, since: before)
            let lifecycle = EngineLifecycle.running.after(reason.event)
            #expect(lifecycle == .recovering && lifecycle.outputsMuted)
            // Never assumed successful: a late report is ignored and nothing new begins.
            #expect(host.refusal { $0.acknowledged(report(.succeeded)) } == .unexpectedPhase(.recovering(planID)))
            #expect(host.refusal { $0.abandonCommit(attempt, reason: reason) } == .unexpectedPhase(.recovering(planID)))
            let live = try host.live
            #expect(host.refusal { $0.begin(request(), candidate: candidate(), in: live) }
                == .unexpectedPhase(.recovering(planID)))
            #expect(host.refusal { $0.resolveRecovery(foreign, lease: nil) } == .staleReport)
            try host.expectRestoreNeedsLease(attempt)
            #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get()
                == restore(.initial))
            host.expectSettled(.idle, running: before.running, since: before)
        }

        @Test(arguments: [false, true])
        func revisionOverflowHasAFailClosedExit(partially: Bool) throws {
            let last = try ContractRevision(ContractRevision.maximumValue)
            var host = try TransactionBench(revision: last)
            let attempt = try host.committedAttempt(base: last)
            if partially {
                // The partial plan cannot become a revision, so it is not kept.
                #expect(try host.transaction.acknowledged(partial).get().isEmpty)
                #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get()
                    == mutedRecovery(.revisionOverflow))
            } else {
                #expect(host.refusal { $0.acknowledged(report(.succeeded)) } == .overflow)
                #expect(host.transaction.phase == .committing)
                #expect(try host.transaction.abandonCommit(attempt, reason: .revisionOverflow).get()
                    == mutedRecovery(.revisionOverflow))
            }
            #expect(host.transaction.phase == .recovering(planID) && host.transaction.validated == nil)
            #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get() == restore(last))
            #expect(host.transaction.phase == .idle)
            #expect(host.transaction.running == RunningGraph(revision: last, prepared: runningPlan))
        }

        @Test func lostPrepareAnswerHasAnAttemptBoundExit() throws {
            var other = try TransactionBench()
            try other.acquire(projectA)
            _ = try other.begin()
            let foreign = try #require(other.transaction.lastPrepareAttempt)
            var host = try TransactionBench()
            try host.acquire(projectA)
            #expect(host.refusal { $0.abandonPrepare(foreign) } == .unexpectedPhase(.idle))
            _ = try host.begin()
            let lost = try #require(host.transaction.lastPrepareAttempt)
            #expect(host.refusal { $0.abandonPrepare(foreign) } == .stalePrepareResponse)
            let before = host.transaction
            #expect(try host.transaction.abandonPrepare(lost).get().isEmpty)  // No discard: the ID may be reissued.
            host.expectSettled(.idle, running: before.running, since: before)
            #expect(host.refusal { $0.abandonPrepare(lost) } == .unexpectedPhase(.idle))
            #expect(host.refusal { $0.prepared(.success(planID), attempt: lost) } == .unexpectedPhase(.idle))
            // The next prepare has a new attempt, so the late answer stays stale.
            _ = try host.begin()
            #expect(host.refusal { $0.prepared(.success(planID), attempt: lost) } == .stalePrepareResponse)
            _ = try host.transaction.prepared(.success(planID)).get()
            #expect(host.refusal { $0.abandonPrepare(lost) } == .unexpectedPhase(.awaitingReview))
        }

        @Test func processorCrashBecomesMissingPlaceholderNotReactivation() throws {
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            for node in nodes {
                #expect(ActivationRecovery.decisions(for: .processorCrashed(node), running: running)
                    == [.missingPlaceholder(node)])
            }
            for lifecycle in lifecycles {
                #expect(lifecycle.after(.processorCrashed(nodes[0])) == lifecycle)
            }
            // An acknowledged transaction is untouched: nothing is prepared or committed again.
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            _ = try host.transaction.acknowledged(report(.succeeded)).get()
            let phase = host.transaction.phase
            #expect(host.refusal { $0.resolveRecovery(attempt, lease: nil) } == .unexpectedPhase(phase))
        }

        @Test func recoveryNeverUnmutesOutputs() {
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            #expect(EventKind.allCases.allSatisfy { EventKind($0.event) == $0 })
            for kind in EventKind.allCases {
                #expect(!ActivationRecovery.decisions(for: kind.event, running: running)
                    .contains(.recover(muteOutputs: false)), "\(kind)")
            }
            #expect(LifecycleKind.allCases.allSatisfy { LifecycleKind($0.lifecycle) == $0 })
        }

        @Test func leaseLossEntersRecoveringWithMutedOutputs() throws {
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            #expect(ActivationRecovery.decisions(for: .leaseLost, running: running) == [.recover(muteOutputs: true)])
            for lifecycle in lifecycles {
                let after = lifecycle.after(.leaseLost)
                #expect(after == .recovering && after.outputsMuted && !after.rendersOutput)
            }
            #expect(lifecycles.filter(\.outputsMuted) == [.recovering])
            try expectGate(in: EngineLifecycle.running.after(.leaseLost))
        }

        @Test func capabilityLossDegradesWithoutRecovery() throws {
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            #expect(ActivationRecovery.decisions(for: .capabilityLost(audio), running: running).isEmpty)
            let degraded = EngineLifecycle.running.after(.capabilityLost(audio))
            #expect(degraded == .degraded([audio]) && degraded.rendersOutput && !degraded.outputsMuted)
            #expect(degraded.after(.capabilityLost(audio)) == degraded)
            #expect(degraded.after(.capabilityLost(meter)) == .degraded([audio, meter]))
            #expect(EngineLifecycle.recovering.after(.capabilityLost(audio)) == .recovering)
        }

        @Test(arguments: blocking)
        func liveCommandsRejectedWhileRecovering(lifecycle: EngineLifecycle) throws {
            try expectGate(in: lifecycle)
            let assistant = try OperationKind.set.intent(origin: .assistant)
            #expect(HostCommandGate.admit(assistant, admission: try admission(), lifecycle: lifecycle)
                == .refused(.rejected(.permissionDenied)))
        }

        @Test(arguments: lifecycles.filter { !blocking.contains($0) })
        func commandsAdmittedWhileEngineAcceptsChanges(lifecycle: EngineLifecycle) throws {
            try expectGate(in: lifecycle)
        }

        @Test(arguments: lifecycles)
        func safetyCommandsAdmittedInEveryLifecycle(lifecycle: EngineLifecycle) throws {
            #expect(try gate(.panic, in: lifecycle) == .admitted)
            #expect(try gate(.safeMute, in: lifecycle) == .admitted)
        }

        /// The gate returns `CommandAdmission`'s own refusal, even for safety commands (#55 owns the rules).
        @Test(arguments: lifecycles)
        func gateReturnsAdmissionRefusalUnchanged(lifecycle: EngineLifecycle) throws {
            let stale = HostEpoch(host: hostEpoch.host, generation: try Generation.initial.next())
            var revisions = CommandRevisions()
            revisions.graph = try ContractRevision.initial.next()
            let other = PermissionFingerprint(rawValue: "permissions.other")
            for kind in OperationKind.allCases {
                let cases: [(CommandIntent, CommandResult)] = [
                    (try kind.intent(epoch: stale), .stale(.hostEpoch)),
                    (try kind.intent(revisions: revisions), .rejected(.revisionChanged)),
                    (try kind.intent(granted: other), .rejected(.permissionChanged)),
                    (try kind.intent(), .rejected(.scopeDenied))
                ]
                for (intent, result) in cases {
                    let context = try admission(scopes: result == .rejected(.scopeDenied) ? [] : nil)
                    #expect(CommandAdmission.admit(intent, in: context) == .refused(result))
                    #expect(HostCommandGate.admit(intent, admission: context, lifecycle: lifecycle) == .refused(result),
                            "\(kind)")
                }
            }
        }

        @Test func heldByOtherWindowCannotRender() throws {
            var registry = EngineLeaseRegistry()
            _ = try registry.acquire(project: projectA, window: windowA)
            #expect(EngineLifecycle.observed(by: windowA, of: projectA, in: registry, engine: .running) == .running)
            let other = EngineLifecycle.observed(by: windowB, of: projectB, in: registry, engine: .running)
            #expect(other == .heldByOther(projectA) && !other.rendersOutput && !other.outputsMuted)
            #expect(try gate(.set, in: other) == .unavailable(other))
            #expect(try gate(.panic, in: other) == .admitted && gate(.editDraft, in: other) == .admitted)
            let detached = EngineLifecycle.observed(by: windowB, of: projectA, in: registry, engine: .running)
            #expect(detached == .heldByOther(projectA) && !detached.rendersOutput)
            _ = try registry.release(expected: try #require(registry.snapshot).token)
            let stopped = EngineLifecycle.observed(by: windowB, of: projectB, in: registry, engine: .running)
            #expect(stopped == .stopped && !stopped.rendersOutput)
            #expect(lifecycles.filter(\.rendersOutput) == [.preparing(.initial), .running, .degraded([audio])])
        }
    }
}
