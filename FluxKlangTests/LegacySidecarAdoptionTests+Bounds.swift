import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Byte caps of the sidecar plan. All counts are `Data.count`, so they are bytes, not characters.
extension LegacySidecarAdoptionTests {
    @Test
    func aDraftOfExactlyTheEntryCapIsPlannedAndOneByteMoreIsOversized() throws {
        let limits = try Fixture.limits(entryBytes: 1000, totalBytes: 10_000)
        let atCap = Fixture.object(bytes: 1000)
        let overCap = Fixture.object(bytes: 1001)
        #expect(atCap.count == 1000)
        let plan = try LegacySidecarPlan.make(draft: atCap, connections: nil, limits: limits)
        try #require(plan.files.count == 1)
        #expect(Array(plan.files[0].bytes) == Array(atCap))
        let expected: LegacySidecarRefusal = .oversized(.draft)
        #expect(Fixture.refusal(draft: overCap, connections: nil, limits: limits) == expected)
    }

    @Test
    func aConnectionsFileOfExactlyTheEntryCapIsPlannedAndOneByteMoreIsOversized() throws {
        let limits = try Fixture.limits(entryBytes: 1000, totalBytes: 10_000)
        let atCap = Fixture.object(bytes: 1000)
        let overCap = Fixture.object(bytes: 1001)
        let plan = try LegacySidecarPlan.make(draft: nil, connections: atCap, limits: limits)
        try #require(plan.files.count == 1)
        #expect(Array(plan.files[0].bytes) == Array(atCap))
        let expected: LegacySidecarRefusal = .oversized(.connections)
        #expect(Fixture.refusal(draft: nil, connections: overCap, limits: limits) == expected)
    }

    @Test
    func theFourMiBDocumentCeilingBoundsADraftWhenTheEntryCapIsAboveIt() throws {
        let ceiling = ProjectGraphLimits.documentBytes
        let limits = try Fixture.limits(entryBytes: ceiling * 2, totalBytes: ceiling * 4)
        let atCeiling = Fixture.object(bytes: ceiling)
        #expect(atCeiling.count == 4_194_304)
        let plan = try LegacySidecarPlan.make(draft: atCeiling, connections: nil, limits: limits)
        try #require(plan.files.count == 1)
        #expect(plan.files[0].bytes.count == 4_194_304)
        let overCeiling = Fixture.object(bytes: ceiling + 1)
        let expected: LegacySidecarRefusal = .oversized(.draft)
        #expect(Fixture.refusal(draft: overCeiling, connections: nil, limits: limits) == expected)
    }

    @Test
    func theFourMiBDocumentCeilingBoundsAConnectionsFileWhenTheEntryCapIsAboveIt() throws {
        let ceiling = ProjectGraphLimits.documentBytes
        let limits = try Fixture.limits(entryBytes: ceiling * 2, totalBytes: ceiling * 4)
        let atCeiling = Fixture.object(bytes: ceiling)
        let plan = try LegacySidecarPlan.make(draft: nil, connections: atCeiling, limits: limits)
        try #require(plan.files.count == 1)
        #expect(plan.files[0].bytes.count == 4_194_304)
        let overCeiling = Fixture.object(bytes: ceiling + 1)
        let expected: LegacySidecarRefusal = .oversized(.connections)
        #expect(Fixture.refusal(draft: nil, connections: overCeiling, limits: limits) == expected)
    }

    @Test
    func twoSidecarsTogetherAtTheTotalArePlannedAndOneByteMoreIsOversizedAsCombined() throws {
        let limits = try Fixture.limits(entryBytes: 1000, totalBytes: 1500)
        let plan = try LegacySidecarPlan.make(
            draft: Fixture.object(bytes: 800), connections: Fixture.object(bytes: 700), limits: limits
        )
        try #require(plan.files.count == 2)
        #expect(plan.files[0].bytes.count == 800)
        #expect(plan.files[1].bytes.count == 700)
        let expected: LegacySidecarRefusal = .oversized(.combined)
        let connectionsOver = Fixture.refusal(
            draft: Fixture.object(bytes: 800), connections: Fixture.object(bytes: 701), limits: limits
        )
        let draftOver = Fixture.refusal(
            draft: Fixture.object(bytes: 801), connections: Fixture.object(bytes: 700), limits: limits
        )
        #expect(connectionsOver == expected)
        #expect(draftOver == expected)
    }

    @Test
    func aSingleSidecarAtTheEntryCapIsNotCountedAsCombinedWhenTheTotalEqualsTheEntryCap() throws {
        let limits = try Fixture.limits(entryBytes: 1000, totalBytes: 1000)
        let plan = try LegacySidecarPlan.make(draft: Fixture.object(bytes: 1000), connections: nil, limits: limits)
        #expect(plan.files.count == 1)
    }

    @Test
    func aBlobWithFewerCharactersThanTheCapButMoreBytesIsOversizedAndOneAtTheCapInBytesIsPlanned() throws {
        let limits = try Fixture.limits(entryBytes: 100, totalBytes: 1000)
        let euro = String(repeating: "\u{20AC}", count: 30)
        let atCapText = "{\"k\":\"\(euro)xx\"}"
        let atCap = Fixture.text(atCapText)
        #expect(atCap.count == 100)
        let plan = try LegacySidecarPlan.make(draft: atCap, connections: nil, limits: limits)
        #expect(plan.files.count == 1)
        let overText = "{\"k\":\"\(euro)\u{20AC}\"}"
        let overCap = Fixture.text(overText)
        #expect(overCap.count == 101)
        #expect(overText.unicodeScalars.count < 100)
        let expected: LegacySidecarRefusal = .oversized(.draft)
        #expect(Fixture.refusal(draft: overCap, connections: nil, limits: limits) == expected)
    }

    @Test
    func limitsOfZeroBytesPlanNothingAndRefuseAnyNonEmptySidecarAsOversizedButAZeroByteOneAsEmpty() throws {
        let limits = try Fixture.limits(entryBytes: 0, totalBytes: 0)
        let plan = try LegacySidecarPlan.make(draft: nil, connections: nil, limits: limits)
        #expect(plan.isEmpty)
        let oversized: LegacySidecarRefusal = .oversized(.draft)
        #expect(Fixture.refusal(draft: Fixture.text("{}"), connections: nil, limits: limits) == oversized)
        let empty: LegacySidecarRefusal = .empty(.pendingDraft)
        #expect(Fixture.refusal(draft: Data(), connections: nil, limits: limits) == empty)
    }
}
