import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Fingerprint goldens, replug continuity and ambiguity reports. Every golden was computed by hand from FNV-1a 64 as
/// draft-eastlake-fnv sections 2 and 5 define it (offset_basis 0xCBF29CE484222325, FNV_Prime 0x100000001B3), not by
/// the production code.
extension CoreMIDIAdapterTests {
    static func fingerprint(_ uniqueID: Int32?, _ manufacturer: String?, _ model: String?, _ owner: String?) -> UInt64 {
        CoreMIDIEndpointRecord(
            ref: 1, uniqueID: uniqueID, displayName: "Launch Control XL", manufacturer: manufacturer, model: model,
            driverOwner: owner, isOffline: nil, protocolID: nil
        ).fingerprint
    }

    /// Each ambiguous group's fingerprint and its refs, ignoring order. A fingerprint listed in two groups is a
    /// recorded failure, not a trap.
    static func groups(_ result: CoreMIDIEndpointReconciliation) -> [UInt64: Set<UInt32>] {
        let fingerprints = result.ambiguous.map(\.fingerprint)
        #expect(Set(fingerprints).count == fingerprints.count)
        return Dictionary(result.ambiguous.map { ($0.fingerprint, Set($0.refs)) }, uniquingKeysWith: { $0.union($1) })
    }

    @Test func fnv1aMatchesThePublishedVectors() {
        // draft-eastlake-fnv section 8.3: the 64-bit values for "", "a" and "foobar".
        #expect(CoreMIDIEndpointFingerprint.fnv1a([]) == 0xCBF2_9CE4_8422_2325)
        #expect(CoreMIDIEndpointFingerprint.fnv1a(Array("a".utf8)) == 0xAF63_DC4C_8601_EC8C)
        #expect(CoreMIDIEndpointFingerprint.fnv1a(Array("foobar".utf8)) == 0x8594_4171_F739_67E8)
    }

    @Test func theFingerprintMatchesItsGoldens() {
        // Four absent fields are four zero presence bytes.
        #expect(Self.fingerprint(nil, nil, nil, nil) == 0x4D25_767F_9DCE_13F5)
        // 61 bytes: 01 81 82 83 84, then for each string 01, its 8-byte count and its UTF-8 bytes.
        let full = Self.fingerprint(Int32(bitPattern: 0x8182_8384), "Acme", "Fader 8", "com.example.driver")
        #expect(full == 0x1C93_2881_32E6_58CF)
    }

    /// The protocol is evidence, not identity: the goldens above hold whatever `kMIDIPropertyProtocolID` reports.
    @Test func theEndpointProtocolNeverChangesTheFingerprint() {
        let full = Self.source(
            1, "Launch Control XL", uniqueID: Int32(bitPattern: 0x8182_8384), manufacturer: "Acme", model: "Fader 8",
            owner: "com.example.driver"
        )
        let absent = CoreMIDIEndpointRecord(
            ref: 2, uniqueID: nil, displayName: "Launch Control XL", manufacturer: nil, model: nil, driverOwner: nil,
            isOffline: nil, protocolID: nil
        )
        let protocolIDs: [Int32?] = [nil, 0, 1, 2, 3, -1, Int32.min, Int32.max]
        for protocolID in protocolIDs {
            #expect(Self.reporting(protocolID, full).fingerprint == 0x1C93_2881_32E6_58CF)
            #expect(Self.reporting(protocolID, absent).fingerprint == 0x4D25_767F_9DCE_13F5)
        }
        #expect(Self.reporting(1, full).endpointProtocol != Self.reporting(2, full).endpointProtocol)
    }

    @Test func theEncodingIsPresenceThenBigEndianThenLengthPrefixed() {
        let bytes = CoreMIDIEndpointFingerprint.encoding(
            uniqueID: 0x0102_0304, manufacturer: "", model: nil, driverOwner: "ab"
        )
        #expect(bytes == [1, 1, 2, 3, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0x61, 0x62])
        let absent = CoreMIDIEndpointFingerprint.encoding(
            uniqueID: nil, manufacturer: nil, model: nil, driverOwner: nil
        )
        #expect(absent == [0, 0, 0, 0])
    }

