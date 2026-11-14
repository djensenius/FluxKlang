//
//  SetupApplyGuardTests.swift
//  FluxKlangTests
//
//  The setup apply guard (#100 SAP1): an ended setup flow composed with the rig mapping review. The guard is pure
//  value code. The tests drive the real reducer to reach the ended state and compare each accepted result with a
//  direct `RigMappingReview.apply` of the same inputs. Nothing here reads a permission, a device, a file, a port or
//  a clock.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// What one guard call produced: the change or the refusal.
private enum ApplyOutcome: Equatable {
    case changed(SetupApplyChange)
    case refused(SetupApplyRefusal)
}

/// The review, the decisions and the document handed to one guard call.
private struct ApplyInputs {
    let review: RigMappingReview
    let decisions: RigMappingDecisions
    let document: DeviceCapabilityDocument

    static func lost(
        decisions: RigMappingDecisions = .empty,
        document: DeviceCapabilityDocument? = nil
    ) throws -> ApplyInputs {
        try ApplyInputs(
            review: RigMappingReviewFixture.lostRigReview(),
            decisions: decisions,
            document: document ?? RigMappingReviewFixture.lostRig()
        )
    }

    /// What `RigMappingReview.apply` returns for these inputs.
    func direct() throws -> RigMappingChange {
        try review.apply(decisions, to: document)
    }

    /// The refusal `RigMappingReview.apply` throws for these inputs, or nil when it succeeds.
    func directRefusal() -> RigReviewRefusal? {
        RigMappingReviewFixture.refusal { _ = try review.apply(decisions, to: document) }
    }
}

private enum ApplyKit {
    static let rigA = SetupFlowTests.rigA
    static let rigB = SetupFlowTests.rigB

    /// Two present devices, one lost device, rigs A and B offered, no undecided role.
    static func facts(
        access: SetupFlowAccess = .granted,
        present: Int = 2,
        lost: Int = 1,
        rigs: [SetupFlowRigID] = [rigA, rigB],
        roles: Int = 0
    ) throws(SetupFlowRefusal) -> SetupFlowFacts {
        try SetupFlowTests.facts(access: access, present: present, lost: lost, rigs: rigs, roles: roles)
    }

    /// A flow that ended with an apply request under `facts`.
    static func ended(facts: SetupFlowFacts, pick: SetupFlowRigID?) throws(SetupFlowRefusal) -> SetupFlowState {
        let state = try SetupFlowTests.running(at: .decide, facts: facts, pick: pick)
        return try SetupFlowReducer.reduce(state, .requestApply, facts: facts)
    }

    /// A flow that ended in manual mode.
    static func manual(facts: SetupFlowFacts) throws(SetupFlowRefusal) -> SetupFlowState {
        let state = try SetupFlowTests.running(at: .identify, facts: facts)
        return try SetupFlowReducer.reduce(state, .stayManual, facts: facts)
    }

    static func attempt(_ state: SetupFlowState, _ facts: SetupFlowFacts, _ inputs: ApplyInputs) -> ApplyOutcome {
        do throws(SetupApplyRefusal) {
            let result = try SetupApplyGuard.apply(
                state, currentFacts: facts, review: inputs.review, decisions: inputs.decisions,
                document: inputs.document
            )
            return .changed(result)
        } catch {
            return .refused(error)
        }
    }

    static func changed(_ outcome: ApplyOutcome) -> SetupApplyChange? {
        if case .changed(let result) = outcome { result } else { nil }
    }

    static func revision(_ value: Int) throws -> ContractRevision {
        try ContractRevision(value)
    }
}

@Suite("Setup apply guard", .productionAccessAudit)
struct SetupApplyGuardTests {
    @Test
    func setupApplyGuardGoldenAcceptedApplyIsTheDirectApplyWithThePickedRig() throws {
        let facts = try ApplyKit.facts()
        let state = try ApplyKit.ended(facts: facts, pick: ApplyKit.rigB)
        let inputs = try ApplyInputs.lost()
        let direct = try inputs.direct()
        let outcome = ApplyKit.attempt(state, facts, inputs)
        let result = try #require(ApplyKit.changed(outcome))
        #expect(result.rig == ApplyKit.rigB)
        #expect(result.change == direct)
        let revision = try ApplyKit.revision(7)
        #expect(result.change.baseRevision == revision)
        #expect(result.change.removed.isEmpty)
    }

    @Test
    func setupApplyGuardGoldenRemoveDecisionOfARealCandidateMatchesTheDirectApply() throws {
        let facts = try ApplyKit.facts()
        let state = try ApplyKit.ended(facts: facts, pick: ApplyKit.rigB)
        let space = try RouteID("rte.space")
        let decisions = try RigMappingDecisions.make(routes: [.remove(space)])
        let inputs = try ApplyInputs.lost(decisions: decisions)
        let direct = try inputs.direct()
        #expect(direct.removed == [space])
        let result = try #require(ApplyKit.changed(ApplyKit.attempt(state, facts, inputs)))
        #expect(result.change == direct)
        #expect(result.rig == ApplyKit.rigB)
    }

