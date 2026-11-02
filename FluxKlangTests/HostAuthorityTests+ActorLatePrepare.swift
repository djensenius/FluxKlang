import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench
private let reused = PreparedActivationID(validated: "prep.reused")

enum LatePrepareReuse: CaseIterable, Sendable { case sameProject, crossProject }
enum LatePrepareOrder: CaseIterable, Sendable { case lateFirst, lateFirstThenDrain, newerFirst }

private func take(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                  project: ProjectID = Bench.projectA, withAux: Bool = false) async throws -> HostPrepare {
    try await Bench.begin(authority, project: project, withAux: withAux)
    await engine.drain(authority)
    return try engine.requireNext()
}

private func send(_ authority: HostAuthority, _ answer: Result<PreparedActivationID, PrepareFailure>,
                  for preparation: HostPrepare) async -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
    await authority.prepareAnswered(answer, instance: preparation.instance, attempt: preparation.attempt)
}

extension HostAuthorityTests {
    struct ActorLatePrepare {
        @Test func cancellingNewAliasNeverDisposesOlderLostPreparation() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let old = try await take(authority, &engine)
            let late = engine.prepare(old, as: reused)
            try await authority.abandonPrepare(project: Bench.projectA).get()
            let newer = try await take(authority, &engine)
            let current = engine.prepare(newer, as: reused)
            #expect(await send(authority, current, for: newer) == .success(.routed))
            let binding = try #require(try await Bench.state(authority).reviewed)
            try await authority.cancel(project: Bench.projectA).get()
            let cancelled = await authority.snapshot()
            #expect(Bench.refusal(await authority.cancel(project: Bench.projectA))
                    == .activation(.unexpectedPhase(.idle)))
            #expect(await authority.snapshot() == cancelled)
            #expect(await engine.drain(authority) == [.discard(binding)])
            #expect(engine.disposed == [.init(preparation: newer, id: reused)])
            #expect(engine.held.contains(.init(preparation: old, id: reused)))
            let result = try await send(authority, late, for: old).get()
            guard case .reclaimed(let oldBinding) = result else {
                Issue.record("Expected old resource to remain reclaimable")
                return
            }
            await engine.drain(authority)
            #expect(engine.discarded == [binding, oldBinding])
            #expect(engine.disposed == [.init(preparation: newer, id: reused), .init(preparation: old, id: reused)])
        }

        @Test(arguments: LatePrepareReuse.allCases, LatePrepareOrder.allCases)
        func lateSuccessDisposesOnlyItsQualifiedPreparation(_ reuse: LatePrepareReuse,
                                                            _ order: LatePrepareOrder) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let old = try await take(authority, &engine)
            let late = engine.prepare(old, as: reused)
            try await authority.abandonPrepare(project: Bench.projectA).get()
            let project = reuse == .sameProject ? Bench.projectA : Bench.projectB
            let newer = try await take(authority, &engine, project: project)
            let current = engine.prepare(newer, as: reused)
            if order == .newerFirst { #expect(await send(authority, current, for: newer) == .success(.routed)) }
            let before = await authority.snapshot()
            let verdict = await send(authority, late, for: old)
            guard case .success(.reclaimed(let binding)) = verdict else {
                Issue.record("Expected qualified late retirement")
                return
            }
            #expect(binding.instance == old.instance && binding.attempt == old.attempt && binding.prepared == reused)
            let after = await authority.snapshot()
            #expect(after.projects == before.projects && after.outstanding == before.outstanding)
            #expect(after.queue.pending == before.queue.pending + [.discard(binding)])
            #expect(after.ledger == before.ledger && after.lease == before.lease)
            #expect(Bench.refusal(await send(authority, late, for: old)) == .activation(.stalePrepareResponse))
            #expect(await authority.snapshot() == after)
            if order == .lateFirstThenDrain { await engine.drain(authority) }
            if order != .newerFirst { #expect(await send(authority, current, for: newer) == .success(.routed)) }
            await engine.drain(authority)
            #expect(engine.discarded == [binding] && engine.disposed == [.init(preparation: old, id: reused)])
            #expect(engine.held.contains(.init(preparation: newer, id: reused)))
            let reviewing = try await Bench.state(authority, project)
            #expect(reviewing.phase == .awaitingReview && reviewing.reviewed?.attempt == newer.attempt)
            #expect(reviewing.reviewed?.prepared == reused)
        }

        @Test func lateSuccessNeverAuthorizesRawBootAdoption() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let old = try await take(authority, &engine)
            let late = engine.prepare(old, as: reused)
            try await authority.abandonPrepare(project: Bench.projectA).get()
            _ = try await send(authority, late, for: old).get()
            let before = await authority.snapshot()
            let running = RunningGraph(revision: .initial, prepared: reused)
            #expect(Bench.refusal(await authority.open(project: Bench.projectC, running: running))
                    == .unqualifiedResident)
            #expect(await authority.snapshot() == before)
            await engine.drain(authority)
            #expect(engine.disposed == [.init(preparation: old, id: reused)])
        }

        @Test func lateSuccessNeverNeedsQueueRoomAndRefillsFIFO() async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            let first = try await take(authority, &engine)
            let firstAnswer = engine.prepare(first, as: reused)
            try await authority.abandonPrepare(project: Bench.projectA).get()
            let second = try await take(authority, &engine)
            let secondAnswer = engine.prepare(second, as: reused)
            try await authority.abandonPrepare(project: Bench.projectA).get()
            try await Bench.fillQueue(authority)
            let full = await authority.snapshot()
            let firstResult = try await send(authority, firstAnswer, for: first).get()
            let secondResult = try await send(authority, secondAnswer, for: second).get()
            guard case .reclaimed(let one) = firstResult, case .reclaimed(let two) = secondResult else {
                Issue.record("Expected both late successes reclaimed")
                return
            }
            let queued = await authority.snapshot()
            #expect(queued.queue == full.queue && queued.projects == full.projects)
            #expect(queued.retirementOutbox == [one, two])
            #expect(Bench.refusal(await authority.retired(one)) == .retirementQueued)
            #expect(Bench.refusal(await send(authority, firstAnswer, for: first)) == .activation(.stalePrepareResponse))
            #expect(await authority.snapshot() == queued)
            // Read two commands directly to observe each refill, then deliver
            // the rest through the same engine that owns the retiring bindings.
            #expect(await authority.nextEngineCommand() == full.queue.pending[0])
            let afterOne = await authority.snapshot()
            #expect(afterOne.queue.count == EngineCommandQueue.capacity && afterOne.retirementOutbox == [two])
            #expect(afterOne.queue.pending.last == .discard(one))
            #expect(await authority.nextEngineCommand() == full.queue.pending[1])
            let afterTwo = await authority.snapshot()
            #expect(afterTwo.queue.count == EngineCommandQueue.capacity && afterTwo.retirementOutbox.isEmpty)
            #expect(Array(afterTwo.queue.pending.suffix(2)) == [.discard(one), .discard(two)])
            #expect(Bench.refusal(await authority.retired(one)) == .retirementQueued)
            let delivered = await engine.drain(authority)
            #expect(delivered == Array(full.queue.pending.dropFirst(2)) + [.discard(one), .discard(two)])
            #expect(engine.disposed == [.init(preparation: first, id: reused), .init(preparation: second, id: reused)])
            #expect(Bench.refusal(await authority.retired(one)) == .plans(.unknownAttempt))
            #expect(await authority.nextEngineCommand() == nil)
        }

        @Test func chosenReusedIDsKeepExactPreparationNodeCoverage() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let first = try await take(authority, &engine, project: Bench.projectB)
            let firstAnswer = engine.prepare(first, as: reused)
            #expect(await send(authority, firstAnswer, for: first) == .success(.routed))
            let second = try await take(authority, &engine, withAux: true)
            let secondAnswer = engine.prepare(second, as: reused)
            #expect(await send(authority, secondAnswer, for: second) == .success(.routed))
            let auth = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            try await authority.commit(project: Bench.projectA, authorization: auth).get()
            await engine.drain(authority)
            let report = try #require(await engine.report(authority, .partial))
            #expect(report.verdict == .success(.partial(unapplied: [Bench.nodeOut])))
            #expect(report.report.applied == [Bench.nodeAux] && report.report.unapplied == [Bench.nodeOut])
            #expect(engine.plannedNodes[first] == [Bench.nodeOut])
            #expect(engine.plannedNodes[second] == [Bench.nodeOut, Bench.nodeAux])
        }

        @Test func fixtureCapacityRecordsFailureRatherThanSilentSuccess() async throws {
            // Bootstrap occupies the only tracked preparation. Overflow is an
            // expected Testing issue, not permission to hide it from the test runner.
            var engine = try ScriptedActivationEngine(trackedLimit: 1)
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.begin(authority)
            await withKnownIssue("Deliberately exhaust qualified fixture tracking") {
                await engine.drain(authority)
            }
            #expect(engine.pending.isEmpty && engine.plannedNodes.count == 1)
            #expect(engine.anomalies == ["tracked preparations capacity"])
        }
    }
}
