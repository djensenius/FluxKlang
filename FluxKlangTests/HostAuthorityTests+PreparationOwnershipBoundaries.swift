import Testing
@testable import FluxKlang

private typealias Bench = PreparationOwnershipBench
private typealias Routing = AudioRoutingTestFixtures

extension HostAuthorityTests {
    struct PreparationOwnershipBoundaries {
        @Test func rawPullAndExternalAnswersCannotReleasePendingCapacity() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            for constructed in [false, true] {
                if constructed { _ = try await Bench.retain(authority, identity) }
                let before = await authority.snapshot()
                #expect(await authority.nextEngineCommand() == nil)
                for answer: Result<PreparedActivationID, PrepareFailure> in [
                    .failure(.cancelled), .failure(.engineRefused), .success(.init(validated: "prep.forged"))
                ] {
                    #expect(AuthorityBench.refusal(await authority.prepareAnswered(
                        answer, instance: identity.instance, attempt: identity.attempt
                    )) == .preparationOnly)
                }
                #expect(AuthorityBench.refusal(await authority.cancel(project: documents.project.id)) ==
                    .preparationOnly)
                #expect(AuthorityBench.refusal(await authority.authorize(
                    project: documents.project.id, gesture: AuthorityBench.gesture()
                )) == .preparationOnly)
                #expect(await authority.snapshot() == before)
            }
            try await authority.abandonPrepare(project: documents.project.id).get()
            let before = await authority.snapshot()
            #expect(AuthorityBench.refusal(await authority.prepareAnswered(
                .failure(.cancelled), instance: identity.instance, attempt: identity.attempt
            )) == .preparationOnly)
            #expect(AuthorityBench.refusal(await authority.begin(
                Bench.request(documents.graph), candidate: documents.graph,
                projectDocument: documents.project, project: documents.project.id
            )) == .plans(.capacityReached))
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .disposed(.dropped))
        }

        @Test func queuedWorkCannotBypassOccupiedResourceOrEvaluation() async throws {
            let first = Routing.documents()
            var second = Routing.documents()
            second.project.id = AuthorityBench.projectB
            let authority = try await Bench.authority(first, capacity: 2)
            try await authority.open(project: second.project.id,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let owned = try await Bench.begin(authority, first)
            _ = try await Bench.retain(authority, owned)
            let queued = try await Bench.begin(authority, second)
            let before = await authority.snapshot()
            #expect(await authority.constructNextPreparation() == .refused(.occupied))
            #expect(await authority.evaluatePreparation(owned, frames: 0, input: Array(repeating: 0, count: 8)) ==
                .failure(.blocked))
            #expect(await authority.nextEngineCommand() == nil)
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(owned) == .disposed(.routed))
            #expect(await authority.snapshot().queue == before.queue)
            _ = try await Bench.retain(authority, queued)
            #expect(await authority.disposePreparation(queued) == .disposed(.routed))
        }

        @Test func reclaimedHeadCancelsWithoutInvokingInvalidConstructor() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents, limits: Routing.limits(frames: 0))
            let identity = try await Bench.begin(authority, documents)
            try await authority.abandonPrepare(project: documents.project.id).get()
            #expect(await authority.constructNextPreparation() == .terminated(identity, .cancelled, .dropped))
            #expect(await authority.snapshot().plans.records[0].entries.isEmpty)
            #expect(await authority.constructNextPreparation() == .empty)
            #expect(await authority.disposePreparation(identity) == .refused(.missing))
        }

        @Test func actualConstructorRejectionIsTerminalAndAllowsNewAdmission() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents, limits: Routing.limits(terms: 0))
            for _ in 0..<2 {
                let identity = try await Bench.begin(authority, documents)
                #expect(await authority.constructNextPreparation() == .terminated(identity, .engineRefused, .routed))
                let after = await authority.snapshot()
                #expect(after.projects[documents.project.id]?.phase == .prepareFailed(.engineRefused))
                #expect(after.plans.records[0].entries.isEmpty && after.queue.isEmpty && after.outstanding.isEmpty)
                #expect(await authority.disposePreparation(identity) == .refused(.missing))
                #expect(await authority.evaluatePreparation(identity, frames: 0, input: []) == .failure(.missing))
            }
        }

        @Test func pendingOutputIsPreservedBeforeOccupancyAndDisposalStillWorks() async throws {
            let documents = Routing.documents()
            for constructed in [false, true] {
                let authority = try await Bench.authority(documents)
                let token = try await authority.acquire(project: documents.project.id, window: AuthorityBench.windowA)
                    .get().token
                let identity = try await Bench.begin(authority, documents)
                if constructed { _ = try await Bench.retain(authority, identity) }
                _ = try await authority.leaseLost(token).get()
                let before = await authority.snapshot()
                #expect(before.pendingOutput == true && before.outputsMuted)
                #expect(await authority.nextEngineCommand() == nil)
                #expect(await authority.constructNextPreparation() == .refused(.blocked))
                if constructed {
                    #expect(await authority.evaluatePreparation(
                        identity, frames: 0, input: Array(repeating: 0, count: 8)
                    ) == .failure(.blocked))
                }
                #expect(await authority.snapshot() == before)
                if constructed {
                    #expect(await authority.disposePreparation(identity) == .disposed(.routed))
                    let after = await authority.snapshot()
                    #expect(after.pendingOutput == before.pendingOutput && after.queue == before.queue)
                    #expect(after.projects[documents.project.id]?.lifecycle == .recovering)
                }
                // Unconstructed blocked admission owns no resource; unsupported
                // work may remain pending indefinitely without a fabricated ACK.
            }
        }

        @Test func unsupportedRestoreHeadAndExternalCompletionRemainUntouched() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let recovering = AuthorityBench.projectB
            try await authority.open(project: recovering, running: RunningGraph(revision: .initial, prepared: nil),
                                     lifecycle: .recovering).get()
            _ = try await authority.acquire(project: recovering, window: AuthorityBench.windowB).get()
            let restore = try #require(await authority.snapshot().restoring)
            let identity = try await Bench.begin(authority, documents)
            let before = await authority.snapshot()
            #expect(before.pendingOutput == nil)
            #expect(before.queue.pending.first == AuthorityBench.restoreCommand(restore))
            #expect(before.queue.count == 2)
            #expect(await authority.constructNextPreparation() == .refused(.blocked))
            #expect(await authority.nextEngineCommand() == nil)
            #expect(AuthorityBench.refusal(await AuthorityBench.acknowledge(restore, on: authority)) ==
                .preparationOnly)
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .refused(.missing))
        }

        @Test func restorationBlocksEvaluationButNotExplicitCleanup() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            let recovering = AuthorityBench.projectB
            try await authority.open(project: recovering, running: RunningGraph(revision: .initial, prepared: nil),
                                     lifecycle: .recovering).get()
            _ = try await authority.acquire(project: recovering, window: AuthorityBench.windowB).get()
            let before = await authority.snapshot()
            #expect(before.restoring != nil && before.pendingOutput == nil)
            #expect(await authority.evaluatePreparation(
                identity, frames: 0, input: Array(repeating: 0, count: 8)
            ) == .failure(.blocked))
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            let after = await authority.snapshot()
            #expect(after.queue == before.queue && after.restoring == before.restoring)
            #expect(after.plans.records[0].entries.isEmpty)
        }

        @Test func closedAdmissionStillRequiresCompleteProjectContext() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            var invalid = documents.project
            invalid.roles.removeAll()
            let before = await authority.snapshot()
            let role = try #require(documents.graph.nodes[0].role)
            #expect(AuthorityBench.refusal(await authority.begin(
                Bench.request(documents.graph), candidate: documents.graph,
                projectDocument: invalid, project: documents.project.id
            )) == .preparationProject(.selected(.missingRole(
                documents.graph.id, node: documents.graph.nodes[0].id, role
            ))))
            #expect(await authority.snapshot() == before)
            #expect(await authority.constructNextPreparation() == .empty)
            let identity = try await Bench.begin(authority, documents)
            #expect(identity.attempt.generation == .initial)
            _ = try await Bench.retain(authority, identity)
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
        }

        @Test func legacyRegressionAndForeignReportsCannotEnterClosedMode() async throws {
            let documents = Routing.documents()
            // Legacy-only values exercise all closed report gates, not a backend
            // substitute for closed custody. No legacy resident is imported.
            let legacy = try await Bench.authority(documents, limits: nil)
            let lease = try await legacy.acquire(project: documents.project.id, window: AuthorityBench.windowA).get()
            let old = try await Bench.begin(legacy, documents)
            let queued = await legacy.snapshot()
            #expect(await legacy.constructNextPreparation() == .refused(.legacyMode))
            #expect(await legacy.disposePreparation(old) == .refused(.legacyMode))
            #expect(await legacy.evaluatePreparation(old, frames: 0, input: []) == .failure(.legacyMode))
            #expect(await legacy.snapshot() == queued)
            #expect(await legacy.nextEngineCommand() == .prepare(
                documents.graph, documents.project, old.instance, old.attempt
            ))
            let prepared = PreparedActivationID(validated: "prep.legacy.inert")
            #expect(try await legacy.prepareAnswered(.success(prepared), instance: old.instance, attempt: old.attempt)
                .get() == .routed)
            let authorization = try await legacy.authorize(
                project: documents.project.id, gesture: AuthorityBench.gesture()
            ).get()
            try await legacy.commit(project: documents.project.id, authorization: authorization).get()
            let state = await legacy.snapshot()
            let binding = try #require(state.projects[documents.project.id]?.reviewed)
            let attempt = try #require(state.projects[documents.project.id]?.lastCommitAttempt)
            let report = ActivationCommitReport(prepared: prepared, attempt: attempt, outcome: .succeeded,
                                                applied: Set(documents.graph.nodes.map(\.id)), unapplied: [])
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            let before = await authority.snapshot()
            #expect(AuthorityBench.refusal(await authority.open(
                project: AuthorityBench.projectB, running: RunningGraph(revision: .initial, prepared: binding.prepared)
            )) == .unqualifiedResident)
            #expect(AuthorityBench.refusal(await authority.retired(binding)) == .preparationOnly)
            #expect(AuthorityBench.refusal(await authority.commitReported(report)) == .preparationOnly)
            #expect(AuthorityBench.refusal(await authority.abandonCommit(attempt, reason: .outcomeUnknown)) ==
                .preparationOnly)
            #expect(AuthorityBench.refusal(await authority.commit(
                project: documents.project.id, authorization: authorization
            )) == .preparationOnly)
            #expect(AuthorityBench.refusal(await authority.restoreCompleted(
                attempt: RestoreAttemptID(), revision: .initial, target: .empty(identity.instance), token: lease.token
            )) == .preparationOnly)
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            #expect(await legacy.nextEngineCommand() == .commit(binding, attempt, lease.token))
            #expect(try await legacy.commitReported(report).get() == .acknowledged(try documents.graph.revision.next()))
        }
    }
}
