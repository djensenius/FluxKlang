import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Plugin resource reservations, the pressure and latency-change policies and the version compatibility matrix
/// (#78, slices A and B of PLG6). The tests live in extensions of this suite; this file holds the fixtures.
/// Expected numbers are literals, never the production constants, so a changed limit fails a test.
struct PluginResourceTests {
    static let scratchLimit = 16_777_216
    static let instanceLimit = 256
    static let reservationLimit = 4_096
    static let frameLimit = 16_384

    static func code(_ text: String) throws -> PluginFourCharacterCode {
        try PluginFourCharacterCode(text)
    }

    static func identity(
        _ subtype: String = "Verb", manufacturer: String = "Acme", type: String = "aufx",
        format: PluginFormat = .audioUnitV2
    ) throws -> PluginIdentity {
        try PluginIdentity(format: format, type: code(type), subtype: code(subtype), manufacturer: code(manufacturer))
    }

    /// A distinct identity per index: the index as four lowercase hex digits, so the owner order is the index order.
    static func indexedIdentity(_ index: Int) throws -> PluginIdentity {
        let digits = Array("0123456789abcdef")
        return try identity(String((0..<4).map { digits[(index >> (12 - 4 * $0)) & 0xF] }))
    }

    static func reservation(
        _ owner: PluginIdentity, scratch: Int = 0, instances: Int = 0, pinned: Bool = false
    ) throws -> ResourceReservation {
        try ResourceReservation.make(owner: owner, scratchBytes: scratch, instances: instances, pinned: pinned)
    }

    /// A pure pin of the indexed owner: pinned, no scratch and no instances.
    static func pin(_ index: Int) throws -> ResourceReservation {
        try reservation(indexedIdentity(index), pinned: true)
    }

    static func ledger(total: Int = 1_000, instances: Int = 8) throws -> ResourceLedger {
        try ResourceLedger.make(totalScratchBytes: total, maximumInstances: instances)
    }

    static func filled(_ base: ResourceLedger, _ items: [ResourceReservation]) throws -> ResourceLedger {
        var result = base
        for item in items { result = try result.reserve(item) }
        return result
    }

    /// 4,096 pure pins reserved from the highest owner down, so every insert lands at the front.
    static func fullLedger(total: Int = 1_000, instances: Int = 8) throws -> ResourceLedger {
        var result = try ledger(total: total, instances: instances)
        for index in stride(from: reservationLimit - 1, through: 0, by: -1) {
            result = try result.reserve(pin(index))
        }
        return result
    }

    private static let cachedFullLedger: Result<ResourceLedger, any Error> = Result { try fullLedger() }

    /// `fullLedger()` built once and shared: every test only reads it.
    static func sharedFullLedger() throws -> ResourceLedger {
        try cachedFullLedger.get()
    }

    /// The owner order spelled out on its own: format (au2 before au3), type, subtype, manufacturer.
    static func orderKey(_ owner: PluginIdentity) -> [UInt32] {
        let format: UInt32 = owner.format == .audioUnitV2 ? 2 : 3
        return [format, owner.type.rawValue, owner.subtype.rawValue, owner.manufacturer.rawValue]
    }

    /// The documented invariants of a ledger, checked against sums and an order key built here.
    static func expectInvariants(_ ledger: ResourceLedger, sourceLocation: SourceLocation = #_sourceLocation) {
        let items = ledger.reservations
        #expect(ledger.reservedScratchBytes == items.map(\.scratchBytes).reduce(0, +), sourceLocation: sourceLocation)
        #expect(ledger.reservedInstances == items.map(\.instances).reduce(0, +), sourceLocation: sourceLocation)
        #expect(ledger.reservedScratchBytes <= ledger.totalScratchBytes, sourceLocation: sourceLocation)
        #expect(ledger.reservedInstances <= ledger.maximumInstances, sourceLocation: sourceLocation)
        #expect(items.count <= 4_096, sourceLocation: sourceLocation)
        let keys = items.map { orderKey($0.owner) }
        let ascending = zip(keys, keys.dropFirst()).allSatisfy { $0.0.lexicographicallyPrecedes($0.1) }
        #expect(ascending, sourceLocation: sourceLocation)
    }

