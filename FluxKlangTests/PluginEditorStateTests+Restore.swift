import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginEditorStateTests {
    private static func plan(
        _ snapshot: PluginStateSnapshot?, _ target: PluginStateTarget, _ instance: InstanceActivity,
        purpose: StatePurpose = .document, evidence: QualifiedVersionEvidence = .none
    ) throws(InactiveRestoreError) -> InactiveRestorePlan {
        try InactiveRestorePlan.plan(
            snapshot: snapshot, target: target, purpose: purpose, evidence: evidence, instance: instance
        )
    }

    @Test func anUnpreparedInstanceGetsPrepareLoadVerifyAndActivateInThatOrder() throws {
        let plan = try Self.plan(Self.snapshot(), Self.target(), .unprepared)
        #expect(plan.steps == [.prepareInstance, .loadState, .verifyDigest, .activateInstance])
    }

    @Test func aPreparedInstanceSkipsThePrepareStep() throws {
        let plan = try Self.plan(Self.snapshot(), Self.target(), .prepared)
        #expect(plan.steps == [.loadState, .verifyDigest, .activateInstance])
    }

    @Test func thePlanCarriesTheSnapshotThePurposeAndTheExpectedDigest() throws {
        let snapshot = try Self.snapshot(blob: [4, 5, 6])
        let plan = try Self.plan(snapshot, Self.target(), .prepared, purpose: .presetRecall)
        #expect(plan.snapshot == snapshot)
        #expect(plan.purpose == .presetRecall)
        #expect(plan.expectedDigest == StateDigest.of([4, 5, 6]))
        #expect(plan.expectedDigest == snapshot.digest)
    }

    @Test func anActiveInstanceIsRefusedAndNothingChanges() throws {
        let snapshot = try Self.snapshot()
        let target = try Self.target()
        let evidence = try Self.evidence(Self.range(1, 2))
        #expect(throws: InactiveRestoreError.instanceActive(.active)) {
            try Self.plan(snapshot, target, .active, evidence: evidence)
        }
        let freshSnapshot = try Self.snapshot()
        let freshTarget = try Self.target()
        let freshEvidence = try Self.evidence(Self.range(1, 2))
        #expect(snapshot == freshSnapshot && target == freshTarget && evidence == freshEvidence)
    }

    @Test func aRenderingInstanceIsRefusedAndNothingChanges() throws {
        let snapshot = try Self.snapshot()
        let target = try Self.target()
        #expect(throws: InactiveRestoreError.instanceActive(.rendering)) {
            try Self.plan(snapshot, target, .rendering)
        }
        let freshSnapshot = try Self.snapshot()
        let freshTarget = try Self.target()
        #expect(snapshot == freshSnapshot && target == freshTarget)
        #expect(try Self.plan(snapshot, target, .prepared).snapshot == snapshot)
    }

    @Test func aRunningInstanceIsRefusedBeforeTheQualificationIsLookedAt() throws {
        let bad = try Self.snapshot(storageClass: .fullState, vendor: "other")
        let target = try Self.target()
        #expect(throws: InactiveRestoreError.instanceActive(.rendering)) { try Self.plan(bad, target, .rendering) }
        #expect(throws: InactiveRestoreError.instanceActive(.active)) { try Self.plan(nil, target, .active) }
        let idle = InstanceActivity.allCases.filter { !$0.isRunning }
        #expect(idle == [.unprepared, .prepared])
    }

    @Test func aMissingSnapshotIsNotPlannedForAnIdleInstance() throws {
        let target = try Self.target()
        #expect(throws: InactiveRestoreError.notQualified([.missingBlob])) { try Self.plan(nil, target, .prepared) }
    }

    @Test func aNewerPluginVersionIsNotPlannedWithoutEvidenceAndIsPlannedWithIt() throws {
        let snapshot = try Self.snapshot(version: 0x0002_0000)
        let target = try Self.target(version: 0x0002_0200)
        let refusal = StateRefusal.versionNotQualified(
            captured: PluginVersion(rawValue: 0x0002_0000), current: PluginVersion(rawValue: 0x0002_0200)
        )
        #expect(throws: InactiveRestoreError.notQualified([refusal])) { try Self.plan(snapshot, target, .unprepared) }
        let evidence = try Self.evidence(Self.range(0x0002_0000, 0x0002_0200))
        let plan = try Self.plan(snapshot, target, .unprepared, evidence: evidence)
        #expect(plan.steps.count == 4)
        let narrow = try Self.evidence(Self.range(0x0002_0000, 0x0002_01FF))
        #expect(throws: InactiveRestoreError.notQualified([refusal])) {
            try Self.plan(snapshot, target, .unprepared, evidence: narrow)
        }
    }

    @Test func aFullStateBlobIsNotPlannedForADocumentButIsForAPresetRecall() throws {
        let full = try Self.snapshot(storageClass: .fullState)
        let target = try Self.target()
        #expect(throws: InactiveRestoreError.notQualified([.storageClassUnsuitable(.fullState, for: .document)])) {
            try Self.plan(full, target, .prepared, purpose: .document)
        }
        #expect(try Self.plan(full, target, .prepared, purpose: .presetRecall).purpose == .presetRecall)
    }

    @Test func aRefusedPlanReportsEveryRefusalInTheQualificationOrder() throws {
        let snapshot = try Self.snapshot(storageClass: .fullState, identity: Self.identity("Verb"), vendor: "a")
        let target = try Self.target(identity: Self.identity("Echo"), vendor: "b")
        #expect(throws: InactiveRestoreError.notQualified([
            .identityMismatch(captured: try Self.identity("Verb"), current: try Self.identity("Echo")),
            .vendorMismatch(captured: try Self.tag("a"), current: try Self.tag("b")),
            .storageClassUnsuitable(.fullState, for: .document)
        ])) { try Self.plan(snapshot, target, .unprepared) }
    }

    @Test func activationIsTheLastStepAndLoadingComesBeforeVerificationForEveryIdleInstance() throws {
        for instance in InstanceActivity.allCases where !instance.isRunning {
            let steps = try Self.plan(Self.snapshot(), Self.target(), instance).steps
            #expect(steps.last == .activateInstance)
            #expect(steps.firstIndex(of: .loadState) == steps.index(before: steps.firstIndex(of: .verifyDigest) ?? 0))
            #expect(Set(steps).count == steps.count)
        }
    }
}
