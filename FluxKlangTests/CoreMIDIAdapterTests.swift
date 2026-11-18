import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The CoreMIDI endpoint directory, fingerprint and reconciler (#81, slice D1). Records come from a fake directory and
/// nothing here calls CoreMIDI. Fingerprint and ambiguity tests are in `+Identity`.
@Suite("CoreMIDI adapter", .productionAccessAudit)
struct CoreMIDIAdapterTests {
    /// Stands in for `LiveCoreMIDIEndpointDirectory`: lists the given records, in order.
    struct FakeDirectory: CoreMIDIEndpointDirectory {
        let records: [CoreMIDIEndpointRecord]

        func sources() -> [CoreMIDIEndpointRecord] { records }
    }

    static let surface = ["Launch Control XL"]

    /// A source with full identity evidence. Without an explicit `uniqueID` it uses `ref`, so units differ.
    static func source(
        _ ref: UInt32, _ name: String, uniqueID: Int32? = nil, manufacturer: String? = "Acme",
        model: String? = "Surface 8", owner: String? = "com.example.driver", offline: Bool? = false
    ) -> CoreMIDIEndpointRecord {
        CoreMIDIEndpointRecord(
            ref: ref, uniqueID: uniqueID ?? Int32(ref), displayName: name, manufacturer: manufacturer, model: model,
            driverOwner: owner, isOffline: offline, protocolID: nil
        )
    }

    /// A source whose uniqueID could not be read.
    static func anonymous(_ ref: UInt32, _ name: String, offline: Bool? = false) -> CoreMIDIEndpointRecord {
        CoreMIDIEndpointRecord(
            ref: ref, uniqueID: nil, displayName: name, manufacturer: "Acme", model: "Surface 8",
            driverOwner: "com.example.driver", isOffline: offline, protocolID: nil
        )
    }

    /// `record` as an enumeration that read `protocolID` from it would list it.
    static func reporting(_ protocolID: Int32?, _ record: CoreMIDIEndpointRecord) -> CoreMIDIEndpointRecord {
        CoreMIDIEndpointRecord(
            ref: record.ref, uniqueID: record.uniqueID, displayName: record.displayName,
            manufacturer: record.manufacturer, model: record.model, driverOwner: record.driverOwner,
            isOffline: record.isOffline, protocolID: protocolID
        )
    }

    static func reconcile(
        _ records: [CoreMIDIEndpointRecord], names: [String] = surface, connected: Set<UInt32> = []
    ) -> CoreMIDIEndpointReconciliation {
        CoreMIDIEndpointReconciler(sourceNameContains: names)
            .reconcile(FakeDirectory(records: records).sources(), connected: connected)
    }

    @Test func matchingNamesConnectIgnoringCaseInEnumerationOrder() {
        let records = [
            Self.source(30, "Launch Control XL"), Self.source(10, "IAC Bus 1"), Self.source(20, "launch control xl 2"),
            Self.source(40, "Port 2 (LAUNCH CONTROL XL)")
        ]
        let result = Self.reconcile(records)
        #expect(result.matched.map(\.ref) == [30, 20, 40])
        #expect(result.toConnect.map(\.ref) == [30, 20, 40])
        #expect(result.toConnect.map(\.displayName) == ["Launch Control XL", "launch control xl 2",
                                                        "Port 2 (LAUNCH CONTROL XL)"])
        #expect(result.toDisconnect.isEmpty)
        let either = Self.reconcile(records, names: ["IAC", "xl 2"])
        #expect(either.toConnect.map(\.ref) == [10, 20])
    }

    @Test func dawAndHUIPortsAreExcludedEvenWhenTheirNamesMatch() {
        let records = [
            Self.source(1, "Launch Control XL DAW"), Self.source(2, "Launch Control XL HUI"),
            Self.source(3, "launch control xl daw in"), Self.source(4, "Launch Control XL hui out"),
            Self.source(5, "Launch Control XL")
        ]
        let result = Self.reconcile(records, connected: [1, 2])
        #expect(result.matched.map(\.ref) == [5])
        #expect(result.toConnect.map(\.ref) == [5])
        #expect(result.toDisconnect == [1, 2])
        let reconciler = CoreMIDIEndpointReconciler(sourceNameContains: ["DAW", "HUI", "Launch"])
        for name in ["DAW", "hui", "Launch DaW", "Launch Hui", "Launch Control XL DAW"] {
            #expect(!reconciler.matches(name), "\(name) must never match")
        }
        #expect(reconciler.matches("Launch Control XL"))
    }

    @Test func namesThatDoNotMatchAreIgnored() {
        let records = [
            Self.source(1, "IAC Bus 1"), Self.source(2, "Launch Control"), Self.source(3, "Unknown MIDI source")
        ]
        let result = Self.reconcile(records)
        #expect(result.matched.isEmpty)
        #expect(result.toConnect.isEmpty)
        #expect(result.ambiguous.isEmpty && result.identityUnavailable.isEmpty)
        #expect(Self.reconcile([Self.source(4, "Launch Control XL")], names: []).toConnect.isEmpty)
    }

    @Test func aSourceThatDisappearsOrStopsMatchingIsDisconnected() {
        let gone = Self.reconcile([Self.source(7, "Launch Control XL")], connected: [5, 7, 9])
        #expect(gone.toDisconnect == [5, 9])
        #expect(gone.toConnect.isEmpty)
        let renamed = Self.reconcile(
            [Self.source(7, "Launch Control XL DAW"), Self.source(8, "IAC")], connected: [7, 8]
        )
        #expect(renamed.toDisconnect == [7, 8])
        #expect(Self.reconcile([], connected: [3]).toDisconnect == [3])
    }

    @Test func anAlreadyConnectedSourceIsNotConnectedAgain() {
        let records = [Self.source(1, "Launch Control XL"), Self.source(2, "Launch Control XL"),
                       Self.source(3, "Launch Control XL")]
        let result = Self.reconcile(records, connected: [2])
        #expect(result.toConnect.map(\.ref) == [1, 3])
        #expect(result.matched.map(\.ref) == [1, 2, 3])
        #expect(result.toDisconnect.isEmpty)
        #expect(Self.reconcile(records, connected: [1, 2, 3]).toConnect.isEmpty)
    }

    @Test func onlyExplicitlyOfflineSourcesLoseNameEligibility() {
        let records = [
            Self.source(30, "Launch Control XL", offline: nil),
            Self.source(10, "Launch Control XL", offline: true),
            Self.source(20, "launch control xl 2", offline: false),
            Self.source(40, "Launch Control XL DAW", offline: nil),
            Self.source(50, "Launch Control XL HUI", offline: false),
            Self.source(60, "IAC Bus 1", offline: nil),
            Self.source(70, "IAC Bus 2", offline: true)
        ]
        let result = Self.reconcile(records, connected: [10, 40, 50, 70])
        #expect(result.matched.map(\.ref) == [30, 20])
        #expect(result.toConnect.map(\.ref) == [30, 20])
        #expect(result.toDisconnect == [10, 40, 50, 70])
        #expect(result.ambiguous.isEmpty && result.identityUnavailable.isEmpty)
        let either = Self.reconcile(records, names: ["IAC", "xl 2"], connected: [10, 20, 70])
        #expect(either.matched.map(\.ref) == [20, 60])
        #expect(either.toConnect.map(\.ref) == [60])
        #expect(either.toDisconnect == [10, 70])
        #expect(Self.reconcile(records, names: []).matched.isEmpty)
    }

    @Test func theOrderIsStableAndDoesNotFollowTheRef() {
        let records = [Self.source(9, "Launch Control XL"), Self.source(3, "Launch Control XL"),
                       Self.source(7, "Launch Control XL")]
        let connected: Set<UInt32> = [50, 2, 40, 3]
        let first = Self.reconcile(records, connected: connected)
        #expect(first.toConnect.map(\.ref) == [9, 7])
        #expect(first.matched.map(\.ref) == [9, 3, 7])
        #expect(first.toDisconnect == [2, 40, 50])
        for _ in 0..<5 {
            #expect(Self.reconcile(records, connected: connected) == first)
        }
    }

    // MARK: Endpoint protocol evidence (M81-EP1)

    @Test func onlyProtocolIDsOneAndTwoMapToAKnownEndpointProtocol() {
        let table: [(protocolID: Int32?, expected: MIDIEndpointProtocol)] = [
            (nil, .unknown), (0, .unknown), (1, .midi1), (2, .midi2), (3, .unknown), (4, .unknown), (-1, .unknown),
            (-2, .unknown), (257, .unknown), (Int32.min, .unknown), (Int32.max, .unknown)
        ]
        for (protocolID, expected) in table {
            let record = Self.reporting(protocolID, Self.source(1, "Launch Control XL"))
            #expect(MIDIEndpointProtocol(protocolID: protocolID) == expected, "\(String(describing: protocolID))")
            #expect(record.endpointProtocol == expected, "\(String(describing: protocolID))")
            #expect(record.protocolID == protocolID)
        }
    }

    @Test func theEndpointProtocolNeverChangesEligibility() {
        let records = [
            Self.source(30, "Launch Control XL"), Self.source(10, "IAC Bus 1"),
            Self.source(20, "Launch Control XL DAW"), Self.source(40, "Launch Control XL", offline: true),
            Self.source(50, "Launch Control XL", uniqueID: 9), Self.source(60, "Launch Control XL 2", uniqueID: 9),
            Self.anonymous(70, "Launch Control XL", offline: nil)
        ]
        let connected: Set<UInt32> = [10, 30, 40, 80]
        let expected = Self.reconcile(records, connected: connected)
        #expect(expected.matched.map(\.ref) == [30, 50, 60, 70])
        #expect(expected.toDisconnect == [10, 40, 80])
        #expect(expected.ambiguous.map(\.refs) == [[50, 60]] && expected.identityUnavailable == [70])
        let protocolIDs: [Int32?] = [nil, 0, 1, 2, 3, -1, Int32.min, Int32.max]
        let uniform = protocolIDs.map { protocolID in records.map { Self.reporting(protocolID, $0) } }
        let mixed = protocolIDs.indices.map { offset in
            zip(protocolIDs[offset...] + protocolIDs[..<offset], records).map { Self.reporting($0, $1) }
        }
        for reported in uniform + mixed {
            let result = Self.reconcile(reported, connected: connected)
            #expect(result.matched == reported.filter { expected.matched.map(\.ref).contains($0.ref) })
            #expect(result.toConnect.map(\.ref) == expected.toConnect.map(\.ref))
            #expect(result.toDisconnect == expected.toDisconnect)
            #expect(result.ambiguous == expected.ambiguous)
            #expect(result.identityUnavailable == expected.identityUnavailable)
        }
    }

    @Test func aKeptBindingReportsItsProtocolChangeAndKeepsItsToken() throws {
        let unit = Self.source(10, "Launch Control XL")
        let key = MIDIEndpointKey(fingerprint: unit.fingerprint)
        let first = Self.bind([Self.reporting(1, unit)])
        let token = try Self.token(of: 10, in: first)
        #expect(first.registrations.map(\.endpointProtocol) == [.midi1])
        #expect(first.protocolChanges.isEmpty, "a registration is never a protocol change")

        let renamed = Self.reporting(2, Self.source(10, "Launch Control XL (Studio)"))
        let second = Self.bind([renamed], after: first.bindings)
        #expect(second.detaches.isEmpty && second.registrations.isEmpty)
        #expect(second.protocolChanges == [.init(ref: 10, token: token, from: .midi1, to: .midi2)])
        #expect(second.bindings.bindings == [.init(
            ref: 10, source: MIDIConnectedSource(token: token, endpoint: key, name: renamed.displayName),
            endpointProtocol: .midi2
        )])

        let same = Self.bind([renamed], after: second.bindings)
        #expect(same.protocolChanges.isEmpty)
        let lost = Self.bind([Self.reporting(nil, unit)], after: same.bindings)
        #expect(lost.protocolChanges == [.init(ref: 10, token: token, from: .midi2, to: .unknown)])
        #expect(lost.detaches.isEmpty && lost.registrations.isEmpty)
        let lostToken = try Self.token(of: 10, in: lost)
        #expect(lostToken == token)
    }

    @Test func rawValuesThatMapAlikeAreNoProtocolChange() throws {
        let unit = Self.source(10, "Launch Control XL")
        var bindings = Self.bind([Self.reporting(0, unit)]).bindings
        let token = try #require(bindings.sources.first).token
        for protocolID: Int32? in [nil, 3, -1, Int32.min, Int32.max, 0] {
            let update = Self.bind([Self.reporting(protocolID, unit)], after: bindings)
            #expect(update.protocolChanges.isEmpty, "\(String(describing: protocolID))")
            #expect(update.bindings.bindings.map(\.endpointProtocol) == [.unknown])
            #expect(update.detaches.isEmpty && update.registrations.isEmpty)
            bindings = update.bindings
        }
        #expect(bindings.sources.map(\.token) == [token])
    }

    @Test func registrationsAndRekeysNeverReportProtocolChanges() throws {
        let first = Self.source(11, "Launch Control XL", uniqueID: 500)
        let second = Self.source(12, "Launch Control XL 2", uniqueID: 500)
        let unique = Self.bind([Self.reporting(1, first)])
        let original = try Self.token(of: 11, in: unique)

        let rekeyed = Self.bind([Self.reporting(2, first), Self.reporting(2, second)], after: unique.bindings)
        #expect(rekeyed.protocolChanges.isEmpty)
        #expect(rekeyed.detaches == unique.bindings.bindings)
        #expect(rekeyed.registrations.map(\.ref) == [11, 12])
        #expect(rekeyed.registrations.map(\.endpointProtocol) == [.midi2, .midi2])
        let rekeyedToken = try Self.token(of: 11, in: rekeyed)
        #expect(rekeyedToken != original)

        let offline = Self.source(11, "Launch Control XL", uniqueID: 500, offline: true)
        let retired = Self.bind([Self.reporting(2, offline)], after: unique.bindings)
        #expect(retired.detaches == unique.bindings.bindings && retired.protocolChanges.isEmpty)
        let returned = Self.bind([Self.reporting(2, first)], after: retired.bindings)
        #expect(returned.protocolChanges.isEmpty)
        #expect(returned.registrations.map(\.endpointProtocol) == [.midi2])
    }

    @Test func protocolChangesFollowTheEnumerationOrder() throws {
        let unit30 = Self.source(30, "Launch Control XL")
        let unit10 = Self.source(10, "Launch Control XL")
        let unit20 = Self.source(20, "Launch Control XL")
        let unit40 = Self.source(40, "Launch Control XL")
        let before = Self.bind([
            Self.reporting(1, unit30), Self.reporting(1, unit10), Self.reporting(2, unit20), Self.reporting(0, unit40)
        ])
        let after = [
            Self.reporting(1, unit20), Self.reporting(2, unit40), Self.reporting(2, unit30), Self.reporting(1, unit10),
            Self.reporting(2, Self.source(50, "Launch Control XL"))
        ]
        let update = Self.bind(after, after: before.bindings)
        let token20 = try Self.token(of: 20, in: before)
        let token40 = try Self.token(of: 40, in: before)
        let token30 = try Self.token(of: 30, in: before)
        #expect(update.protocolChanges == [
            .init(ref: 20, token: token20, from: .midi2, to: .midi1),
            .init(ref: 40, token: token40, from: .unknown, to: .midi2),
            .init(ref: 30, token: token30, from: .midi1, to: .midi2)
        ])
        #expect(update.registrations.map(\.ref) == [50])
        #expect(update.bindings.bindings.map(\.endpointProtocol) == [.midi1, .midi2, .midi2, .midi1, .midi2])
    }
}
