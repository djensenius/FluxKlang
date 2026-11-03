import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

private func pendingCount(_ snapshot: HostAuthoritySnapshot) -> Int {
    snapshot.plans.records.flatMap(\.entries).filter {
        if case .pending = $0.state { true } else { false }
    }.count
}

private func beginAndAbandon(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                             project: ProjectID = Bench.projectA) async throws -> HostPrepare {
    try await Bench.begin(authority, project: project)
    await engine.drain(authority)
    let preparation = try engine.requireNext()
    try await authority.abandonPrepare(project: project).get()
    return preparation
}

private func answer(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                    _ preparation: HostPrepare, as id: PreparedActivationID) async
-> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
    let result = engine.prepare(preparation, as: id)
    return await authority.prepareAnswered(result, instance: preparation.instance, attempt: preparation.attempt)
}

private func reclaimed(_ outcome: Result<PrepareAnswerOutcome, HostAuthorityRefusal>) throws -> PlanBinding {
    guard case .success(.reclaimed(let binding)) = outcome else {
        Issue.record("Expected qualified reclamation, got \(outcome)")
        throw ActorTestError.notReclaimed
    }
    return binding
}

private enum ActorTestError: Error { case notReclaimed }

extension HostAuthorityTests {
    struct Actor {
        @Test func abandonedPrepareSuccessIsReclaimedOnce() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let attempt = try await beginAndAbandon(authority, &engine)
            let id = PreparedActivationID(validated: "prep.late")
            let binding = try reclaimed(await answer(authority, &engine, attempt, as: id))
            let before = await authority.snapshot()
            let duplicate = await authority.prepareAnswered(.success(id), instance: attempt.instance,
                                                             attempt: attempt.attempt)
            #expect(Bench.refusal(duplicate) == .activation(.stalePrepareResponse))
            #expect(await authority.snapshot() == before && pendingCount(before) == 0)
            #expect(try await Bench.state(authority).lifecycle == .running)
            #expect(await engine.drain(authority) == [.discard(binding)])
            #expect(engine.disposed.last?.matches(binding) == true)
            #expect(try await Bench.state(authority).phase == .idle)
        }

