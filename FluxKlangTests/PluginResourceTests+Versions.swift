import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `VersionCompatibilityMatrix`: a version is qualified only by evidence the caller supplied, and a newer version is
/// never presumed compatible (#78, PLG6, slice B).
extension PluginResourceTests {
    private static func expectVerdicts(
        _ expected: [(UInt32, CompatibilityVerdict)], _ known: QualifiedVersionEvidence,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for (version, answer) in expected {
            #expect(try verdict(version, known) == answer, sourceLocation: sourceLocation)
        }
    }

    @Test func aVersionInsideAQualifiedRangeIsQualifiedAtBothEndsAndBetween() throws {
        let known = try Self.evidence([Self.range(0x0001_0000, 0x0003_0000)])
        let versions: [UInt32] = [0x0001_0000, 0x0001_0001, 0x0002_0000, 0x0002_FFFF, 0x0003_0000]
        for version in versions {
            #expect(try Self.verdict(version, known) == .qualified)
        }
    }

    @Test func aVersionJustOutsideAQualifiedRangeIsNotQualified() throws {
        let known = try Self.evidence([Self.range(0x0001_0000, 0x0003_0000)])
        try Self.expectVerdicts([
            (0x0000_0000, .notQualified(.older)), (0x0000_FFFF, .notQualified(.older)),
            (0x0003_0001, .notQualified(.newer)), (UInt32.max, .notQualified(.newer))
        ], known)
    }

    @Test func aNewerVersionIsNeverPresumedCompatible() throws {
        let known = try Self.evidence([Self.range(0x0001_0000, 0x0001_0500)])
        try Self.expectVerdicts([
            (0x0001_0500, .qualified), (0x0001_0501, .notQualified(.newer)), (0x0001_0600, .notQualified(.newer)),
            (0x0002_0000, .notQualified(.newer)), (0x7FFF_FFFF, .notQualified(.newer)),
            (UInt32.max, .notQualified(.newer))
        ], known)
    }

    @Test func aVersionInTheGapBetweenTwoRangesIsNewerThanTheLowerOne() throws {
        let known = try Self.evidence([
            Self.range(0x0001_0000, 0x0001_0200), Self.range(0x0002_0000, 0x0002_0500)
        ])
        try Self.expectVerdicts([
            (0x0000_FFFF, .notQualified(.older)), (0x0001_0000, .qualified), (0x0001_0200, .qualified),
            (0x0001_0201, .notQualified(.newer)), (0x0001_FFFF, .notQualified(.newer)),
            (0x0002_0000, .qualified), (0x0002_0500, .qualified), (0x0002_0501, .notQualified(.newer))
        ], known)
    }

    @Test func aRangeThatCoversTheVersionOutweighsARangeBelowIt() throws {
        let known = try Self.evidence([
            Self.range(0x0001_0000, 0x0001_0200), Self.range(0x0003_0000, 0x0003_0500)
        ])
        try Self.expectVerdicts([(0x0003_0100, .qualified), (0x0003_0501, .notQualified(.newer))], known)
    }

    @Test func overlappingRangesQualifyTheirUnion() throws {
        let known = try Self.evidence([
            Self.range(0x0001_0000, 0x0001_0300), Self.range(0x0001_0200, 0x0001_0500)
        ])
        try Self.expectVerdicts([
            (0x0000_FFFF, .notQualified(.older)), (0x0001_0000, .qualified), (0x0001_0250, .qualified),
            (0x0001_0500, .qualified), (0x0001_0501, .notQualified(.newer))
        ], known)
    }

    @Test func aSingleVersionRangeQualifiesExactlyThatVersion() throws {
        let known = try Self.evidence([Self.range(0x0002_0000, 0x0002_0000)])
        try Self.expectVerdicts([
            (0x0001_FFFF, .notQualified(.older)), (0x0002_0000, .qualified), (0x0002_0001, .notQualified(.newer))
        ], known)
    }

    @Test func theEdgesOfTheVersionSpaceBehaveLikeAnyOtherBound() throws {
        try Self.expectVerdicts([(0, .qualified), (1, .notQualified(.newer))], Self.evidence([Self.range(0, 0)]))
        let top = UInt32.max
        try Self.expectVerdicts(
            [(top, .qualified), (top - 1, .notQualified(.older))], Self.evidence([Self.range(top, top)])
        )
        let everything = try Self.evidence([Self.range(0, top)])
        let inside: [UInt32] = [0, 1, top - 1, top]
        for version in inside {
            #expect(try Self.verdict(version, everything) == .qualified)
        }
    }

