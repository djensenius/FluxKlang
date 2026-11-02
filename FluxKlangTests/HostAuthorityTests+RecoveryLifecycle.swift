import Testing
@testable import FluxKlang

// Lifecycle while preparing, and restore causes; the bench helpers are in `+Recovery.swift`.
private let audio = CapabilityID(validated: "cap.audio")
private let meter = CapabilityID(validated: "cap.meter")
private let planID = PreparedActivationID(validated: "prep.next")
private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let windowA = WindowID(validated: "win.a1")
private let windowA2 = WindowID(validated: "win.a2")
private let windowB = WindowID(validated: "win.b1")

extension HostAuthorityTests.Recovery {
    /// A window of the recovering project that is not on the lease still reports muted recovery.
    @Test func ownProjectWindowOffTheLeaseReportsRecovery() throws {
        var registry = EngineLeaseRegistry()
        _ = try registry.acquire(project: projectA, window: windowA)
        let offLease = EngineLifecycle.observed(by: windowA2, of: projectA, in: registry, engine: .recovering)
        #expect(offLease == .recovering && offLease.outputsMuted && !offLease.acceptsRunningSetChanges)
        #expect(EngineLifecycle.observed(by: windowA2, of: projectA, in: registry, engine: .running)
            == .heldByOther(projectA))
        let otherProject = EngineLifecycle.observed(by: windowB, of: projectB, in: registry, engine: .recovering)
        #expect(otherProject == .heldByOther(projectA) && !otherProject.outputsMuted)
    }

    @Test func preparationRendersOnlyOverARunningSet() throws {
        let next = try ContractRevision.initial.next()
        let first = EngineLifecycle.preparing(next, over: .absent)
        #expect(!first.rendersOutput && !first.outputsMuted && first.acceptsRunningSetChanges)
        for base in [RunningSetState.running, .degraded([audio])] {
            let preparing = EngineLifecycle.preparing(next, over: base)
            #expect(preparing.rendersOutput && !preparing.outputsMuted && preparing.acceptsRunningSetChanges)
        }
    }

    @Test func capabilityLossDuringPreparationIsRecorded() throws {
        let next = try ContractRevision.initial.next()
        let degraded = EngineLifecycle.preparing(next, over: .running).after(.capabilityLost(audio))
        #expect(degraded == .preparing(next, over: .degraded([audio])) && degraded.rendersOutput)
        #expect(degraded.after(.capabilityLost(audio)) == degraded)
        #expect(degraded.after(.capabilityLost(meter)) == .preparing(next, over: .degraded([audio, meter])))
        // Nothing renders yet, so nothing degrades; the commit's capability check still applies.
        let first = EngineLifecycle.preparing(next, over: .absent)
        #expect(first.after(.capabilityLost(audio)) == first)
        #expect(degraded.after(.leaseLost) == .recovering)
    }

    /// The owner's mapping into and out of preparation keeps what renders, including lost capabilities.
    @Test func preparationStartsAndEndsOverTheRenderingSet() throws {
        let next = try ContractRevision.initial.next()
        let lost = EngineLifecycle.degraded([audio, meter])
        for lifecycle in [EngineLifecycle.stopped, .running, lost] {
            let preparing = lifecycle.startingPreparation(of: next)
            #expect(preparing.rendersOutput == lifecycle.rendersOutput && preparing.endingPreparation == lifecycle)
            #expect(preparing.startingPreparation(of: .initial).endingPreparation == lifecycle)
        }
        #expect(lost.startingPreparation(of: next) == .preparing(next, over: .degraded([audio, meter])))
        let degraded = EngineLifecycle.running.startingPreparation(of: next).after(.capabilityLost(audio))
        #expect(degraded.endingPreparation == .degraded([audio]))
        for lifecycle in [EngineLifecycle.recovering, .heldByOther(projectB)] {
            #expect(lifecycle.startingPreparation(of: next) == lifecycle && lifecycle.endingPreparation == lifecycle)
        }
    }

    /// The restore keeps its instructions but reports why recovery started, not a confirmed failure.
    @Test(arguments: [CommitAbandonment.outcomeUnknown, .revisionOverflow, .leaseLost])
    func restoreReportsTheCauseThatStartedRecovery(reason: CommitAbandonment) throws {
        let base = try reason == .revisionOverflow ? ContractRevision(ContractRevision.maximumValue) : .initial
        var host = try TransactionBench(revision: base)
        let attempt = try host.committedAttempt(base: base)
        _ = try host.transaction.abandonCommit(attempt, reason: reason).get()
        #expect(host.transaction.phase == .recovering(planID, cause: reason.event))
        #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get()
            == ActivationRecoveryStep(cause: reason.event, decisions: [.restorePrevious(base)],
                                      effects: [.discard(planID)]))
        #expect(host.transaction.phase == .idle)
    }
}
