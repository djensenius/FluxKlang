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
            driverOwner: owner, isOffline: offline
        )
    }

    /// A source whose uniqueID could not be read.
    static func anonymous(_ ref: UInt32, _ name: String, offline: Bool? = false) -> CoreMIDIEndpointRecord {
        CoreMIDIEndpointRecord(
            ref: ref, uniqueID: nil, displayName: name, manufacturer: "Acme", model: "Surface 8",
            driverOwner: "com.example.driver", isOffline: offline
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
}
