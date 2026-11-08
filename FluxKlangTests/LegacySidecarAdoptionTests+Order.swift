import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The refusal order of `LegacySidecarPlan.make`, one fixture holding both defects for each adjacent pair.
/// The order is: oversized draft, oversized connections, oversized combined, empty draft, empty connections,
/// invalid UTF-8 draft, invalid UTF-8 connections, undecodable draft, undecodable connections, non-object draft,
/// non-object connections. A stage finishes for both sources before the next stage starts.
/// The pair (oversized combined, empty draft) cannot both hold: `combined` needs both blobs non-empty and each
/// within the entry cap, and an empty blob leaves the other within the entry cap, which is at most the total
/// (`ProjectPackageLimits.init` requires entry cap <= total). It has no fixture; the pair (oversized connections,
/// empty draft) pins "byte caps before emptiness".
extension LegacySidecarAdoptionTests {
    private static let truncated = Fixture.text("{")
    private static let array = Fixture.text("[]")

    private static func capped() throws -> ProjectPackageLimits {
        try Fixture.limits(entryBytes: 1000, totalBytes: 1500)
    }

    /// Pair (1,2): both sources oversized.
    @Test
    func whenBothSidecarsAreOversizedTheDraftIsReported() throws {
        let both = Fixture.object(bytes: 1001)
        let refusal = Fixture.refusal(draft: both, connections: both, limits: try Self.capped())
        let expected: LegacySidecarRefusal = .oversized(.draft)
        #expect(refusal == expected)
    }

    /// Pair (2,3): the oversized connections also push the sum over the total.
    @Test
    func anOversizedConnectionsFileIsReportedBeforeTheCombinedTotalEvenWhenBothHold() throws {
        let draft = Fixture.object(bytes: 600)
        let connections = Fixture.object(bytes: 1001)
        let refusal = Fixture.refusal(draft: draft, connections: connections, limits: try Self.capped())
        let expected: LegacySidecarRefusal = .oversized(.connections)
        #expect(refusal == expected)
    }

    /// Pair (2,4), standing in for (3,4): an oversized source with an empty other source.
    @Test
    func byteCapsAreCheckedBeforeEmptiness() throws {
        let limits = try Self.capped()
        let over = Fixture.object(bytes: 1001)
        let connectionsOver = Fixture.refusal(draft: Data(), connections: over, limits: limits)
        let draftOver = Fixture.refusal(draft: over, connections: Data(), limits: limits)
        let expectedConnections: LegacySidecarRefusal = .oversized(.connections)
        let expectedDraft: LegacySidecarRefusal = .oversized(.draft)
        #expect(connectionsOver == expectedConnections)
        #expect(draftOver == expectedDraft)
    }

    /// Pair (4,5): both sources empty.
    @Test
    func whenBothSidecarsAreEmptyTheDraftIsReported() throws {
        let refusal = Fixture.refusal(draft: Data(), connections: Data(), limits: try Fixture.limits())
        let expected: LegacySidecarRefusal = .empty(.pendingDraft)
        #expect(refusal == expected)
    }

    /// Pair (5,6): an empty connections file with an invalid-UTF-8 draft, and the same with the roles swapped.
    @Test
    func emptinessIsCheckedBeforeUTF8ForBothSources() throws {
        let limits = try Fixture.limits()
        let invalid = Fixture.invalidUTF8(Fixture.lone)
        let connectionsEmpty = Fixture.refusal(draft: invalid, connections: Data(), limits: limits)
        let draftEmpty = Fixture.refusal(draft: Data(), connections: invalid, limits: limits)
        let expectedConnections: LegacySidecarRefusal = .empty(.connections)
        let expectedDraft: LegacySidecarRefusal = .empty(.pendingDraft)
        #expect(connectionsEmpty == expectedConnections)
        #expect(draftEmpty == expectedDraft)
    }

    /// Pair (6,7): both sources invalid UTF-8.
    @Test
    func whenBothSidecarsAreInvalidUTF8TheDraftIsReported() throws {
        let refusal = Fixture.refusal(
            draft: Fixture.invalidUTF8(Fixture.lone), connections: Fixture.invalidUTF8(Fixture.overlong),
            limits: try Fixture.limits()
        )
        let expected: LegacySidecarRefusal = .notUTF8(.pendingDraft)
        #expect(refusal == expected)
    }

    /// Pair (7,8): invalid-UTF-8 connections with an undecodable draft reports the connections (every source is
    /// checked for UTF-8 before any source is decoded), and invalid-UTF-8 draft with undecodable connections
    /// reports the draft.
    @Test
    func utf8IsCheckedForBothSourcesBeforeAnySourceIsDecoded() throws {
        let limits = try Fixture.limits()
        let invalid = Fixture.invalidUTF8(Fixture.surrogate)
        let connectionsInvalid = Fixture.refusal(draft: Self.truncated, connections: invalid, limits: limits)
        let draftInvalid = Fixture.refusal(draft: invalid, connections: Self.truncated, limits: limits)
        let expectedConnections: LegacySidecarRefusal = .notUTF8(.connections)
        let expectedDraft: LegacySidecarRefusal = .notUTF8(.pendingDraft)
        #expect(connectionsInvalid == expectedConnections)
        #expect(draftInvalid == expectedDraft)
    }

    /// Pair (8,9): both sources undecodable.
    @Test
    func whenBothSidecarsAreUndecodableTheDraftIsReported() throws {
        let limits = try Fixture.limits()
        let refusal = Fixture.refusal(draft: Self.truncated, connections: Fixture.text("nope"), limits: limits)
        let expected: LegacySidecarRefusal = .undecodable(.pendingDraft)
        #expect(refusal == expected)
    }

    /// Pair (9,10): undecodable connections with a draft that is valid JSON but an array, and the roles swapped.
    @Test
    func decodingIsDoneForBothSourcesBeforeAnySourceIsCheckedForAnObject() throws {
        let limits = try Fixture.limits()
        let connectionsBad = Fixture.refusal(draft: Self.array, connections: Self.truncated, limits: limits)
        let draftBad = Fixture.refusal(draft: Self.truncated, connections: Self.array, limits: limits)
        let expectedConnections: LegacySidecarRefusal = .undecodable(.connections)
        let expectedDraft: LegacySidecarRefusal = .undecodable(.pendingDraft)
        #expect(connectionsBad == expectedConnections)
        #expect(draftBad == expectedDraft)
    }

    /// Pair (10,11): both sources are arrays.
    @Test
    func whenBothSidecarsAreArraysTheDraftIsReported() throws {
        let limits = try Fixture.limits()
        let refusal = Fixture.refusal(draft: Self.array, connections: Fixture.text("[1]"), limits: limits)
        let expected: LegacySidecarRefusal = .notAnObject(.pendingDraft)
        #expect(refusal == expected)
    }

    /// A non-object connections file is reported when the draft is a valid object.
    @Test
    func aValidDraftDoesNotHideANonObjectConnectionsFile() throws {
        let limits = try Fixture.limits()
        let refusal = Fixture.refusal(draft: Fixture.draftBytes, connections: Self.array, limits: limits)
        let expected: LegacySidecarRefusal = .notAnObject(.connections)
        #expect(refusal == expected)
    }
}
