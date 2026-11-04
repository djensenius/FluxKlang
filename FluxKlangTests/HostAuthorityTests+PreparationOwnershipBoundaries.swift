import Testing
@testable import FluxKlang

private typealias Bench = PreparationOwnershipBench
private typealias Routing = AudioRoutingTestFixtures

extension HostAuthorityTests {
    struct PreparationOwnershipBoundaries {
        @Test func maintenanceReclaimsIgnoredConstructionAndReusesCapacity() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents, capacity: 3)
            let identity = try await Bench.begin(authority, documents)
            _ = await authority.constructNextPreparation()
            try await authority.abandonPrepare(project: documents.project.id).get()
            let before = await authority.snapshot()
            #expect(AuthorityBench.refusal(await authority.begin(
                Bench.request(documents.graph), candidate: documents.graph,
                projectDocument: documents.project, project: documents.project.id
            )) == .preparationOccupied)
            #expect(await authority.snapshot() == before)
            #expect(await authority.reclaimAbandonedPreparation() == .terminated(identity, .cancelled, .dropped))
            #expect(await authority.snapshot().plans.records[0].entries.isEmpty)
            #expect(await authority.disposePreparation(identity) == .refused(.missing))
            #expect(await authority.reclaimAbandonedPreparation() == .empty)
            let next = try await Bench.begin(authority, documents)
            #expect(next != identity)
            _ = try await Bench.retain(authority, next)
            #expect(await authority.disposePreparation(next) == .disposed(.routed))
            // Capacity reuse is bookkeeping evidence, not measured deallocation.
        }

        @Test func maintenanceEmptyPreservesQueuedAbandonedAdmission() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            try await authority.abandonPrepare(project: documents.project.id).get()
            let before = await authority.snapshot()
            #expect(before.queue.count == 1)
            #expect(before.plans.records[0].entries == [
                .init(attempt: identity.attempt, state: .pending(reclaim: true))
            ])
            #expect(await authority.reclaimAbandonedPreparation() == .empty)
            #expect(await authority.snapshot() == before)
            #expect(await authority.constructNextPreparation() == .terminated(identity, .cancelled, .dropped))
        }

        @Test func maintenanceWantedRefusalPreservesRealCustody() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            let before = await authority.snapshot()
            for _ in 0..<3 {
                #expect(await authority.reclaimAbandonedPreparation() == .refused(.occupied))
                #expect(await authority.snapshot() == before)
            }
            // Explicit cleanup must still find the real private resource.
            #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            #expect(await authority.reclaimAbandonedPreparation() == .empty)
        }

        @Test func maintenanceConcurrentCallsTerminateExactlyOnce() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents)
            let identity = try await Bench.begin(authority, documents)
            _ = try await Bench.retain(authority, identity)
            try await authority.abandonPrepare(project: documents.project.id).get()
            let results = await withTaskGroup(of: OwnedPreparationStep.self) { group in
                for _ in 0..<12 { group.addTask { await authority.reclaimAbandonedPreparation() } }
                var results: [OwnedPreparationStep] = []
                for await result in group { results.append(result) }
                return results
            }
            #expect(results.filter { $0 == .terminated(identity, .cancelled, .dropped) }.count == 1)
            #expect(results.filter { $0 == .empty }.count == 11)
            #expect(await authority.snapshot().plans.records[0].entries.isEmpty)
            #expect(await authority.disposePreparation(identity) == .refused(.missing))
        }

        @Test func maintenanceReleasesReservationBeforeNewerOrCrossProjectAdmission() async throws {
            let first = Routing.documents()
            var second = Routing.documents()
            second.project.id = AuthorityBench.projectB
            let authority = try await Bench.authority(first, capacity: 3)
            try await authority.open(project: second.project.id,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let old = try await Bench.begin(authority, first)
            _ = try await Bench.retain(authority, old)
            try await authority.abandonPrepare(project: first.project.id).get()
            let before = await authority.snapshot()
            for documents in [first, second] {
                #expect(AuthorityBench.refusal(await authority.begin(
                    Bench.request(documents.graph), candidate: documents.graph,
                    projectDocument: documents.project, project: documents.project.id
                )) == .preparationOccupied)
                #expect(await authority.snapshot() == before)
            }
            #expect(await authority.reclaimAbandonedPreparation() == .terminated(old, .cancelled, .dropped))
            let after = await authority.snapshot()
            #expect(after.queue == before.queue && after.outstanding == before.outstanding)
            #expect(after.projects == before.projects)
            #expect(after.plans.records[0].entries == before.plans.records[0].entries.filter {
                $0.attempt != old.attempt
            })
            for documents in [first, second] {
                let identity = try await Bench.begin(authority, documents)
                #expect(identity != old)
                _ = try await Bench.retain(authority, identity)
                let retained = await authority.snapshot()
                #expect(await authority.reclaimAbandonedPreparation() == .refused(.occupied))
                #expect(await authority.snapshot() == retained)
                #expect(await authority.disposePreparation(old) == .refused(.identityMismatch))
                #expect(await authority.disposePreparation(identity) == .disposed(.routed))
            }
            #expect(await authority.reclaimAbandonedPreparation() == .empty)
        }

        @Test func maintenancePreservesMuteRestoreQueueAndRecoveryObligations() async throws {
            let documents = Routing.documents()
            for restoring in [false, true] {
                let authority = try await Bench.authority(documents)
                let identity = try await Bench.begin(authority, documents)
                _ = try await Bench.retain(authority, identity)
                if restoring {
                    try await authority.open(
                        project: AuthorityBench.projectB, running: RunningGraph(revision: .initial, prepared: nil),
                        lifecycle: .recovering
                    ).get()
                    _ = try await authority.acquire(project: AuthorityBench.projectB, window: AuthorityBench.windowB)
                        .get()
                } else {
                    let lease = try await authority.acquire(
                        project: documents.project.id, window: AuthorityBench.windowA
                    ).get()
                    _ = try await authority.leaseLost(lease.token).get()
                }
                try await authority.abandonPrepare(project: documents.project.id).get()
                let before = await authority.snapshot()
                if restoring {
                    #expect(before.restoring != nil && !before.queue.isEmpty)
                } else {
                    #expect(before.pendingOutput == true && before.outputsMuted)
                }
                #expect(await authority.reclaimAbandonedPreparation() == .terminated(identity, .cancelled, .dropped))
                let after = await authority.snapshot()
                #expect(after.plans.records[0].entries.isEmpty)
                #expect(after.pendingOutput == before.pendingOutput && after.outputsMuted == before.outputsMuted)
                #expect(after.queue == before.queue && after.restoring == before.restoring)
                #expect(after.projects == before.projects && after.outstanding == before.outstanding)
                #expect(after.retirementOutbox == before.retirementOutbox)
                #expect(after.deferredRestoreDiscards == before.deferredRestoreDiscards)
                #expect(after.lease == before.lease && after.ledger == before.ledger)
                #expect(await authority.disposePreparation(identity) == .refused(.missing))
            }
        }

        @Test func maintenanceRefusesLegacyModeUnchanged() async throws {
            let documents = Routing.documents()
            let authority = try await Bench.authority(documents, limits: nil)
            _ = try await Bench.begin(authority, documents)
            let before = await authority.snapshot()
            #expect(await authority.reclaimAbandonedPreparation() == .refused(.legacyMode))
            #expect(await authority.snapshot() == before)
        }

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
            )) == .preparationOccupied)
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(identity) == .disposed(.dropped))
        }

        @Test func occupiedAdmissionRefusesWithoutBlockingExistingEvaluation() async throws {
            let first = Routing.documents()
            var second = Routing.documents()
            second.project.id = AuthorityBench.projectB
            let authority = try await Bench.authority(first, capacity: 2)
            try await authority.open(project: second.project.id,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let owned = try await Bench.begin(authority, first)
            _ = try await Bench.retain(authority, owned)
            let before = await authority.snapshot()
            #expect(AuthorityBench.refusal(await authority.begin(
                Bench.request(second.graph), candidate: second.graph,
                projectDocument: second.project, project: second.project.id
            )) == .preparationOccupied)
            #expect(await authority.snapshot() == before)
            #expect(await authority.constructNextPreparation() == .refused(.occupied))
            #expect(try await authority.evaluatePreparation(
                owned, frames: 0, input: Array(repeating: 0, count: 8)
            ).get().result == .processed)
            #expect(await authority.nextEngineCommand() == nil)
            #expect(await authority.snapshot() == before)
            #expect(await authority.disposePreparation(owned) == .disposed(.routed))
            #expect(await authority.snapshot().queue == before.queue)
            let queued = try await Bench.begin(authority, second)
            #expect(queued.attempt.generation == .initial)
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
            let next = try await Bench.begin(authority, documents)
            #expect(next.attempt.generation == (try identity.attempt.generation.next()))
            try await authority.abandonPrepare(project: documents.project.id).get()
            #expect(await authority.constructNextPreparation() == .terminated(next, .cancelled, .dropped))
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
