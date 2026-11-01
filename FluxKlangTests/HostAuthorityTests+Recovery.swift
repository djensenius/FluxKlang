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
private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]
private let liveParameter = ParameterID(validated: "parameter.live")
private let hazardousParameter = ParameterID(validated: "parameter.hazardous")
private let draftID = DraftID(validated: "draft.main")

private let lifecycles: [EngineLifecycle] = [
    .stopped, .preparing(.initial), .running, .degraded([audio]), .recovering, .heldByOther(projectB)
]

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
    ActivationRecoveryStep(decisions: [.restorePrevious(revision)], effects: [.discard(planID)])
}

private let mutedRecovery = ActivationRecoveryStep(decisions: [.recover(muteOutputs: true)], effects: [])

extension TransactionBench {
    /// Reviews, authorizes and commits the plan at `base`, returning the attempt the engine was given.
    fileprivate mutating func committedAttempt(base: ContractRevision = .initial) throws -> CommitAttemptID {
        try reviewing(request(base: base), candidate: candidate(revision: base))
        _ = try commit(try authorize()).get()
        return try #require(transaction.lastAttempt)
    }

    /// An attempt issued by another transaction, which this one must treat as stale.
    fileprivate static func foreignAttempt() throws -> CommitAttemptID {
        var other = try TransactionBench()
        return try other.committedAttempt()
    }
}

/// One command per kind of change the gate distinguishes.
private enum GatedCommand: CaseIterable {
    case live, hazardous, bind, transport, panic, safeMute, propose, editDraft

    var operation: CommandOperation {
        switch self {
        case .live: .set(liveParameter, .init(value: 0.5, unit: .normalized))
        case .hazardous: .set(hazardousParameter, .init(value: 0.5, unit: .normalized))
        case .bind: .bind(RouteID(validated: "route.main"))
        case .transport: .start
        case .panic: .panic
        case .safeMute: .safeMute
        case .propose: .propose(draftID)
        case .editDraft: .editDraft(draftID)
        }
    }

    var commandClass: ControlClass {
        switch self {
        case .live, .transport: .live
        case .hazardous: .hazardous
        case .bind, .editDraft: .structural
        case .panic, .safeMute: .safety
        case .propose: .proposal
        }
    }

    /// Whether the command changes what the engine renders.
    var changesRunningSet: Bool { [.live, .hazardous, .bind, .transport].contains(self) }

    func intent(epoch: HostEpoch = hostEpoch, origin: CommandOrigin = .human) throws -> CommandIntent {
        try CommandIntent(.init(
            id: CommandID(validated: "command.recovery"), commandClass: commandClass, origin: origin,
            hostEpoch: epoch, connectionEpoch: nil, revisions: CommandRevisions(), operation: operation,
            permission: permission
        ))
    }
}

private func admission() throws -> AdmissionContext {
    let descriptors = try [(liveParameter, ControlClass.live), (hazardousParameter, .hazardous)].map { id, kind in
        try ParameterDescriptor(.init(
            id: id, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8, curve: .linear,
            ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
            controlClass: kind, verification: .reported
        ))
    }
    return AdmissionContext(
        hostEpoch: hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(), permission: permission,
        allowedScopes: Set(GatedCommand.allCases.map(\.operation.scope)), allowedClasses: Set(ControlClass.allCases),
        catalog: try ParameterCatalog(descriptors)
    )
}

private func gate(_ command: GatedCommand, in lifecycle: EngineLifecycle,
                  epoch: HostEpoch = hostEpoch) throws -> HostCommandDecision {
    HostCommandGate.admit(try command.intent(epoch: epoch), admission: try admission(), lifecycle: lifecycle)
}

extension HostAuthorityTests {
    struct Recovery {
        @Test func commitFailureRestoresPreviousPreparedRevision() throws {
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            #expect(try host.transaction.acknowledged(report(.failed, applied: [], unapplied: Set(nodes)))
                .get().isEmpty)
            let foreign = try TransactionBench.foreignAttempt()
            #expect(host.refusal { $0.resolveRecovery(foreign) } == .staleReport)
            #expect(try host.transaction.resolveRecovery(attempt).get() == restore(.initial))
            #expect(host.transaction.phase == .idle)
            #expect(host.transaction.running == RunningGraph(revision: .initial, prepared: runningPlan))
            #expect(host.refusal { $0.resolveRecovery(attempt) } == .unexpectedPhase(.idle))
            #expect(EngineLifecycle.running.after(.commitFailed) == .running)
            // Recovered: another activation may begin over the unchanged running graph.
            #expect(try host.begin(request(), candidate: candidate()).count == 1)
        }