    @Test func aReplugKeepsTheFingerprintDespiteANewRefNameOrOfflineState() {
        let before = Self.source(4, "Launch Control XL", uniqueID: 77)
        let after = Self.source(912, "Launch Control XL (Studio)", uniqueID: 77, offline: true)
        #expect(after.fingerprint == before.fingerprint)
        #expect(Self.source(4, "LCXL", uniqueID: 77, offline: nil).fingerprint == before.fingerprint)
        let changed = [
            Self.source(4, "Launch Control XL", uniqueID: 78),
            Self.source(4, "Launch Control XL", uniqueID: 77, manufacturer: "Acme Ltd"),
            Self.source(4, "Launch Control XL", uniqueID: 77, model: "Surface 9"),
            Self.source(4, "Launch Control XL", uniqueID: 77, owner: "com.example.other")
        ]
        for record in changed {
            #expect(record.fingerprint != before.fingerprint)
        }
        let replug = Self.reconcile([after], connected: [4])
        #expect(replug.toDisconnect == [4])
        #expect(replug.matched.isEmpty && replug.toConnect.isEmpty)
        let online = Self.source(912, "Launch Control XL (Studio)", uniqueID: 77, offline: false)
        #expect(Self.reconcile([online]).toConnect.map(\.fingerprint) == [before.fingerprint])
    }

    @Test func anAbsentFieldDiffersFromAnEmptyOneAndNoValueShiftsIntoItsNeighbour() {
        #expect(Self.fingerprint(1, nil, "M", "O") != Self.fingerprint(1, "", "M", "O"))
        #expect(Self.fingerprint(1, "A", "M", nil) != Self.fingerprint(1, "A", "M", ""))
        #expect(Self.fingerprint(nil, "A", "M", "O") != Self.fingerprint(0, "A", "M", "O"))
        #expect(Self.fingerprint(1, "X", nil, "O") != Self.fingerprint(1, nil, "X", "O"))
        #expect(Self.fingerprint(1, "ab", "c", "O") != Self.fingerprint(1, "a", "bc", "O"))
    }

    @Test func identicalUnitsAreReportedAsOneAmbiguousGroupAndStillConnected() {
        let first = Self.source(11, "Launch Control XL", uniqueID: 500)
        let other = Self.source(13, "Launch Control XL", uniqueID: 501)
        let daw = Self.source(14, "Launch Control XL DAW", uniqueID: 500)
        let second = Self.source(12, "Launch Control XL 2", uniqueID: 500)
        let result = Self.reconcile([first, other, daw, second])
        #expect(result.ambiguous == [.init(fingerprint: first.fingerprint, refs: [11, 12])])
        #expect(result.toConnect.map(\.ref) == [11, 13, 12])
        #expect(result.identityUnavailable.isEmpty)
        #expect(Self.reconcile([first, other, daw, second], connected: [11]).ambiguous == result.ambiguous)

        let pairs = Self.reconcile([
            Self.source(31, "Launch Control XL", uniqueID: 9), Self.source(32, "Launch Control XL", uniqueID: 8),
            Self.source(33, "Launch Control XL", uniqueID: 8), Self.source(34, "Launch Control XL", uniqueID: 9)
        ])
        #expect(pairs.ambiguous.map(\.refs) == [[31, 34], [32, 33]])
        #expect(pairs.toConnect.map(\.ref) == [31, 32, 33, 34])
    }

    @Test func sourcesWithoutAUniqueIDAreIdentityUnavailableAndNeverGrouped() {
        let first = Self.anonymous(21, "Launch Control XL")
        let second = Self.anonymous(22, "Launch Control XL")
        let records = [first, second, Self.source(23, "Launch Control XL"), Self.anonymous(24, "IAC Bus 1")]
        #expect(first.fingerprint == second.fingerprint)
        let result = Self.reconcile(records)
        #expect(result.identityUnavailable == [21, 22])
        #expect(result.ambiguous.isEmpty)
        #expect(result.toConnect.map(\.ref) == [21, 22, 23])
    }

    @Test func offlineRecordsAreExcludedBeforeIdentityReporting() {
        let first = Self.source(11, "Launch Control XL", uniqueID: 500)
        let duplicate = Self.source(12, "Launch Control XL 2", uniqueID: 500, offline: true)
        let unavailable = Self.anonymous(21, "Launch Control XL", offline: true)
        let unknownAvailability = Self.anonymous(22, "Launch Control XL", offline: nil)
        #expect(unavailable.uniqueID == nil)
        #expect(first.fingerprint == duplicate.fingerprint)
        for records in [[first, duplicate, unavailable, unknownAvailability],
                        [unavailable, duplicate, first, unknownAvailability]] {
            let result = Self.reconcile(records, connected: [12, 21])
            #expect(result.matched.map(\.ref) == [11, 22])
            #expect(result.toConnect.map(\.ref) == [11, 22])
            #expect(result.toDisconnect == [12, 21])
            #expect(result.ambiguous.isEmpty)
            #expect(result.identityUnavailable == [22])
        }
    }