    @Test
    func setupApplyGuardFactsDriftByFieldIsRefusedAndRebuiltEqualFactsPass() throws {
        let basis = try ApplyKit.facts()
        let state = try ApplyKit.ended(facts: basis, pick: ApplyKit.rigB)
        let inputs = try ApplyInputs.lost()
        let rigC = SetupFlowTests.rigC
        let drifted: [(String, SetupFlowFacts)] = try [
            ("access denied", ApplyKit.facts(access: .denied)),
            ("access not determined", ApplyKit.facts(access: .notDetermined)),
            ("present devices 1", ApplyKit.facts(present: 1)),
            ("present devices 3", ApplyKit.facts(present: 3)),
            ("lost devices 2", ApplyKit.facts(lost: 2)),
            ("lost devices 0", ApplyKit.facts(lost: 0)),
            ("rig removed", ApplyKit.facts(rigs: [ApplyKit.rigB])),
            ("rig added", ApplyKit.facts(rigs: [ApplyKit.rigA, ApplyKit.rigB, rigC])),
            ("undecided role", ApplyKit.facts(roles: 1))
        ]
        for (label, facts) in drifted {
            let outcome = ApplyKit.attempt(state, facts, inputs)
            #expect(outcome == .refused(.factsChanged), Comment(rawValue: label))
        }
        let rebuilt = try ApplyKit.facts()
        let accepted = ApplyKit.attempt(state, rebuilt, inputs)
        #expect(ApplyKit.changed(accepted) != nil)
    }

    @Test
    func setupApplyGuardReorderedRigListIsAChangeAtTwoAndAtTheSixteenRigLimit() throws {
        let basis = try ApplyKit.facts()
        let state = try ApplyKit.ended(facts: basis, pick: ApplyKit.rigB)
        let inputs = try ApplyInputs.lost()
        let swapped = try ApplyKit.facts(rigs: [ApplyKit.rigB, ApplyKit.rigA])
        #expect(ApplyKit.attempt(state, swapped, inputs) == .refused(.factsChanged))

        let limit = SetupFlowFacts.maximumRigs
        let many = SetupFlowTests.manyRigs(limit)
        let first = try #require(many.first)
        let manyFacts = try ApplyKit.facts(rigs: many)
        let manyState = try ApplyKit.ended(facts: manyFacts, pick: first)
        let equalAgain = try ApplyKit.facts(rigs: many)
        #expect(ApplyKit.changed(ApplyKit.attempt(manyState, equalAgain, inputs)) != nil)
        let reversed = try ApplyKit.facts(rigs: Array(many.reversed()))
        #expect(ApplyKit.attempt(manyState, reversed, inputs) == .refused(.factsChanged))
    }

    @Test
    func setupApplyGuardRunningSuspendedAndManualFlowsProduceNoChange() throws {
        let facts = try ApplyKit.facts()
        let valid = try ApplyInputs.lost()
        let stale = try ApplyInputs.lost(document: RigMappingReviewFixture.lostRig(revision: 8))
        for step in SetupFlowTests.steps {
            let running = try SetupFlowTests.running(at: step, facts: facts, pick: ApplyKit.rigB)
            #expect(ApplyKit.attempt(running, facts, valid) == .refused(.flowNotEnded))
            let suspended = try SetupFlowTests.suspended(at: step)
            #expect(ApplyKit.attempt(suspended, facts, valid) == .refused(.flowNotEnded))
        }
        let manual = try ApplyKit.manual(facts: facts)
        #expect(ApplyKit.attempt(manual, facts, valid) == .refused(.manualChosen))
        #expect(ApplyKit.attempt(manual, facts, stale) == .refused(.manualChosen))
    }

    @Test
    func setupApplyGuardRefusalOrderIsPhaseThenFactsThenReview() throws {
        let basis = try ApplyKit.facts()
        let drifted = try ApplyKit.facts(access: .denied)
        let stale = try ApplyInputs.lost(document: RigMappingReviewFixture.lostRig(revision: 8))
        let running = try SetupFlowTests.running(at: .review, facts: basis, pick: ApplyKit.rigB)
        #expect(ApplyKit.attempt(running, drifted, stale) == .refused(.flowNotEnded))
        let manual = try ApplyKit.manual(facts: basis)
        #expect(ApplyKit.attempt(manual, drifted, stale) == .refused(.manualChosen))
        let ended = try ApplyKit.ended(facts: basis, pick: ApplyKit.rigB)
        #expect(ApplyKit.attempt(ended, drifted, stale) == .refused(.factsChanged))
        let base = try ApplyKit.revision(7)
        let found = try ApplyKit.revision(8)
        let expected = SetupApplyRefusal.review(.staleDocument(base: base, found: found))
        #expect(ApplyKit.attempt(ended, basis, stale) == .refused(expected))
    }

