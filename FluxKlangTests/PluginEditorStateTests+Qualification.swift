import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginEditorStateTests {
    private static func qualify(
        _ snapshot: PluginStateSnapshot?, _ target: PluginStateTarget, _ purpose: StatePurpose = .document,
        _ evidence: QualifiedVersionEvidence = .none
    ) -> [StateRefusal] {
        StateQualification.evaluate(snapshot: snapshot, target: target, purpose: purpose, evidence: evidence).refusals
    }

    @Test func aMatchingSnapshotIsQualifiedWithNoRefusalsForBothPurposes() throws {
        let snapshot = try Self.snapshot()
        for purpose in StatePurpose.allCases {
            let result = StateQualification.evaluate(
                snapshot: snapshot, target: try Self.target(), purpose: purpose, evidence: .none
            )
            #expect(result.isQualified && result.refusals.isEmpty)
        }
    }

    @Test func aMissingSnapshotIsReportedAloneAsAMissingBlob() throws {
        #expect(Self.qualify(nil, try Self.target()) == [.missingBlob])
        let result = StateQualification.evaluate(
            snapshot: nil, target: try Self.target(), purpose: .presetRecall, evidence: .none
        )
        #expect(!result.isQualified)
    }

    @Test func aDifferentIdentityIsRefusedWithBothIdentities() throws {
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        #expect(Self.qualify(try Self.snapshot(identity: verb), try Self.target(identity: echo))
            == [.identityMismatch(captured: verb, current: echo)])
        let version3 = try Self.identity("Verb", format: .audioUnitV3)
        #expect(Self.qualify(try Self.snapshot(identity: verb), try Self.target(identity: version3))
            == [.identityMismatch(captured: verb, current: version3)])
    }

    @Test func aDifferentVendorTagIsRefusedWithBothTags() throws {
        let result = Self.qualify(try Self.snapshot(vendor: "acme.v1"), try Self.target(vendor: "acme.v2"))
        #expect(result == [.vendorMismatch(captured: try Self.tag("acme.v1"), current: try Self.tag("acme.v2"))])
        let decomposed = Self.qualify(try Self.snapshot(vendor: "caf\u{E9}"), try Self.target(vendor: "cafe\u{301}"))
        #expect(decomposed.count == 1)
    }

    @Test func aNewerCurrentVersionIsNeverPresumedCompatible() throws {
        let snapshot = try Self.snapshot(version: 0x0002_0100)
        let captured = PluginVersion(rawValue: 0x0002_0100)
        for newer: UInt32 in [0x0002_0101, 0x0002_0200, 0x0003_0000] {
            let current = PluginVersion(rawValue: newer)
            #expect(Self.qualify(snapshot, try Self.target(version: newer))
                == [.versionNotQualified(captured: captured, current: current)])
        }
    }

    private static func versions(
        _ captured: UInt32, _ current: UInt32, _ evidence: QualifiedVersionEvidence = .none
    ) throws -> [StateRefusal] {
        qualify(try snapshot(version: captured), try target(version: current), .document, evidence)
    }

    private static func notQualified(_ captured: UInt32, _ current: UInt32) -> StateRefusal {
        .versionNotQualified(captured: PluginVersion(rawValue: captured), current: PluginVersion(rawValue: current))
    }

    @Test func anOlderCurrentVersionIsNotPresumedCompatibleEither() throws {
        #expect(try Self.versions(0x0002_0100, 0x0002_00FF) == [Self.notQualified(0x0002_0100, 0x0002_00FF)])
        #expect(try Self.versions(0x0002_0100, 0x0001_0100).count == 1)
    }

    @Test func aRangeQualifiesBothVersionsAtItsInclusiveEdgesInEitherDirection() throws {
        let evidence = try Self.evidence(Self.range(0x0002_0000, 0x0002_0200))
        #expect(try Self.versions(0x0002_0000, 0x0002_0200, evidence).isEmpty)
        #expect(try Self.versions(0x0002_0200, 0x0002_0000, evidence).isEmpty)
        #expect(try Self.versions(0x0002_0000, 0x0002_0000).isEmpty)
        #expect(try Self.versions(0x0002_0100, 0x0002_0200, evidence).isEmpty)
    }

    @Test func versionsJustOutsideARangeAreNotQualifiedOnEitherSide() throws {
        let evidence = try Self.evidence(Self.range(0x0002_0000, 0x0002_0200))
        let inside: UInt32 = 0x0002_0100
        for outside: UInt32 in [0x0001_FFFF, 0x0002_0201] {
            #expect(try Self.versions(inside, outside, evidence) == [Self.notQualified(inside, outside)])
            #expect(try Self.versions(outside, inside, evidence) == [Self.notQualified(outside, inside)])
        }
    }

    @Test func oneRangeMustCoverBothVersionsAndTwoRangesNeverCombine() throws {
        let evidence = try Self.evidence(Self.range(0x0002_0000, 0x0002_0100), Self.range(0x0002_0200, 0x0002_0300))
        #expect(try Self.versions(0x0002_0100, 0x0002_0200, evidence).count == 1)
        #expect(try Self.versions(0x0002_0200, 0x0002_0300, evidence).isEmpty)
    }

    @Test func aRangeForAnotherIdentityOrVendorNeverQualifiesTheVersions() throws {
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        let low: UInt32 = 0x0002_0000
        let high: UInt32 = 0x0002_0200
        let forEcho = try Self.evidence(Self.range(low, high, identity: echo))
        #expect(try Self.versions(low, high, forEcho).count == 1)
        let forOtherVendor = try Self.evidence(Self.range(low, high, vendor: "other"))
        #expect(try Self.versions(low, high, forOtherVendor).count == 1)
        let crossIdentity = Self.qualify(
            try Self.snapshot(identity: verb, version: low), try Self.target(identity: echo, version: high),
            .document, forEcho
        )
        #expect(crossIdentity == [
            .identityMismatch(captured: verb, current: echo), Self.notQualified(low, high)
        ])
        let forVerb = try Self.evidence(Self.range(low, high, identity: verb))
        let crossForSnapshot = Self.qualify(
            try Self.snapshot(identity: verb, version: low), try Self.target(identity: echo, version: high),
            .document, forVerb
        )
        #expect(crossForSnapshot == crossIdentity)
        let forSnapshotVendor = try Self.evidence(Self.range(low, high))
        let crossVendorForSnapshot = Self.qualify(
            try Self.snapshot(version: low), try Self.target(version: high, vendor: "acme.v2"),
            .document, forSnapshotVendor
        )
        #expect(crossVendorForSnapshot.count == 2)
        let forTargetVendor = try Self.evidence(Self.range(low, high, vendor: "acme.v2"))
        let crossVendor = Self.qualify(
            try Self.snapshot(version: low), try Self.target(version: high, vendor: "acme.v2"),
            .document, forTargetVendor
        )
        #expect(crossVendor.count == 2)
        #expect(crossVendor.last == Self.notQualified(low, high))
    }

    @Test func theOrderOfTheEvidenceRangesNeverChangesTheDecision() throws {
        let covering = try Self.range(0x0002_0000, 0x0002_0200)
        let other = try Self.range(0x0009_0000, 0x0009_0100)
        let snapshot = try Self.snapshot(version: 0x0002_0000)
        let target = try Self.target(version: 0x0002_0200)
        let forward = try QualifiedVersionEvidence(ranges: [covering, other])
        let reversed = try QualifiedVersionEvidence(ranges: [other, covering])
        #expect(Self.qualify(snapshot, target, .document, forward).isEmpty)
        #expect(Self.qualify(snapshot, target, .document, reversed).isEmpty)
    }

    @Test func eachStorageClassAndPurposePairingIsDecidedExactly() throws {
        let document = try Self.snapshot(storageClass: .fullStateForDocument)
        let full = try Self.snapshot(storageClass: .fullState)
        let target = try Self.target()
        #expect(Self.qualify(document, target, .document).isEmpty)
        #expect(Self.qualify(document, target, .presetRecall).isEmpty)
        #expect(Self.qualify(full, target, .presetRecall).isEmpty)
        #expect(Self.qualify(full, target, .document) == [.storageClassUnsuitable(.fullState, for: .document)])
    }

    @Test func severalDefectsAreReportedInTheFixedOrderWhicheverSideHoldsWhich() throws {
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        let first = PluginVersion(rawValue: 0x0001_0000)
        let second = PluginVersion(rawValue: 0x0004_0000)
        let forward = Self.qualify(
            try Self.snapshot(storageClass: .fullState, identity: verb, version: first.rawValue, vendor: "a"),
            try Self.target(identity: echo, version: second.rawValue, vendor: "b")
        )
        #expect(forward == [
            .identityMismatch(captured: verb, current: echo),
            .vendorMismatch(captured: try Self.tag("a"), current: try Self.tag("b")),
            .versionNotQualified(captured: first, current: second),
            .storageClassUnsuitable(.fullState, for: .document)
        ])
        let swapped = Self.qualify(
            try Self.snapshot(storageClass: .fullState, identity: echo, version: second.rawValue, vendor: "b"),
            try Self.target(identity: verb, version: first.rawValue, vendor: "a")
        )
        #expect(swapped == [
            .identityMismatch(captured: echo, current: verb),
            .vendorMismatch(captured: try Self.tag("b"), current: try Self.tag("a")),
            .versionNotQualified(captured: second, current: first),
            .storageClassUnsuitable(.fullState, for: .document)
        ])
    }

    @Test func eachPairOfDefectsKeepsTheFixedRelativeOrder() throws {
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        let idAndClass = Self.qualify(
            try Self.snapshot(storageClass: .fullState, identity: verb), try Self.target(identity: echo)
        )
        #expect(idAndClass == [
            .identityMismatch(captured: verb, current: echo), .storageClassUnsuitable(.fullState, for: .document)
        ])
        let vendorAndVersion = Self.qualify(
            try Self.snapshot(version: 1, vendor: "a"), try Self.target(version: 2, vendor: "b")
        )
        #expect(vendorAndVersion == [
            .vendorMismatch(captured: try Self.tag("a"), current: try Self.tag("b")),
            .versionNotQualified(captured: PluginVersion(rawValue: 1), current: PluginVersion(rawValue: 2))
        ])
        let versionAndClass = Self.qualify(
            try Self.snapshot(storageClass: .fullState, version: 1), try Self.target(version: 2)
        )
        #expect(versionAndClass == [
            .versionNotQualified(captured: PluginVersion(rawValue: 1), current: PluginVersion(rawValue: 2)),
            .storageClassUnsuitable(.fullState, for: .document)
        ])
    }

    @Test func aRangeWithLowerAboveUpperIsRefusedAndOneWithEqualBoundsIsAccepted() throws {
        let lower = PluginVersion(rawValue: 0x0002_0001)
        let upper = PluginVersion(rawValue: 0x0002_0000)
        #expect(throws: QualificationEvidenceError.invertedRange(lower: lower, upper: upper)) {
            try Self.range(0x0002_0001, 0x0002_0000)
        }
        let single = try Self.range(0x0002_0000, 0x0002_0000)
        #expect(single.covers(upper) && !single.covers(lower))
        #expect(!single.covers(PluginVersion(rawValue: 0x0001_FFFF)))
    }

    @Test func theEvidenceAccepts256RangesAndRefusesOneMore() throws {
        let one = try Self.range(1, 2)
        #expect(try QualifiedVersionEvidence(ranges: Array(repeating: one, count: 256)).ranges.count == 256)
        #expect(throws: QualificationEvidenceError.tooManyRanges(count: 257, limit: 256)) {
            try QualifiedVersionEvidence(ranges: Array(repeating: one, count: 257))
        }
        #expect(QualifiedVersionEvidence.none.ranges.isEmpty)
        #expect(try QualifiedVersionEvidence(ranges: []).ranges.isEmpty)
    }
}
