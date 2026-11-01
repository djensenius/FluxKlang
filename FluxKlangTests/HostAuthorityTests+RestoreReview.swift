import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

enum RestoreLifecycleBaseline: CaseIterable, Sendable {
    case stopped
    case degraded

    var lifecycle: EngineLifecycle {
        switch self {
        case .stopped: .stopped
        case .degraded: .degraded([Bench.audio])
        }
    }

    var runningSet: RunningSetState {
        switch self {
        case .stopped: .absent
        case .degraded: .degraded([Bench.audio])
        }
    }
}

enum OpenRecoveryBaseline: CaseIterable, Sendable {
    case unknown
    case absent
    case running
    case degraded

    var recoveryBase: RunningSetState? {
        switch self {
        case .unknown: nil
        case .absent: .absent
        case .running: .running
        case .degraded: .degraded([Bench.audio])
        }
    }

    var lifecycle: EngineLifecycle {
        switch self {
        case .unknown, .absent: .stopped
        case .running: .running
        case .degraded: .degraded([Bench.audio])
        }
    }
}

extension HostAuthorityTests {
    struct RestoreReview {
        @Test func restoreDeliveryRejectsADifferentAttemptWithTheSameTuple() throws {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.restore.delivery"),
                                              musicalClock: nil, nominalRate: 48_000)
            // A separate book exercises the guard without an actor command-injection API.
            var book = try HostAuthorityBook(host: ledger, live: Bench.liveState())
            try book.open(project: Bench.projectA,
                          running: RunningGraph(revision: .initial, prepared: Bench.runningPlan),
                          lifecycle: .recovering, recoveryBase: .running).get()
            _ = try book.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let restore = try #require(book.restoring)
            let before = book.snapshot()
            let foreign = EngineCommand.restore(RestoreAttemptID(), restore.revision,
                                                restore.prepared, restore.token)
            let admittedForeign = book.admitRestore(foreign)
            #expect(!admittedForeign)
            #expect(book.snapshot() == before)
            let delivered = book.nextEngineCommand()
            #expect(delivered == .restore(
                restore.attempt, restore.revision, restore.prepared, restore.token
            ))
            #expect(book.restoring?.delivered == true)
        }

        @Test func repeatedOutcomeUnknownRestoreRejectsReplayedAcknowledgement() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let lease = try await Bench.leaseToken(authority)

            _ = try await Bench.commitDelivered(authority, &engine)
            try await authority.abandonCommit(try await Bench.attempt(authority),
                                              reason: .outcomeUnknown).get()
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            let firstQueued = await authority.snapshot()
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectA)) == .activation(.busy))
            #expect(await authority.snapshot() == firstQueued)
            let firstCommands = await engine.drain(authority)
            let firstRestore = try #require(engine.pendingRestores.first)
            #expect(firstCommands.count == 2 &&
                    firstCommands.first == .restore(firstRestore.attempt, .initial, Bench.runningPlan, lease))
            #expect(firstCommands.last.map { if case .discard = $0 { true } else { false } } == true)
            #expect(await engine.completeRestore(authority) == .success(.running))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])

            _ = try await Bench.commitDelivered(authority, &engine)
            try await authority.abandonCommit(try await Bench.attempt(authority),
                                              reason: .outcomeUnknown).get()
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            let secondQueued = await authority.snapshot()
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectA)) == .activation(.busy))
            #expect(await authority.snapshot() == secondQueued)
            #expect(await authority.snapshot().lease?.token == lease)
            let secondRestore = try #require(await authority.snapshot().restoring)
            #expect(secondRestore.attempt != firstRestore.attempt)

            let pending = await authority.snapshot()
            let earlyReplay = await authority.restoreCompleted(attempt: firstRestore.attempt,
                                                               revision: firstRestore.revision,
                                                               prepared: firstRestore.prepared,
                                                               token: firstRestore.token)
            #expect(Bench.refusal(earlyReplay) == .staleRestore)
            #expect(await authority.snapshot() == pending)
            #expect(pending.outputsMuted && pending.restoring?.delivered == false)

            let secondCommands = await engine.drain(authority)
            #expect(secondCommands.count == 2 && secondCommands.first == .restore(
                secondRestore.attempt, .initial, Bench.runningPlan, lease
            ))
            #expect(secondCommands.last.map { if case .discard = $0 { true } else { false } } == true)
            let delivered = await authority.snapshot()
            let lateReplay = await authority.restoreCompleted(attempt: firstRestore.attempt,
                                                              revision: firstRestore.revision,
                                                              prepared: firstRestore.prepared,
                                                              token: firstRestore.token)
            #expect(Bench.refusal(lateReplay) == .staleRestore)
            #expect(await authority.snapshot() == delivered)
            #expect(delivered.outputsMuted && delivered.restoring?.delivered == true)

            #expect(engine.pendingRestores.last?.attempt == secondRestore.attempt)
            #expect(await engine.completeRestore(authority) == .success(.running))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }

        @Test(arguments: [false, true])
        func firstCommitAfterRestoreAcknowledgementRendersOutput(awaitingReview: Bool) async throws {
            let authority = try await authorityWithNoRunningPlan()
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let newToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [.restore(restore.attempt, .initial, nil, newToken)])
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            let prepareAttempt = try #require(await authority.snapshot().outstanding[Bench.projectA])
            let prepareCommands = await engine.drain(authority)
            #expect(prepareCommands.count == 1 && prepareCommands.first.map {
                if case .prepare(_, let deliveredAttempt) = $0 { deliveredAttempt == prepareAttempt } else { false }
            } == true)

            if awaitingReview {
                #expect(try await engine.answerNext(authority)?.verdict.get() == .routed)
                #expect(try await Bench.state(authority).phase == .awaitingReview)
            } else {
                #expect(try await Bench.state(authority).phase == .preparing)
            }

            let nextRevision = try ContractRevision.initial.next()
            let expectedPreparing = EngineLifecycle.preparing(nextRevision, over: .absent)
            #expect(await engine.completeRestore(authority) == .success(expectedPreparing))
            let restored = await authority.snapshot()
            #expect(restored.projects[Bench.projectA]?.lifecycle == expectedPreparing)
            #expect(restored.projects[Bench.projectA]?.phase == (awaitingReview ? .awaitingReview : .preparing))
            let replay = await authority.restoreCompleted(attempt: restore.attempt, revision: restore.revision,
                                                          prepared: restore.prepared, token: restore.token)
            #expect(Bench.refusal(replay) == .staleRestore)
            #expect(await authority.snapshot() == restored)

            if !awaitingReview {
                #expect(try await engine.answerNext(authority)?.verdict.get() == .routed)
            }
            let reviewedPlan = try #require(await authority.snapshot().projects[Bench.projectA]?.reviewed)
            let authorization = try await authority.authorize(
                project: Bench.projectA, gesture: Bench.gesture()
            ).get()
            try await authority.commit(project: Bench.projectA, authorization: authorization).get()
            let commitCommands = await engine.drain(authority)
            #expect(commitCommands.contains {
                if case .commit(let prepared, _, let token) = $0 {
                    prepared == reviewedPlan && token == newToken
                } else {
                    false
                }
            })
            let report = try #require(await engine.report(authority, .succeeded))
            #expect(try report.verdict.get() == .acknowledged(nextRevision))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == .running)
            #expect((await authority.lifecycle(of: Bench.projectA, window: Bench.windowA))?.rendersOutput == true)
        }

        @Test func restoreWithoutPreparationReturnsToStoppedWithoutRunningPlan() async throws {
            let authority = try await authorityWithNoRunningPlan()
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [.restore(restore.attempt, .initial, nil, token)])
            #expect(await engine.completeRestore(authority) == .success(.stopped))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == .stopped)
            #expect((await authority.lifecycle(of: Bench.projectA, window: Bench.windowA))?.rendersOutput == false)
        }

        @Test(arguments: RestoreLifecycleBaseline.allCases)
        func settledRestorePreservesPreRecoveryLifecycle(_ baseline: RestoreLifecycleBaseline) async throws {
            let authority = try await Bench.makeAuthority(lifecycleA: baseline.lifecycle)
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            #expect(await authority.snapshot().projects[Bench.projectA]?.recoveryBase == baseline.runningSet)
            let interimToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let interimRestore = try #require(await authority.snapshot().restoring)
            _ = try await authority.leaseLost(interimToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(await authority.snapshot().projects[Bench.projectA]?.recoveryBase == baseline.runningSet)

            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(restore.attempt != interimRestore.attempt)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, .initial, Bench.runningPlan, token)
            ])
            #expect(await engine.completeRestore(authority) == .success(baseline.lifecycle))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == baseline.lifecycle)
        }

        @Test(arguments: OpenRecoveryBaseline.allCases)
        func openedRecoveryUsesOnlyExplicitSavedBase(_ baseline: OpenRecoveryBaseline) async throws {
            let authority = try await Bench.makeAuthority(
                lifecycleA: .recovering, recoveryBaseA: baseline.recoveryBase
            )
            let saved = try #require(await authority.snapshot().projects[Bench.projectA]?.recoveryBase)
            #expect(saved == (baseline.recoveryBase ?? .absent))
            var engine = try ScriptedActivationEngine()
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, .initial, Bench.runningPlan, restore.token)
            ])
            #expect(await engine.completeRestore(authority) == .success(baseline.lifecycle))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == baseline.lifecycle)
        }

        @Test func invalidRecoveryBaseOpenRefusalsChangeNothing() throws {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.restore.open.base"),
                                              musicalClock: nil, nominalRate: 48_000)
            var book = try HostAuthorityBook(host: ledger, live: Bench.liveState())
            let noPlan = RunningGraph(revision: .initial, prepared: nil)

            let before = book.snapshot()
            #expect(Bench.refusal(book.open(project: Bench.projectA, running: noPlan,
                                            lifecycle: .stopped, recoveryBase: .absent)) == .invalidRecoveryBase)
            #expect(book.snapshot() == before)
            #expect(Bench.refusal(book.open(project: Bench.projectA, running: noPlan,
                                            lifecycle: .recovering, recoveryBase: .running)) == .invalidRecoveryBase)
            #expect(book.snapshot() == before)
            #expect(Bench.refusal(book.open(project: Bench.projectA, running: noPlan,
                                            lifecycle: .recovering,
                                            recoveryBase: .degraded([Bench.audio]))) == .invalidRecoveryBase)
            #expect(book.snapshot() == before)
        }

        @Test(arguments: [false, true])
        func preparationRestorePreservesItsPreRecoveryRunningSet(awaitingReview: Bool) async throws {
            for baseline in RestoreLifecycleBaseline.allCases {
                let authority = try await Bench.makeAuthority(lifecycleA: baseline.lifecycle)
                var engine = try ScriptedActivationEngine()
                let oldToken = try await Bench.leaseToken(authority)
                _ = try await authority.leaseLost(oldToken).get()
                #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
                #expect(await authority.snapshot().projects[Bench.projectA]?.recoveryBase == baseline.runningSet)

                let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
                let restore = try #require(await authority.snapshot().restoring)
                #expect(await engine.drain(authority) == [
                    .restore(restore.attempt, .initial, Bench.runningPlan, token)
                ])
                try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
                let prepareCommands = await engine.drain(authority)
                #expect(prepareCommands.count == 1 && prepareCommands.first.map {
                    if case .prepare = $0 { true } else { false }
                } == true)

                if awaitingReview {
                    #expect(try await engine.answerNext(authority)?.verdict.get() == .routed)
                    #expect(try await Bench.state(authority).phase == .awaitingReview)
                }

                let expected = EngineLifecycle.preparing(
                    try ContractRevision.initial.next(), over: baseline.runningSet
                )
                #expect(await engine.completeRestore(authority) == .success(expected))
                #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == expected)
            }
        }

        @Test(arguments: [false, true])
        func leaseLossDuringPreparationKeepsItsPriorRenderingState(awaitingReview: Bool) async throws {
            for baseline in RestoreLifecycleBaseline.allCases {
                let authority = try await Bench.makeAuthority(lifecycleA: baseline.lifecycle)
                var engine = try ScriptedActivationEngine()
                try await authority.begin(Bench.request(), candidate: Bench.candidate(),
                                          project: Bench.projectA).get()
                #expect((await engine.drain(authority)).count == 1)
                if awaitingReview {
                    #expect(try await engine.answerNext(authority)?.verdict.get() == .routed)
                    #expect(try await Bench.state(authority).phase == .awaitingReview)
                }

                let token = try await Bench.leaseToken(authority)
                _ = try await authority.leaseLost(token).get()
                #expect(await authority.snapshot().projects[Bench.projectA]?.recoveryBase == baseline.runningSet)
                #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

                let nextToken = try await authority.acquire(
                    project: Bench.projectA, window: Bench.windowA
                ).get().token
                let restore = try #require(await authority.snapshot().restoring)
                #expect(await engine.drain(authority) == [
                    .restore(restore.attempt, .initial, Bench.runningPlan, nextToken)
                ])
                let expected = EngineLifecycle.preparing(
                    try ContractRevision.initial.next(), over: baseline.runningSet
                )
                #expect(await engine.completeRestore(authority) == .success(expected))
                #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == expected)
            }
        }

        @Test func keepingFirstPartialStartsRendering() async throws {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.restore.first"),
                                              musicalClock: nil, nominalRate: 48_000)
            let authority = try HostAuthority(host: ledger, live: Bench.liveState())
            try await authority.open(project: Bench.projectA,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            try await authority.open(project: Bench.projectB,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            var engine = try ScriptedActivationEngine()

            let partialPlan = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()
            let revision = try ContractRevision.initial.next()
            #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.keptPartial(revision)))
            #expect(await authority.snapshot().projects[Bench.projectA]?.running.prepared == partialPlan)
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == .running)
            #expect((await authority.lifecycle(of: Bench.projectA, window: Bench.windowA))?.rendersOutput == true)
        }

        @Test func keepingPartialPreservesDegradedLifecycle() async throws {
            let authority = try await Bench.makeAuthority(lifecycleA: .degraded([Bench.audio]))
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()

            let revision = try ContractRevision.initial.next()
            #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.keptPartial(revision)))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == .degraded([Bench.audio]))
        }

        private func authorityWithNoRunningPlan() async throws -> HostAuthority {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.restore.preparing"),
                                              musicalClock: nil, nominalRate: 48_000)
            let authority = try HostAuthority(host: ledger, live: Bench.liveState())
            try await authority.open(project: Bench.projectA,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            try await authority.open(project: Bench.projectB,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            return authority
        }
    }

    struct ActorRestoreOpening {
        @Test func deferredRestorePlanCannotBeOpened() async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, failedPlan) = try await authorityWithDeferredRestoreDiscard(&engine)
            let before = await authority.snapshot()
            let result = await authority.open(
                project: Bench.projectC, running: RunningGraph(revision: .initial, prepared: failedPlan)
            )
            #expect(Bench.refusal(result) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
        }
    }
}
