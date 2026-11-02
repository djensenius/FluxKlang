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
    case absentSucceeded, absentFailed, absentPartial, runningSucceeded, runningPartial, degradedSucceeded
    case degradedFailed

    var outcome: ActivationCommitOutcome {
        switch self {
        case .absentSucceeded, .runningSucceeded, .degradedSucceeded: .succeeded
        case .absentFailed, .degradedFailed: .failed
        case .absentPartial, .runningPartial: .partial
        }
    }

    var expected: EngineLifecycle {
        switch self {
        case .absentSucceeded, .runningSucceeded, .runningPartial: .running
        case .absentFailed, .absentPartial: .stopped
        case .degradedSucceeded, .degradedFailed: .degraded([AuthorityBench.audio])
        }
    }
}

extension HostAuthorityTests {
    /// The engine's commit reports: D-ctx, the lifecycle and the end of the flight (H5c-2).
    struct ActorCommitReports {
        @Test func acknowledgedCommitAdvancesRunningAndDiscardsReplaced() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitDelivered(authority, &engine)
            let revision = try ContractRevision.initial.next()
            let reported = try #require(await engine.report(authority, .succeeded))
            #expect(reported.verdict == .success(.acknowledged(revision)))
            let after = await authority.snapshot()
            let state = try #require(after.projects[Bench.projectA])
            #expect(state.running == RunningGraph(revision: revision, prepared: reviewed))
            #expect(state.phase == .acknowledged(revision) && state.lifecycle == .running && state.reviewed == nil)
            #expect(after.inFlight.isEmpty && after.queue.pending == [.discard(Bench.runningPlan)])
            #expect(await engine.drain(authority) == [.discard(Bench.runningPlan)])
        }

        @Test(arguments: [ActivationCommitOutcome.failed, .partial])
        func failedAndPartialReportsQueueNothing(_ outcome: ActivationCommitOutcome) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
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
            // The plan stays live until H5d resolves it: no project may adopt it.
            let adopt = await authority.open(project: Bench.projectC,
                                             running: RunningGraph(revision: .initial, prepared: reviewed))
            #expect(Bench.refusal(adopt) == .activation(.preparedIDInUse))
            #expect(await engine.drain(authority).isEmpty)
        }

        @Test(arguments: StaleReportCase.allCases)
        func staleCommitReportQueuesNothing(_ staleCase: StaleReportCase) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let (report, expected) = try await stale(staleCase, authority, &engine)
            let before = await authority.snapshot()
            let refused = await authority.commitReported(report)
            #expect(Bench.refusal(refused) == expected)
            #expect(await authority.snapshot() == before)
        }

        @Test func fullQueueRefusesTheReportBeforeItsChecks() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
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
            let revision = try ContractRevision.initial.next()
            #expect(await authority.commitReported(report) == .success(.acknowledged(revision)))
        }

        @Test(arguments: ReportBumpCase.allCases)
        func acknowledgedActivationBumpsContext(_ bumpCase: ReportBumpCase) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
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
                authority = try await Bench.makeAuthority(holding: nil)
                _ = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get()
                project = Bench.projectB
            case .runningSucceeded, .runningPartial:
                authority = try await Bench.makeAuthority()
                project = Bench.projectA
            case .degradedSucceeded, .degradedFailed:
                authority = try await Bench.makeAuthority(lifecycleA: .degraded([Bench.audio]))
                project = Bench.projectA
            }
            let window = project == Bench.projectB ? Bench.windowB : Bench.windowA
            _ = try await Bench.commitDelivered(authority, &engine, project: project, window: window, withAux: true)
            _ = try #require(await engine.report(authority, lifecycleCase.outcome)).verdict.get()
            #expect(try await Bench.state(authority, project).lifecycle == lifecycleCase.expected)
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
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
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
                let foreign = try await Bench.makeAuthority()
                var foreignEngine = try ScriptedActivationEngine()
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