    @Test
    func setupApplyGuardStaleAndChangedDocumentsPassTheReviewRefusalThrough() throws {
        let facts = try ApplyKit.facts()
        let state = try ApplyKit.ended(facts: facts, pick: ApplyKit.rigB)
        let staleDocument = try RigMappingReviewFixture.lostRig(revision: 8)
        let stale = try ApplyInputs.lost(document: staleDocument)
        let base = try ApplyKit.revision(7)
        let found = try ApplyKit.revision(8)
        let expectedStale = SetupApplyRefusal.review(.staleDocument(base: base, found: found))
        #expect(ApplyKit.attempt(state, facts, stale) == .refused(expectedStale))

        let changedDocument = try RigMappingReviewFixture.lostRig(ifaceAOutputs: 8)
        let changed = try ApplyInputs.lost(document: changedDocument)
        let expectedChanged = SetupApplyRefusal.review(.documentChanged(revision: base))
        #expect(ApplyKit.attempt(state, facts, changed) == .refused(expectedChanged))
    }

    @Test
    func setupApplyGuardDecisionRefusalPassesThroughAndEqualsTheDirectRefusal() throws {
        let facts = try ApplyKit.facts()
        let state = try ApplyKit.ended(facts: facts, pick: ApplyKit.rigB)
        let mains = try RouteID("rte.mains")
        let decisions = try RigMappingDecisions.make(routes: [.remove(mains)])
        let inputs = try ApplyInputs.lost(decisions: decisions)
        let direct = try #require(inputs.directRefusal())
        #expect(direct == .removeNotCandidate(mains))
        #expect(ApplyKit.attempt(state, facts, inputs) == .refused(.review(direct)))
    }

    @Test
    func setupApplyGuardKeepsTheMissingDeviceRouteLikeTheDirectApplyAndRefusesDeniedAccess() throws {
        let facts = try ApplyKit.facts(lost: 1)
        let state = try ApplyKit.ended(facts: facts, pick: ApplyKit.rigB)
        let inputs = try ApplyInputs.lost()
        let direct = try inputs.direct()
        let space = try RouteID("rte.space")
        #expect(direct.kept.contains(space))
        let result = try #require(ApplyKit.changed(ApplyKit.attempt(state, facts, inputs)))
        #expect(result.change == direct)
        #expect(result.change.kept.contains(space))

        let denied = try ApplyKit.facts(access: .denied, lost: 1)
        let refused = ApplyKit.attempt(state, denied, inputs)
        #expect(refused == .refused(.factsChanged))
        #expect(ApplyKit.changed(refused) == nil)
    }

    @Test
    func setupApplyGuardPickedRigIsPassedThroughWhetherAbsentFirstOrSecondOffered() throws {
        let inputs = try ApplyInputs.lost()
        let noRigs = try ApplyKit.facts(rigs: [])
        let unpicked = try ApplyKit.ended(facts: noRigs, pick: nil)
        let none = try #require(ApplyKit.changed(ApplyKit.attempt(unpicked, noRigs, inputs)))
        #expect(none.rig == nil)

        let pair = try ApplyKit.facts()
        let first = try ApplyKit.ended(facts: pair, pick: ApplyKit.rigA)
        let firstResult = try #require(ApplyKit.changed(ApplyKit.attempt(first, pair, inputs)))
        #expect(firstResult.rig == ApplyKit.rigA)

        let reversed = try ApplyKit.facts(rigs: [ApplyKit.rigB, ApplyKit.rigA])
        let second = try ApplyKit.ended(facts: reversed, pick: ApplyKit.rigA)
        let secondResult = try #require(ApplyKit.changed(ApplyKit.attempt(second, reversed, inputs)))
        #expect(secondResult.rig == ApplyKit.rigA)
    }

    @Test
    func setupApplyGuardNewFlowUnderTheCurrentFactsPassesAfterARefusal() throws {
        let basis = try ApplyKit.facts()
        let current = try ApplyKit.facts(lost: 0)
        let oldState = try ApplyKit.ended(facts: basis, pick: ApplyKit.rigB)
        let inputs = try ApplyInputs.lost()
        #expect(ApplyKit.attempt(oldState, current, inputs) == .refused(.factsChanged))

        let newState = try ApplyKit.ended(facts: current, pick: ApplyKit.rigB)
        let result = try #require(ApplyKit.changed(ApplyKit.attempt(newState, current, inputs)))
        let direct = try inputs.direct()
        #expect(result.change == direct)
        #expect(result.rig == ApplyKit.rigB)
    }

    @Test
    func setupApplyGuardRefusalCasesCompareUnequalToEachOther() throws {
        let base = try ApplyKit.revision(7)
        let reviewCase = SetupApplyRefusal.review(.documentChanged(revision: base))
        let cases: [SetupApplyRefusal] = [.flowNotEnded, .manualChosen, .factsChanged, reviewCase]
        for (index, left) in cases.enumerated() {
            for (other, right) in cases.enumerated() where index != other {
                #expect(left != right)
            }
        }
    }
}
