import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

/// A commit report the actor must refuse with nothing changed.
enum StaleReportCase: CaseIterable, Sendable {
    case duplicateAfterAck, foreignAuthority, wrongPlan, inconsistentNodes, undelivered, withheld
}

/// What is reported, and how `ctx.engine` must move for it.
enum ReportBumpCase: CaseIterable, Sendable { case succeeded, failed, partial, refused }

/// The lifecycle before the commit (none: B runs nothing), the outcome, and the lifecycle after.
enum ReportLifecycleCase: CaseIterable, Sendable {
    case absentSucceeded, absentFailed, absentPartial, runningSucceeded, runningFailed, runningPartial

    var outcome: ActivationCommitOutcome {
        switch self {
        case .absentSucceeded, .runningSucceeded: .succeeded
        case .absentFailed, .runningFailed: .failed
        case .absentPartial, .runningPartial: .partial
        }
    }

    var expected: EngineLifecycle {
        switch self {
        case .absentSucceeded, .runningSucceeded, .runningFailed, .runningPartial: .running
        case .absentFailed, .absentPartial: .stopped
        }
    }
}

private func actorPlanPhase(
    _ binding: PlanBinding, in snapshot: HostAuthoritySnapshot
) -> EnginePlanPhase? {
    for record in snapshot.plans.records where record.instance == binding.instance {
        for entry in record.entries where entry.attempt == binding.attempt {
            if case .bound(let actual, let phase) = entry.state, actual == binding { return phase }
        }
    }
    return nil
}

private struct DegradedActorReportSeed {
    var engine: ScriptedActivationEngine
    let authority: HostAuthority
    let installed: PlanBinding
    let context: Generation
}

private func degradedActorReportSeed() async throws -> DegradedActorReportSeed {
    var engine = try ScriptedActivationEngine()
    let authority = try await AuthorityBench.makeAuthority(&engine, lifecycleA: .degraded([AuthorityBench.audio]))
    let initial = await authority.snapshot()
    let project = try #require(initial.projects[AuthorityBench.projectA])
    let installed = try #require(project.installed)
    let context = try #require(AuthorityBench.context(initial))
    #expect(project.lifecycle == .degraded([AuthorityBench.audio]))
    #expect(installed.instance == initial.plans.currentInstance)
    #expect(actorPlanPhase(installed, in: initial) == .committed)
    #expect(initial.lease?.project == AuthorityBench.projectA)
    #expect(initial.lease?.windows.contains(AuthorityBench.windowA) == true)
    #expect(initial.queue.isEmpty && initial.retirementOutbox.isEmpty && initial.inFlight.isEmpty)
    #expect(await authority.lifecycle(of: AuthorityBench.projectA, window: AuthorityBench.windowA)
            == .degraded([AuthorityBench.audio]))
    #expect(await authority.lifecycle(of: AuthorityBench.projectA, window: AuthorityBench.windowA2)
            == .heldByOther(AuthorityBench.projectA))
    #expect(await authority.lifecycle(of: AuthorityBench.projectB, window: AuthorityBench.windowB)
            == .heldByOther(AuthorityBench.projectA))
    return DegradedActorReportSeed(engine: engine, authority: authority, installed: installed, context: context)
}

extension HostAuthorityTests {
    /// The engine's commit reports: D-ctx, the lifecycle and the end of the flight (H5c-2).
    struct ActorCommitReports {
        @Test func acknowledgedCommitAdvancesRunningAndDiscardsReplaced() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let previous = try #require(try await Bench.state(authority).installed)
            let reviewed = try await Bench.commitDelivered(authority, &engine)
            let revision = try await Bench.state(authority).running.revision.next()
            let reported = try #require(await engine.report(authority, .succeeded))
            #expect(reported.verdict == .success(.acknowledged(revision)))
            let after = await authority.snapshot()
            let state = try #require(after.projects[Bench.projectA])
            #expect(state.running == RunningGraph(revision: revision, prepared: reviewed))
            #expect(state.phase == .acknowledged(revision) && state.lifecycle == .running && state.reviewed == nil)
            #expect(state.installed?.prepared == reviewed)
            #expect(after.inFlight.isEmpty && after.queue.pending == [.discard(previous)])
            #expect(await engine.drain(authority) == [.discard(previous)])
        }