        @Test func partialCommitKeepsActivePlanWithMissingPlaceholders() throws {
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            #expect(try host.transaction.acknowledged(partial).get().isEmpty)
            let next = try ContractRevision.initial.next()
            #expect(try host.transaction.resolveRecovery(attempt).get() == ActivationRecoveryStep(
                decisions: [.keepActivePartial, .missingPlaceholder(nodes[1]), .missingPlaceholder(nodes[2])],
                effects: [.discard(runningPlan)]
            ))
            #expect(host.transaction.running == RunningGraph(revision: next, prepared: planID))
            #expect(host.transaction.phase == .acknowledged(next))
        }

        @Test func unknownCommitOutcomeFailsClosedIntoMutedRecovery() throws {
            var host = try TransactionBench()
            try host.reviewing(request(), candidate: candidate())
            let foreign = try TransactionBench.foreignAttempt()
            #expect(host.refusal { $0.abandonCommit(foreign) } == .unexpectedPhase(.awaitingReview))
            _ = try host.commit(try host.authorize()).get()
            let attempt = try #require(host.transaction.lastAttempt)
            #expect(host.refusal { $0.abandonCommit(foreign) } == .staleReport)
            #expect(try host.transaction.abandonCommit(attempt).get() == mutedRecovery)
            #expect(host.transaction.phase == .recovering(planID))
            #expect(host.transaction.running == RunningGraph(revision: .initial, prepared: runningPlan))
            let lifecycle = EngineLifecycle.running.after(.commitOutcomeUnknown)
            #expect(lifecycle == .recovering && lifecycle.outputsMuted)
            // Never assumed successful: a late report is ignored and nothing new begins.
            #expect(host.refusal { $0.acknowledged(report(.succeeded)) } == .unexpectedPhase(.recovering(planID)))
            #expect(host.refusal { $0.abandonCommit(attempt) } == .unexpectedPhase(.recovering(planID)))
            let live = try host.live
            #expect(host.refusal { $0.begin(request(), candidate: candidate(), in: live) }
                == .unexpectedPhase(.recovering(planID)))
            #expect(host.refusal { $0.resolveRecovery(foreign) } == .staleReport)
            #expect(try host.transaction.resolveRecovery(attempt).get() == restore(.initial))
            #expect(host.transaction.phase == .idle)
            #expect(host.transaction.running == RunningGraph(revision: .initial, prepared: runningPlan))
        }

        @Test(arguments: [false, true])
        func revisionOverflowHasAFailClosedExit(partially: Bool) throws {
            let last = try ContractRevision(ContractRevision.maximumValue)
            var host = try TransactionBench(revision: last)
            let attempt = try host.committedAttempt(base: last)
            if partially {
                // The partial plan cannot become a revision, so it is not kept.
                #expect(try host.transaction.acknowledged(partial).get().isEmpty)
                #expect(try host.transaction.resolveRecovery(attempt).get() == mutedRecovery)
            } else {
                #expect(host.refusal { $0.acknowledged(report(.succeeded)) } == .overflow)
                #expect(host.transaction.phase == .committing)
                #expect(try host.transaction.abandonCommit(attempt).get() == mutedRecovery)
            }
            #expect(host.transaction.phase == .recovering(planID))
            #expect(try host.transaction.resolveRecovery(attempt).get() == restore(last))
            #expect(host.transaction.phase == .idle)
            #expect(host.transaction.running == RunningGraph(revision: last, prepared: runningPlan))
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
            #expect(host.refusal { $0.resolveRecovery(attempt) } == .unexpectedPhase(host.transaction.phase))
        }

        @Test func leaseLossEntersRecoveringWithMutedOutputs() throws {
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            #expect(ActivationRecovery.decisions(for: .leaseLost, running: running) == [.recover(muteOutputs: true)])
            for lifecycle in lifecycles {
                let after = lifecycle.after(.leaseLost)
                #expect(after == .recovering && after.outputsMuted && !after.rendersOutput)
            }
            #expect(lifecycles.filter(\.outputsMuted) == [.recovering])
            #expect(try gate(.live, in: EngineLifecycle.running.after(.leaseLost)) == .unavailable(.recovering))
            #expect(try gate(.panic, in: EngineLifecycle.running.after(.leaseLost)) == .admitted)
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

        @Test(arguments: [EngineLifecycle.recovering, .heldByOther(projectB)])
        func liveCommandsRejectedWhileRecovering(lifecycle: EngineLifecycle) throws {
            for command in GatedCommand.allCases {
                #expect(try gate(command, in: lifecycle) == (command.changesRunningSet ? .unavailable(lifecycle)
                                                                                        : .admitted))
            }
            // CommandAdmission refusals come first and are unchanged.
            let stale = HostEpoch(host: hostEpoch.host, generation: try Generation.initial.next())
            #expect(try gate(.live, in: lifecycle, epoch: stale) == .refused(.stale(.hostEpoch)))
            let assistant = try GatedCommand.live.intent(origin: .assistant)
            #expect(HostCommandGate.admit(assistant, admission: try admission(), lifecycle: lifecycle)
                == .refused(.rejected(.permissionDenied)))
        }

        @Test(arguments: [EngineLifecycle.stopped, .preparing(.initial), .running, .degraded([audio])])
        func commandsAdmittedWhileEngineAcceptsChanges(lifecycle: EngineLifecycle) throws {
            for command in GatedCommand.allCases {
                #expect(try gate(command, in: lifecycle) == .admitted)
            }
        }

        @Test(arguments: lifecycles)
        func safetyCommandsAdmittedInEveryLifecycle(lifecycle: EngineLifecycle) throws {
            #expect(try gate(.panic, in: lifecycle) == .admitted)
            #expect(try gate(.safeMute, in: lifecycle) == .admitted)
            let stale = HostEpoch(host: hostEpoch.host, generation: try Generation.initial.next())
            #expect(try gate(.panic, in: lifecycle, epoch: stale) == .refused(.stale(.hostEpoch)))
        }

        @Test func heldByOtherWindowCannotRender() throws {
            var registry = EngineLeaseRegistry()
            _ = try registry.acquire(project: projectA, window: windowA)
            #expect(EngineLifecycle.observed(by: windowA, of: projectA, in: registry, engine: .running) == .running)
            let other = EngineLifecycle.observed(by: windowB, of: projectB, in: registry, engine: .running)
            #expect(other == .heldByOther(projectA) && !other.rendersOutput && !other.outputsMuted)
            #expect(try gate(.live, in: other) == .unavailable(other))
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