    /// A refused `reserve` throws exactly `expected`; the ledger it was called on equals its former self.
    static func expectReserveRefused(
        _ ledger: ResourceLedger, _ item: ResourceReservation, _ expected: ResourceRefusal,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let before = ledger
        #expect(throws: expected, sourceLocation: sourceLocation) { try ledger.reserve(item) }
        #expect(ledger == before, sourceLocation: sourceLocation)
    }

    /// A refused `release` throws exactly `expected`; the ledger it was called on equals its former self.
    static func expectReleaseRefused(
        _ ledger: ResourceLedger, _ owner: PluginIdentity, _ expected: ResourceRefusal,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let before = ledger
        #expect(throws: expected, sourceLocation: sourceLocation) { try ledger.release(owner: owner) }
        #expect(ledger == before, sourceLocation: sourceLocation)
    }

    static func policy(_ deferAt: Int = 50, _ rejectAt: Int = 80) -> ResourcePressurePolicy {
        ResourcePressurePolicy(thresholds: PressureThresholds(defer: deferAt, reject: rejectAt))
    }

    /// A new-reservation request carrying a reservation of the given pin state; its numbers never matter.
    static func newRequest(pinned: Bool = false) throws -> WorkRequest {
        .newReservation(try reservation(identity("News"), scratch: 10, instances: 1, pinned: pinned))
    }

    static func evaluate(
        _ policy: ResourcePressurePolicy, used: Int, total: Int = 1_000, _ request: WorkRequest, held: Int = 0
    ) -> PressureDecision {
        policy.evaluate(usedScratchBytes: used, totalScratchBytes: total, request: request, heldNotes: held)
    }

    static func decide(_ previous: Int, _ next: Int, bound: Int) -> LatencyDecision {
        LatencyChangePolicy.decide(previous: previous, next: next, framesBound: bound)
    }

    /// A reprepare ledger driven to `.silenced` by repeated format changes (budget 3, so the fourth silences).
    static func silencedReprepareLedger() -> ReprepareLedger {
        var ledger = ReprepareLedger(budget: .standard)
        for _ in 0..<4 { ledger = ledger.observing(.format).ledger }
        return ledger
    }

    static let vendorText = "acme.state.v1"

    static func vendor(_ text: String = vendorText) throws -> PluginVendorTag {
        try PluginVendorTag(text)
    }

    static func target(
        _ version: UInt32, vendor text: String = vendorText, owner: PluginIdentity? = nil
    ) throws -> PluginStateTarget {
        try PluginStateTarget(
            identity: owner ?? identity(), version: PluginVersion(rawValue: version), vendorTag: vendor(text)
        )
    }

    static func range(
        _ lower: UInt32, _ upper: UInt32, vendor text: String = vendorText, owner: PluginIdentity? = nil
    ) throws -> QualifiedVersionRange {
        try QualifiedVersionRange(
            identity: owner ?? identity(), vendorTag: vendor(text),
            lower: PluginVersion(rawValue: lower), upper: PluginVersion(rawValue: upper)
        )
    }

    static func evidence(_ ranges: [QualifiedVersionRange]) throws -> QualifiedVersionEvidence {
        try QualifiedVersionEvidence(ranges: ranges)
    }

    static func verdict(
        _ version: UInt32, _ evidence: QualifiedVersionEvidence, vendor text: String = vendorText,
        owner: PluginIdentity? = nil
    ) throws -> CompatibilityVerdict {
        try VersionCompatibilityMatrix.verdict(for: target(version, vendor: text, owner: owner), evidence: evidence)
    }
}
