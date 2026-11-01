import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    struct RestoreReview {
        @Test func restoreDeliveryRejectsADifferentAttemptWithTheSameTuple() throws {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.restore.delivery"),
                                              musicalClock: nil, nominalRate: 48_000)
            // A separate book exercises the guard without an actor command-injection API.
            var book = try HostAuthorityBook(host: ledger, live: Bench.liveState())
            try book.open(project: Bench.projectA,
                          running: RunningGraph(revision: .initial, prepared: Bench.runningPlan),
                          lifecycle: .recovering).get()
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
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.restoring(.initial)))
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
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.restoring(.initial)))
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
    }
}
