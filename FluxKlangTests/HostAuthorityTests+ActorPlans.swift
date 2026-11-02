import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    struct ActorPlans {
        @Test func defaultCapacityAndFirstRealBootstrap() async throws {
            let generations = try GenerationLedger(primaryClock: .init(validated: "smp.plans"), musicalClock: nil,
                                                   nominalRate: 48_000)
            let authority = try HostAuthority(host: generations, live: Bench.liveState())
            #expect(await authority.snapshot().plans.capacity == 64)
            #expect(throws: HostAuthorityRefusal.plans(.invalidCapacity)) {
                try HostAuthority(host: generations, live: Bench.liveState(), planCapacity: 0)
            }
            var engine = try ScriptedActivationEngine()
            let bootstrapped = try await Bench.makeAuthority(&engine, planCapacity: 64)
            let snapshot = await bootstrapped.snapshot()
            let state = try #require(snapshot.projects[Bench.projectA])
            let installed = try #require(state.installed)
            #expect(state.running.prepared == installed.prepared && state.reviewed == nil)
            #expect(snapshot.plans.records[0].entries == [
                .init(attempt: installed.attempt, state: .bound(installed, .committed))
            ])
            #expect(snapshot.queue.isEmpty && snapshot.retirementOutbox.isEmpty && snapshot.inFlight.isEmpty)
            #expect(engine.discarded.isEmpty && engine.held.count == 1 && engine.held[0].matches(installed))
            let before = await bootstrapped.snapshot()
            #expect(Bench.refusal(await bootstrapped.retired(installed)) == .plans(.notRetiring))
            #expect(await bootstrapped.snapshot() == before)
        }

        @Test func transactionRefusedSuccessUsesOutboxAtFullQueue() async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            let installed = try #require(try await Bench.state(authority).installed)
            try await Bench.begin(authority)
            await engine.drain(authority)
            let preparation = try engine.requireNext()
            let answer = engine.prepare(preparation, as: installed.prepared)
            try await Bench.fillQueue(authority)
            let full = await authority.snapshot()
            let outcome = await authority.prepareAnswered(answer, instance: preparation.instance,
                                                          attempt: preparation.attempt)
            guard case .success(.refusedReclaimed(let retired, refusal: .preparedIDInUse)) = outcome else {
                Issue.record("Refused resource must be consumed, not a state-preserving failure")
                return
            }
            let after = await authority.snapshot()
            #expect(after.queue == full.queue && after.retirementOutbox == [retired])
            #expect(after.projects[Bench.projectA]?.installed == installed && retired != installed)
            #expect(after.projects[Bench.projectA]?.reviewed == nil && after.outstanding[Bench.projectA] == nil)
            #expect(after.projects[Bench.projectA]?.phase == .idle)
            #expect(Bench.refusal(await authority.retired(retired)) == .retirementQueued)
            #expect(Bench.refusal(await authority.prepareAnswered(answer, instance: preparation.instance,
                                                                  attempt: preparation.attempt))
                    == .activation(.stalePrepareResponse))
            #expect(await authority.snapshot() == after)
            await engine.drain(authority)
            #expect(engine.discarded == [retired] && engine.held.contains { $0.matches(installed) })
        }

        @Test func everyStaleCommitDequeueRefillsBeforeContinuing() async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            try await authority.open(project: Bench.projectC, running: RunningGraph(revision: .initial, prepared: nil))
                .get()
            var late: [(HostPrepare, Result<PreparedActivationID, PrepareFailure>)] = []
            for index in 0..<3 {
                try await Bench.begin(authority, project: Bench.projectC)
                await engine.drain(authority)
                let preparation = try engine.requireNext()
                let answer = engine.prepare(preparation, as: try PreparedActivationID("prep.late.\(index)"))
                late.append((preparation, answer))
                try await authority.abandonPrepare(project: Bench.projectC).get()
            }
            _ = try await Bench.commitQueued(authority, &engine)
            let dependent = try #require(try await Bench.state(authority).reviewed)
            let attemptA = try await Bench.attempt(authority)
            try await authority.abandonCommit(attemptA, reason: .outcomeUnknown).get()
            // A stale commit followed by a mute exercises the multi-dequeue path.
            try await Bench.fillQueue(authority, with: Bench.projectC)
            var retired: [PlanBinding] = []
            for (preparation, answer) in late {
                let result = try await authority.prepareAnswered(answer, instance: preparation.instance,
                                                                 attempt: preparation.attempt).get()
                if case .reclaimed(let binding) = result { retired.append(binding) }
            }
            #expect(retired.count == 3)
            let full = await authority.snapshot()
            #expect(full.retirementOutbox == retired && full.queue.count == EngineCommandQueue.capacity)
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            let after = await authority.snapshot()
            // BOTH the stale commit and the returned mute freed and refilled a slot.
            #expect(after.queue.count == EngineCommandQueue.capacity)
            #expect(after.retirementOutbox == Array(retired.dropFirst(2)))
            #expect(Array(after.queue.pending.suffix(2)) == Array(retired.prefix(2)).map(EngineCommand.discard))
            await engine.drain(authority)
            #expect(engine.discarded == [dependent] + retired && engine.disposed.count == 4)
            #expect(await authority.snapshot().retirementOutbox.isEmpty)
        }

        @Test func withholdingCommitToMuteAlsoRefills() async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.begin(authority, project: Bench.projectB)
            await engine.drain(authority)
            let late = try engine.requireNext()
            let answer = engine.prepare(late, as: .init(validated: "prep.late"))
            try await authority.abandonPrepare(project: Bench.projectB).get()
            _ = try await Bench.commitQueued(authority, &engine)
            try await authority.release(project: Bench.projectA).get()
            try await Bench.fillQueue(authority)
            let result = try await authority.prepareAnswered(
                answer, instance: late.instance, attempt: late.attempt
            ).get()
            guard case .reclaimed(let binding) = result else {
                Issue.record("Expected late reclaim")
                return
            }
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            let after = await authority.snapshot()
            #expect(after.queue.count == EngineCommandQueue.capacity && after.retirementOutbox.isEmpty)
            #expect(after.queue.pending.last == .discard(binding))
            #expect(after.projects[Bench.projectA]?.lifecycle == .recovering)
            await engine.drain(authority)
            #expect(engine.discarded == [binding])
        }
    }
}