    @Test func duplicateAvailabilityRekeysSurvivorsWithFreshTokens() throws {
        let first = Self.source(11, "Launch Control XL", uniqueID: 500)
        let second = Self.source(12, "Launch Control XL 2", uniqueID: 500)
        let firstOffline = Self.source(11, "Launch Control XL", uniqueID: 500, offline: true)
        let secondOffline = Self.source(12, "Launch Control XL 2", uniqueID: 500, offline: true)
        let key = MIDIEndpointKey(fingerprint: first.fingerprint)
        let unique = Self.bind([first, secondOffline])
        #expect(unique.bindings.sources.map(\.endpoint) == [key])
        let original = try Self.token(of: 11, in: unique)

        let ambiguous = Self.bind([first, second], after: unique.bindings)
        #expect(ambiguous.detaches == unique.bindings.bindings)
        #expect(ambiguous.registrations.map(\.ref) == [11, 12])
        #expect(ambiguous.bindings.sources.map(\.endpoint) == [nil, nil])
        let firstShared = try Self.token(of: 11, in: ambiguous)
        let secondShared = try Self.token(of: 12, in: ambiguous)
        #expect(firstShared != original)
        #expect(secondShared != original && secondShared != firstShared)

        let survivor = Self.bind([firstOffline, second], after: ambiguous.bindings)
        #expect(survivor.detaches.map(\.source.token) == [firstShared, secondShared])
        #expect(survivor.registrations.map(\.ref) == [12])
        #expect(survivor.bindings.sources.map(\.endpoint) == [key])
        let secondResolved = try Self.token(of: 12, in: survivor)
        #expect(![original, firstShared, secondShared].contains(secondResolved))

        let returned = Self.bind([first, second], after: survivor.bindings)
        #expect(returned.detaches == survivor.bindings.bindings)
        #expect(returned.registrations.map(\.ref) == [11, 12])
        #expect(returned.bindings.sources.map(\.endpoint) == [nil, nil])
        let returnedTokens = returned.bindings.sources.map(\.token)
        #expect(Set(returnedTokens).count == 2)
        #expect(Set(returnedTokens).isDisjoint(with: [original, firstShared, secondShared, secondResolved]))
        let restored = Self.bind([first, secondOffline], after: returned.bindings)
        #expect(Set(restored.detaches.map(\.source.token)) == Set(returnedTokens))
        #expect(restored.registrations.map(\.ref) == [11])
        #expect(restored.bindings.sources.map(\.endpoint) == [key])
        let restoredToken = try Self.token(of: 11, in: restored)
        #expect(!([original, firstShared, secondShared, secondResolved] + returnedTokens).contains(restoredToken))
    }

    @Test func shufflingTheEnumerationChangesNoOutputSet() {
        let unitA = Self.source(1, "Launch Control XL", uniqueID: 500)
        let unitB = Self.source(3, "Launch Control XL", uniqueID: 600)
        let records = [
            unitA, Self.source(2, "Launch Control XL", uniqueID: 500),
            unitB, Self.anonymous(4, "Launch Control XL"),
            Self.source(5, "Launch Control XL DAW"), Self.source(6, "IAC Bus 1"),
            Self.source(7, "Launch Control XL", uniqueID: 600), Self.anonymous(8, "Launch Control XL"),
            Self.source(9, "Launch Control XL", uniqueID: 700)
        ]
        let connected: Set<UInt32> = [2, 5, 9, 10]
        let expected = Self.reconcile(records, connected: connected)
        #expect(Set(expected.toConnect.map(\.ref)) == [1, 3, 4, 7, 8])
        #expect(expected.toDisconnect == [5, 10])
        #expect(Self.groups(expected) == [unitA.fingerprint: [1, 2], unitB.fingerprint: [3, 7]])
        #expect(Set(expected.identityUnavailable) == [4, 8])

        let rotations = (1..<records.count).map { Array(records[$0...] + records[..<$0]) }
        let interleaved = records.indices.sorted { ($0 % 2, $0) < ($1 % 2, $1) }.map { records[$0] }
        for order in [Array(records.reversed()), interleaved] + rotations {
            let result = Self.reconcile(order, connected: connected)
            #expect(Set(result.matched.map(\.ref)) == Set(expected.matched.map(\.ref)))
            #expect(Set(result.toConnect.map(\.ref)) == Set(expected.toConnect.map(\.ref)))
            #expect(result.toDisconnect == expected.toDisconnect)
            #expect(Self.groups(result) == Self.groups(expected))
            #expect(Set(result.identityUnavailable) == Set(expected.identityUnavailable))
        }
    }
}