        @Test func lateSuccessAfterRebeginDoesNotChangeTheReview() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let first = try await beginAndAbandon(authority, &engine)
            let second = try await beginAndAbandon(authority, &engine)
            try await Bench.begin(authority)
            await engine.drain(authority)
            let third = try engine.requireNext()
            #expect(Set([first, second, third]).count == 3)
            let firstBinding = try reclaimed(await answer(
                authority, &engine, first, as: PreparedActivationID(validated: "prep.first")
            ))
            let currentID = PreparedActivationID(validated: "prep.current")
            #expect(await answer(authority, &engine, third, as: currentID) == .success(.routed))
            let before = try await Bench.state(authority)
            let secondBinding = try reclaimed(await answer(
                authority, &engine, second, as: PreparedActivationID(validated: "prep.second")
            ))
            #expect(try await Bench.state(authority) == before)
            let current = try #require(before.reviewed)
            #expect(current.prepared == currentID && before.phase == .awaitingReview)
            #expect(before.lifecycle == .preparing(try before.running.revision.next(), over: .running))
            try await authority.cancel(project: Bench.projectA).get()
            let expected: [EngineCommand] = [.discard(firstBinding), .discard(secondBinding), .discard(current)]
            #expect(await engine.drain(authority) == expected)
            #expect(try await Bench.state(authority).reviewed == nil)
            #expect(try await Bench.state(authority).lifecycle == .running)
        }

        @Test func foreignOrDuplicateStaleAnswerNeverDiscards() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            var otherEngine = try ScriptedActivationEngine()
            let other = try await Bench.makeAuthority(&otherEngine)
            let foreign = try await beginAndAbandon(other, &otherEngine)
            let own = try await beginAndAbandon(authority, &engine)
            let before = await authority.snapshot()
            let id = PreparedActivationID(validated: "prep.foreign")
            for key in [foreign, HostPrepare(instance: foreign.instance, attempt: own.attempt)] {
                let crossed = await authority.prepareAnswered(
                    .success(id), instance: key.instance, attempt: key.attempt
                )
                #expect(Bench.refusal(crossed) == .activation(.stalePrepareResponse))
                #expect(await authority.snapshot() == before)
            }
            let failed = engine.terminalFailure(own, reason: .engineRefused)
            #expect(await authority.prepareAnswered(failed, instance: own.instance,
                                                     attempt: own.attempt) == .success(.dropped))
            let after = await authority.snapshot()
            #expect(pendingCount(after) == 0 && after.queue == before.queue)
            #expect(Bench.refusal(await authority.prepareAnswered(.success(id), instance: own.instance,
                                                                  attempt: own.attempt))
                    == .activation(.stalePrepareResponse))
            let reviewedID = try await Bench.review(authority, &engine)
            let reviewed = try #require(try await Bench.state(authority).reviewed)
            let reviewedSnapshot = await authority.snapshot()
            #expect(Bench.refusal(await authority.prepareAnswered(.success(reviewedID), instance: reviewed.instance,
                                                                  attempt: reviewed.attempt))
                    == .activation(.stalePrepareResponse))
            #expect(await authority.snapshot() == reviewedSnapshot && engine.discarded.isEmpty)
        }

        @Test func staleAnswerAliasingLivePlansDisposesOnlyItsOwnPreparation() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let planB = try await Bench.review(authority, &engine, project: Bench.projectB)
            let beforeB = try await Bench.state(authority, Bench.projectB)
            var bindings: [PlanBinding] = []
            for name in [Bench.runningPlan, planB] {
                let late = try await beginAndAbandon(authority, &engine)
                bindings.append(try reclaimed(await answer(authority, &engine, late, as: name)))
            }
            await engine.drain(authority)
            #expect(engine.discarded == bindings)
            let after = await authority.snapshot()
            #expect(engine.held.count == 2 && pendingCount(after) == 0)
            #expect(try await Bench.state(authority, Bench.projectB) == beforeB)
        }

        @Test func rejectedBeginsNeverReachEngine() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let revision = try await Bench.state(authority).running.revision
            let graph = Bench.candidate(revision: revision)
            let document = Bench.projectDocument(project: Bench.projectA, candidate: graph)
            let next = try revision.next()
            let wrongEpoch = HostEpoch(host: Bench.host, generation: try Generation.initial.next())
            func request(base: ContractRevision? = nil, epoch: HostEpoch = Bench.hostEpoch,
                         permission: PermissionFingerprint = Bench.permission, origin: CommandOrigin = .human,
                         digest: String = "sha256:activation") -> ActivationRequest {
                ActivationRequest(draft: DraftID(validated: "draft.main"), graph: Bench.graphID,
                                  baseRevision: base ?? revision, hostEpoch: epoch, permission: permission,
                                  digest: ActivationDigest(rawValue: digest), origin: origin)
            }
            let cases: [(ActivationRequest, ActivationRejection)] = [
                (request(epoch: wrongEpoch), .staleHostEpoch),
                (request(permission: PermissionFingerprint(rawValue: "old")), .permissionChanged),
                (request(origin: .assistant), .originCannotActivate(.assistant)),
                (request(digest: ""), .invalidDigest),
                (request(base: next), .staleBase(expected: revision, found: next))
            ]
            let before = await authority.snapshot()
            for (request, rejection) in cases {
                #expect(Bench.refusal(await authority.begin(request, candidate: graph,
                                                            projectDocument: document, project: Bench.projectA))
                        == .activation(.rejected(rejection)))
            }
            let wrongGraph = GraphDocument(id: GraphID(validated: "graph.other"), revision: revision)
            let wrongDocument = Bench.projectDocument(project: Bench.projectA, candidate: wrongGraph)
            #expect(Bench.refusal(await authority.begin(request(), candidate: wrongGraph,
                                                        projectDocument: wrongDocument, project: Bench.projectA))
                    == .activation(.rejected(.graphMismatch)))
            #expect(Bench.refusal(await authority.begin(
                request(), candidate: graph,
                projectDocument: Bench.projectDocument(project: Bench.projectC, candidate: graph),
                project: Bench.projectC
            ))
                    == .unknownProject(Bench.projectC))
            #expect(await authority.snapshot() == before)
            let live = try Bench.liveState()
            for (permission, rejection): (PermissionFingerprint?, ActivationRejection) in [
                (PermissionFingerprint(rawValue: "new"), .permissionChanged), (nil, .permissionDenied)
            ] {
                await authority.updateLive(HostLiveState(hostEpoch: live.hostEpoch, permission: permission,
                                                         capabilities: live.capabilities))
                #expect(Bench.refusal(await authority.begin(request(), candidate: graph,
                                                            projectDocument: document, project: Bench.projectA))
                        == .activation(.rejected(rejection)))
            }
            await authority.updateLive(try Bench.liveState(epoch: wrongEpoch))
            #expect(Bench.refusal(await authority.begin(request(), candidate: graph,
                                                        projectDocument: document, project: Bench.projectA))
                    == .activation(.rejected(.staleHostEpoch)))
            await authority.updateLive(live)
            #expect(await authority.nextEngineCommand() == nil)
            try await Bench.begin(authority)
            let preparing = await authority.snapshot()
            #expect(Bench.refusal(await authority.begin(request(), candidate: graph,
                                                        projectDocument: document, project: Bench.projectA))
                    == .activation(.busy))
            #expect(await authority.snapshot() == preparing)
        }

        @Test func lostAnswersConsumeCapacityWithoutEviction() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine, planCapacity: 4)
            var lost: [HostPrepare] = []
            for _ in 0..<3 { lost.append(try await beginAndAbandon(authority, &engine)) }
            let full = await authority.snapshot()
            let revision = try await Bench.state(authority).running.revision
            let graph = Bench.candidate(revision: revision)
            #expect(pendingCount(full) == 3 && full.plans.capacity == 4)
            #expect(Bench.refusal(await authority.begin(Bench.request(base: revision),
                                                        candidate: graph,
                                                        projectDocument: Bench.projectDocument(
                                                            project: Bench.projectA, candidate: graph),
                                                        project: Bench.projectA)) == .plans(.capacityReached))
            #expect(Bench.refusal(await authority.abandonPrepare(project: Bench.projectA))
                    == .activation(.unexpectedPhase(.idle)))
            #expect(await authority.snapshot() == full)
            let binding = try reclaimed(await answer(
                authority, &engine, lost[0], as: PreparedActivationID(validated: "prep.oldest")
            ))
            #expect(Bench.refusal(await authority.retired(binding)) == .retirementQueued)
            #expect(await authority.snapshot().plans.records[0].entries.count == 4)
            await engine.drain(authority)
            try await Bench.begin(authority)
            #expect(pendingCount(await authority.snapshot()) == 3)
        }

        @Test func crossProjectAliasesAreAllowedButSameProjectCollisionIsConsumed() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.begin(authority, project: Bench.projectB)
            await engine.drain(authority)
            let attemptB = try engine.requireNext()
            #expect(await answer(authority, &engine, attemptB, as: Bench.runningPlan) == .success(.routed))
            let reviewB = try #require(try await Bench.state(authority, Bench.projectB).reviewed)
            let installed = try #require(try await Bench.state(authority).installed)
            #expect(reviewB != installed && reviewB.prepared == installed.prepared)
            try await Bench.begin(authority)
            await engine.drain(authority)
            let attemptA = try engine.requireNext()
            let verdict = await answer(authority, &engine, attemptA, as: Bench.runningPlan)
            guard case .success(.refusedReclaimed(let refused, refusal: .preparedIDInUse)) = verdict else {
                Issue.record("Same-project collision must be consumed and reclaimed")
                return
            }
            #expect(try await Bench.state(authority).phase == .idle)
            #expect(await authority.snapshot().outstanding.isEmpty)
            try await authority.cancel(project: Bench.projectB).get()
            #expect(await engine.drain(authority) == [.discard(refused), .discard(reviewB)])
            #expect(engine.held.count == 1 && engine.held[0].matches(installed))
        }

        @Test func openResumesOnlySettledPlanlessLifecycles() async throws {
            let authority = try await Bench.makeAuthority()
            let before = await authority.snapshot()
            let idle = RunningGraph(revision: .initial, prepared: nil)
            let invalid: [EngineLifecycle] = [
                .preparing(try ContractRevision.initial.next(), over: .absent), .heldByOther(Bench.projectA),
                .running, .degraded([Bench.audio])
            ]
            for lifecycle in invalid {
                let opened = await authority.open(project: Bench.projectC, running: idle, lifecycle: lifecycle)
                #expect(Bench.refusal(opened)
                        == .lifecycleNotResumable(lifecycle))
            }
            // Lifecycle validation still precedes raw-resident rejection.
            for lifecycle in invalid.prefix(2) {
                let raw = RunningGraph(revision: .initial, prepared: Bench.runningPlan)
                let opened = await authority.open(project: Bench.projectC, running: raw, lifecycle: lifecycle)
                #expect(Bench.refusal(opened) == .lifecycleNotResumable(lifecycle))
            }
            for lifecycle in [EngineLifecycle.running, .degraded([Bench.audio]), .stopped, .recovering] {
                let raw = RunningGraph(revision: .initial, prepared: Bench.runningPlan)
                #expect(Bench.refusal(await authority.open(project: Bench.projectC, running: raw, lifecycle: lifecycle))
                        == .unqualifiedResident)
            }
            #expect(await authority.snapshot() == before)
            try await authority.open(project: Bench.projectC, running: idle, lifecycle: .stopped).get()
            #expect(try await Bench.state(authority, Bench.projectC).lifecycle == .stopped)
        }

        @Test func queuedDiscardDoesNotPoisonQualifiedReuse() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let late = try await beginAndAbandon(authority, &engine)
            let name = try await Bench.review(authority, &engine, project: Bench.projectB)
            let cancelled = try #require(try await Bench.state(authority, Bench.projectB).reviewed)
            try await Bench.begin(authority)
            await engine.drain(authority)
            let current = try engine.requireNext()
            try await authority.cancel(project: Bench.projectB).get()
            let old = try reclaimed(await answer(authority, &engine, late, as: name))
            #expect(await authority.snapshot().queue.pending == [.discard(cancelled), .discard(old)])
            // The new answer is adopted while BOTH aliasing discards remain queued.
            #expect(await answer(authority, &engine, current, as: name) == .success(.routed))
            #expect(await authority.snapshot().queue.pending == [.discard(cancelled), .discard(old)])
            await engine.drain(authority)
            #expect(engine.discarded == [cancelled, old])
            #expect(try await Bench.state(authority).reviewed?.prepared == name)
            #expect(engine.held.contains(.init(preparation: current, id: name)))
        }

        @Test func beginAtTheLastRevisionOverflowsBeforeTheTransition() async throws {
            let authority = try await Bench.makeAuthority()
            let last = try ContractRevision(ContractRevision.maximumValue)
            try await authority.open(
                project: Bench.projectC, running: RunningGraph(revision: last, prepared: nil)
            ).get()
            let before = await authority.snapshot()
            #expect(Bench.refusal(await authority.begin(Bench.request(base: last), candidate: Bench.candidate(),
                                                        projectDocument: Bench.projectDocument(
                                                            project: Bench.projectC, candidate: Bench.candidate()),
                                                        project: Bench.projectC)) == .activation(.overflow))
            #expect(await authority.snapshot() == before)
        }

        @Test func prepareAnswerRoutesByQualifiedAttempt() async throws {
            var engine = try ScriptedActivationEngine(failing: [2: .prepareFailed])
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.begin(authority)
            try await Bench.begin(authority, project: Bench.projectB)
            await engine.drain(authority)
            let attemptA = try engine.requireNext()
            let attemptB = try engine.requireNext()
            let answerB = engine.scriptedAnswer()
            #expect(await answer(authority, &engine, attemptB, as: try answerB.get()) == .success(.routed))
            let stateA = try await Bench.state(authority)
            #expect(stateA.phase == .preparing)
            #expect(stateA.lifecycle == .preparing(try stateA.running.revision.next(), over: .running))
            #expect(try await Bench.state(authority, Bench.projectB).lifecycle
                    == .preparing(try ContractRevision.initial.next(), over: .absent))
            let answerA = engine.scriptedAnswer()
            #expect(answerA == .failure(.engineRefused))
            let cleaned = engine.terminalFailure(attemptA, reason: .engineRefused)
            #expect(await authority.prepareAnswered(cleaned, instance: attemptA.instance,
                                                     attempt: attemptA.attempt) == .success(.routed))
            #expect(try await Bench.state(authority).phase == .prepareFailed(.engineRefused))
            #expect(try await Bench.state(authority).lifecycle == .running)
            #expect(try await Bench.state(authority, Bench.projectB).phase == .awaitingReview)
            #expect(pendingCount(await authority.snapshot()) == 0)
        }

        @Test func fullQueueRefusesBeginAndCancelUnchanged() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.review(authority, &engine)
            try await Bench.fillQueue(authority)
            let full = await authority.snapshot()
            #expect(full.queue.count == EngineCommandQueue.capacity)
            #expect(Bench.refusal(await authority.begin(Bench.request(), candidate: Bench.candidate(),
                                                        projectDocument: Bench.projectDocument(
                                                            project: Bench.projectB, candidate: Bench.candidate()),
                                                        project: Bench.projectB)) == .queueFull)
            #expect(Bench.refusal(await authority.cancel(project: Bench.projectA)) == .queueFull)
            #expect(await authority.snapshot() == full)
        }

        @Test func recoveringEngineNeverShowsPreparing() async throws {
            let authority = try await Bench.makeAuthority(lifecycleA: .recovering, recoveryBaseA: .absent)
            try await Bench.begin(authority)
            #expect(try await Bench.state(authority).phase == .preparing)
            #expect(try await Bench.state(authority).lifecycle == .recovering)
            try await authority.abandonPrepare(project: Bench.projectA).get()
            #expect(try await Bench.state(authority).lifecycle == .recovering)
        }
    }
}