    @Test func theVerdictDoesNotDependOnTheOrderOfTheRanges() throws {
        let ranges = try [
            Self.range(0x0001_0000, 0x0001_0200), Self.range(0x0002_0000, 0x0002_0500),
            Self.range(0x0001_0100, 0x0001_0300)
        ]
        let expected: [(UInt32, CompatibilityVerdict)] = [
            (0x0000_FFFF, .notQualified(.older)), (0x0001_0250, .qualified), (0x0001_0300, .qualified),
            (0x0001_0301, .notQualified(.newer)), (0x0002_0000, .qualified), (0x0002_0501, .notQualified(.newer))
        ]
        let forward = try Self.evidence(ranges)
        let backward = try Self.evidence(Array(ranges.reversed()))
        let rotated = try Self.evidence(Array(ranges.dropFirst()) + ranges.prefix(1))
        for known in [forward, backward, rotated] {
            try Self.expectVerdicts(expected, known)
        }
    }

    @Test func noEvidenceMeansTheVersionIsUnknownNeverQualified() throws {
        for version in [UInt32(0), 0x0001_0000, UInt32.max] {
            #expect(try Self.verdict(version, QualifiedVersionEvidence.none) == .unknown)
            #expect(try Self.verdict(version, Self.evidence([])) == .unknown)
        }
    }

    @Test func evidenceForAnotherPluginNeverQualifiesThisOne() throws {
        let others = try [
            Self.identity("Echo"), Self.identity(manufacturer: "Zeta"), Self.identity(format: .audioUnitV3),
            Self.identity(type: "aumu")
        ]
        for other in others {
            let known = try Self.evidence([Self.range(0, UInt32.max, owner: other)])
            #expect(try Self.verdict(0x0001_0000, known) == .unknown)
        }
        let mixed = try Self.evidence([
            Self.range(0x0001_0000, 0x0001_0200, owner: Self.identity("Echo")),
            Self.range(0x0002_0000, 0x0002_0500)
        ])
        try Self.expectVerdicts([(0x0001_0100, .notQualified(.older)), (0x0002_0100, .qualified)], mixed)
    }

    @Test func aDifferentVendorTagIsNotQualifiedEvenInsideTheRange() throws {
        let known = try Self.evidence([Self.range(0x0001_0000, 0x0003_0000)])
        let refused = CompatibilityVerdict.notQualified(.unknownVendor)
        #expect(try Self.verdict(0x0002_0000, known, vendor: "acme.state.v2") == refused)
        #expect(try Self.verdict(0x0001_0000, known, vendor: "other") == refused)
        #expect(try Self.verdict(0x0009_0000, known, vendor: "other") == refused)
        #expect(try Self.verdict(0x0000_0001, known, vendor: "x") == refused)
        #expect(try Self.verdict(0x0002_0000, known) == .qualified)
    }

    @Test func aVersionIsJudgedOnlyAgainstRangesOfItsOwnVendorTag() throws {
        let known = try Self.evidence([
            Self.range(0x0001_0000, 0x0001_0200, vendor: "vendor.one"),
            Self.range(0x0002_0000, 0x0002_0500, vendor: "vendor.two")
        ])
        let oneAnswers: [(UInt32, CompatibilityVerdict)] = [
            (0x0001_0100, .qualified), (0x0002_0100, .notQualified(.newer)), (0x0000_0500, .notQualified(.older))
        ]
        for (version, answer) in oneAnswers {
            #expect(try Self.verdict(version, known, vendor: "vendor.one") == answer)
        }
        let twoAnswers: [(UInt32, CompatibilityVerdict)] = [
            (0x0002_0100, .qualified), (0x0001_0100, .notQualified(.older)), (0x0003_0000, .notQualified(.newer))
        ]
        for (version, answer) in twoAnswers {
            #expect(try Self.verdict(version, known, vendor: "vendor.two") == answer)
        }
    }

    @Test func theMatrixTreatsVendorTagsThatOnlyCanonicallyMatchAsDifferentVendors() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let known = try Self.evidence([Self.range(0x0001_0000, 0x0003_0000, vendor: composed)])
        let refused = CompatibilityVerdict.notQualified(.unknownVendor)
        #expect(try Self.verdict(0x0002_0000, known, vendor: decomposed) == refused)
        #expect(try Self.verdict(0x0002_0000, known, vendor: composed) == .qualified)
        let other = try Self.evidence([Self.range(0x0001_0000, 0x0003_0000, vendor: decomposed)])
        #expect(try Self.verdict(0x0002_0000, other, vendor: composed) == refused)
        #expect(try Self.verdict(0x0002_0000, other, vendor: decomposed) == .qualified)
    }

    @Test func everyReasonForNotBeingQualifiedIsReachable() throws {
        let known = try Self.evidence([Self.range(0x0001_0000, 0x0003_0000)])
        let reached = try [
            Self.verdict(0x0000_0001, known), Self.verdict(0x0004_0000, known),
            Self.verdict(0x0002_0000, known, vendor: "other")
        ]
        #expect(reached == [.notQualified(.older), .notQualified(.newer), .notQualified(.unknownVendor)])
        #expect(Set(NotQualifiedReason.allCases) == [.older, .newer, .unknownVendor])
        #expect(CompatibilityVerdict.unknown != .qualified)
    }
}