        @Test(arguments: [ActivationCommitOutcome.failed, .partial])
        func failedAndPartialReportsQueueNothing(_ outcome: ActivationCommitOutcome) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let reviewed = try await Bench.commitDelivered(authority, &engine, withAux: true)
            let before = await authority.snapshot()
            let reported = try #require(await engine.report(authority, outcome))
            let after = await authority.snapshot()
            let state = try #require(after.projects[Bench.projectA])
            switch outcome {
            case .failed:
                #expect(reported.verdict == .success(.failed) && state.phase == .commitFailed(reviewed))
            case .partial, .succeeded:
                #expect(reported.verdict == .success(.partial(unapplied: [Bench.nodeOut])))
                #expect(state.phase == .partial(reviewed, applied: [Bench.nodeAux], unapplied: [Bench.nodeOut]))
            }
            #expect(after.queue.pending.isEmpty && after.inFlight.isEmpty)
            #expect(Bench.context(after) == Bench.context(before))
            #expect(state.running == before.projects[Bench.projectA]?.running && state.lifecycle == .running)
            #expect(state.reviewed == before.projects[Bench.projectA]?.reviewed)
            #expect(state.installed == before.projects[Bench.projectA]?.installed)
            let binding = try #require(state.reviewed)
            let expectedPhase: EnginePlanPhase = outcome == .partial ? .committed : .held
            let owned = after.plans.records.flatMap(\.entries).first { $0.attempt == binding.attempt }
            #expect(owned?.state == .bound(binding, expectedPhase))
            // Unqualified boot adoption is forbidden, whatever the raw name.
            let adopt = await authority.open(project: Bench.projectC,
                                             running: RunningGraph(revision: .initial, prepared: reviewed))
            #expect(Bench.refusal(adopt) == .unqualifiedResident)
            #expect(await engine.drain(authority).isEmpty)
        }

        @Test(arguments: StaleReportCase.allCases)
        func staleCommitReportQueuesNothing(_ staleCase: StaleReportCase) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let (report, expected) = try await stale(staleCase, authority, &engine)
            let before = await authority.snapshot()
            let refused = await authority.commitReported(report)
            #expect(Bench.refusal(refused) == expected)
            #expect(await authority.snapshot() == before)
        }

        @Test func fullQueueRefusesTheReportBeforeItsChecks() async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine)
            let withheld = engine.withholdCommit()
            let commit = try #require(withheld)
            try await Bench.fillQueue(authority)
            let before = await authority.snapshot()
            let report = engine.report(on: commit, .succeeded)
            #expect(Bench.refusal(await authority.commitReported(report)) == .queueFull)
            // Room is checked before the transaction: a mismatching report is also `.queueFull`.
            let wrongPlan = ActivationCommitReport(prepared: Bench.runningPlan, attempt: commit.attempt,
                                                   outcome: .succeeded, applied: [Bench.nodeOut], unapplied: [])
            #expect(Bench.refusal(await authority.commitReported(wrongPlan)) == .queueFull)
            #expect(await authority.snapshot() == before)
            // Nothing moved, so the engine re-delivers the same report once the queue drains.
            await engine.drain(authority)
            let revision = try await Bench.state(authority).running.revision.next()
            #expect(await authority.commitReported(report) == .success(.acknowledged(revision)))
        }

        @Test(arguments: ReportBumpCase.allCases)
        func acknowledgedActivationBumpsContext(_ bumpCase: ReportBumpCase) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine, withAux: true)
            let before = try #require(Bench.context(await authority.snapshot()))
            switch bumpCase {
            case .succeeded: _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
            case .failed: _ = try #require(await engine.report(authority, .failed)).verdict.get()
            case .partial: _ = try #require(await engine.report(authority, .partial)).verdict.get()
            case .refused:
                let withheld = engine.withholdCommit()
                let commit = try #require(withheld)
                let wrongPlan = ActivationCommitReport(prepared: Bench.runningPlan, attempt: commit.attempt,
                                                       outcome: .failed, applied: [], unapplied: [Bench.nodeOut])
                #expect(Bench.refusal(await authority.commitReported(wrongPlan)) == .activation(.reportMismatch))
            }
            let expected = bumpCase == .succeeded ? try before.next() : before
            #expect(Bench.context(await authority.snapshot()) == expected)
        }

        @Test(arguments: ReportLifecycleCase.allCases)
        func reportedLifecycleFollowsPriorState(_ lifecycleCase: ReportLifecycleCase) async throws {
            var engine = try ScriptedActivationEngine()
            let authority: HostAuthority
            let project: ProjectID
            switch lifecycleCase {
            case .absentSucceeded, .absentFailed, .absentPartial:
                authority = try await Bench.makeAuthority(&engine, holding: nil)
                _ = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get()
                project = Bench.projectB
            case .runningSucceeded, .runningFailed, .runningPartial:
                authority = try await Bench.makeAuthority(&engine)
                project = Bench.projectA
            }
            let window = project == Bench.projectB ? Bench.windowB : Bench.windowA
            _ = try await Bench.commitDelivered(authority, &engine, project: project, window: window, withAux: true)
            _ = try #require(await engine.report(authority, lifecycleCase.outcome)).verdict.get()
            #expect(try await Bench.state(authority, project).lifecycle == lifecycleCase.expected)
        }

        @Test(arguments: [ActivationCommitOutcome.succeeded, .failed])
        func degradedActorReportsPreserveCanonicalOwnership(_ outcome: ActivationCommitOutcome) async throws {
            var seed = try await degradedActorReportSeed()
            let authority = seed.authority
            let reviewed = try await Bench.commitDelivered(authority, &seed.engine, withAux: true)
            let before = await authority.snapshot()
            let beforeProject = try #require(before.projects[Bench.projectA])
            let attempt = try #require(before.inFlight[Bench.projectA])
            let reviewedBinding = try #require(beforeProject.reviewed)
            #expect(beforeProject.phase == .committing && beforeProject.reviewed?.prepared == reviewed)
            #expect(beforeProject.installed == seed.installed && actorPlanPhase(reviewedBinding, in: before) == .held)
            #expect(Bench.context(before) == seed.context)
            #expect(before.queue.isEmpty && before.retirementOutbox.isEmpty)

            let withheld = seed.engine.withholdCommit()
            let commit = try #require(withheld)
            let report = seed.engine.report(on: commit, outcome)
            #expect(report.prepared == reviewed && report.attempt == attempt)
            let wrong = ActivationCommitReport(prepared: seed.installed.prepared, attempt: attempt,
                                               outcome: outcome, applied: report.applied,
                                               unapplied: report.unapplied)
            #expect(Bench.refusal(await authority.commitReported(wrong)) == .activation(.reportMismatch))
            #expect(await authority.snapshot() == before)
            let result = try await authority.commitReported(report).get()
            let after = await authority.snapshot()
            let project = try #require(after.projects[Bench.projectA])
            #expect(project.lifecycle == .degraded([Bench.audio]))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA)
                    == .degraded([Bench.audio]))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA2)
                    == .heldByOther(Bench.projectA))
            #expect(after.inFlight.isEmpty && after.retirementOutbox.isEmpty)

            if outcome == .succeeded {
                let revision = try beforeProject.running.revision.next()
                #expect(result == .acknowledged(revision))
                #expect(project.phase == .acknowledged(revision) && project.running.prepared == reviewed)
                #expect(project.installed == reviewedBinding && project.reviewed == nil)
                #expect(actorPlanPhase(seed.installed, in: after) == .retiring)
                #expect(actorPlanPhase(reviewedBinding, in: after) == .committed)
                #expect(Bench.context(after) == (try seed.context.next()))
                #expect(after.queue.pending == [.discard(seed.installed)])
                let refusedSnapshot = await authority.snapshot()
                #expect(Bench.refusal(await authority.retired(seed.installed)) == .retirementQueued)
                #expect(await authority.snapshot() == refusedSnapshot)
                #expect(await seed.engine.drain(authority) == [.discard(seed.installed)])
                let retiredSnapshot = await authority.snapshot()
                #expect(actorPlanPhase(seed.installed, in: retiredSnapshot) == nil)
                #expect(actorPlanPhase(reviewedBinding, in: retiredSnapshot) == .committed)
                #expect(Bench.refusal(await authority.retired(seed.installed)) == .plans(.unknownAttempt))
                #expect(await authority.snapshot() == retiredSnapshot)
            } else {
                #expect(result == .failed && project.phase == .commitFailed(reviewed))
                #expect(project.running == beforeProject.running)
                #expect(project.installed == seed.installed && project.reviewed == reviewedBinding)
                #expect(actorPlanPhase(seed.installed, in: after) == .committed)
                #expect(actorPlanPhase(reviewedBinding, in: after) == .held)
                #expect(Bench.context(after) == seed.context && after.queue.isEmpty)
                let refusedSnapshot = await authority.snapshot()
                #expect(Bench.refusal(await authority.retired(seed.installed)) == .plans(.notRetiring))
                #expect(await authority.snapshot() == refusedSnapshot)
                #expect(await seed.engine.drain(authority).isEmpty)
            }
        }

        @Test func acknowledgingActivationKeepsSettledStates() throws {
            let next = try ContractRevision.initial.next()
            #expect(EngineLifecycle.preparing(next, over: .absent).acknowledgingActivation == .running)
            // Fail closed: an acknowledgement never ends recovery (H5d unmutes).
            for settled in [EngineLifecycle.recovering, .stopped, .running, .degraded([Bench.audio]),
                            .heldByOther(Bench.projectB)] {
                #expect(settled.acknowledgingActivation == settled)
            }
        }

        @Test(arguments: [ActivationCommitOutcome.succeeded, .failed, .partial])
        func releaseAndTransferAllowedAfterReport(_ outcome: ActivationCommitOutcome) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine, withAux: true)
            #expect(Bench.refusal(await authority.release(project: Bench.projectA)) == .activation(.busy))
            _ = try #require(await engine.report(authority, outcome)).verdict.get()
            try await authority.release(project: Bench.projectA).get()
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            #expect(await authority.snapshot().lease?.project == Bench.projectB)
        }

        /// Sets up `staleCase` on `authority`; returns the report and its expected refusal.
        private func stale(_ staleCase: StaleReportCase, _ authority: HostAuthority,
                           _ engine: inout ScriptedActivationEngine) async throws
        -> (ActivationCommitReport, HostAuthorityRefusal) {
            switch staleCase {
            case .duplicateAfterAck:
                _ = try await Bench.commitDelivered(authority, &engine)
                let reported = try #require(await engine.report(authority, .succeeded))
                _ = try reported.verdict.get()
                return (reported.report, .activation(.staleReport))
            case .foreignAuthority:
                _ = try await Bench.commitDelivered(authority, &engine)
                var foreignEngine = try ScriptedActivationEngine()
                let foreign = try await Bench.makeAuthority(&foreignEngine)
                _ = try await Bench.commitDelivered(foreign, &foreignEngine)
                let withheld = foreignEngine.withholdCommit()
                let commit = try #require(withheld)
                return (foreignEngine.report(on: commit, .succeeded), .activation(.staleReport))
            case .wrongPlan, .inconsistentNodes:
                _ = try await Bench.commitDelivered(authority, &engine)
                let withheld = engine.withholdCommit()
                let commit = try #require(withheld)
                let plan = staleCase == .wrongPlan ? Bench.runningPlan : commit.prepared
                let applied: Set<NodeID> = staleCase == .wrongPlan ? [Bench.nodeOut] : []
                let unapplied = Set([Bench.nodeOut]).subtracting(applied)
                let report = ActivationCommitReport(prepared: plan, attempt: commit.attempt, outcome: .succeeded,
                                                    applied: applied, unapplied: unapplied)
                return (report, .activation(.reportMismatch))
            case .undelivered, .withheld:
                let reviewed = try await Bench.commitQueued(authority, &engine)
                let attempt = try await Bench.attempt(authority)
                if staleCase == .withheld {
                    try await authority.release(project: Bench.projectA).get()
                    #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
                }
                let report = ActivationCommitReport(prepared: reviewed, attempt: attempt, outcome: .succeeded,
                                                    applied: [Bench.nodeOut], unapplied: [])
                return (report, .activation(.staleReport))
            }
        }
    }
}
