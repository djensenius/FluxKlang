import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerControlMessageTests.Fixture {
    // Session h/1, c/2; revisions 1 2 3 4 5.
    static let goldenSnapshot: [UInt8] = [
        0x01,
        0x01, 0x68, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x63, 0, 0, 0, 0, 0, 0, 0, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0x05,
        0, 0, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0, 0x05,
        0, 0, 0, 0x02,
        0x01, 0x61, 0xC0, 0x18, 0, 0, 0, 0, 0, 0, 0x01,
        0x01, 0x62, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0, 0x02
    ]

    // Sequence 6, revisions 1 2 3 4 6, one update (a: 1.0 percent), removals b and c.
    static let goldenDelta: [UInt8] = [
        0x02,
        0x01, 0x68, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x63, 0, 0, 0, 0, 0, 0, 0, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0x06,
        0, 0, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0, 0x06,
        0, 0, 0, 0x01, 0, 0, 0, 0x02,
        0x01, 0x61, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0, 0x03,
        0x01, 0x62, 0x01, 0x63
    ]

    // lastApplied 4, gap(expected 5, found 7).
    static let goldenResync: [UInt8] = [
        0x03,
        0x01, 0x68, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x63, 0, 0, 0, 0, 0, 0, 0, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0x04,
        0x01, 0, 0, 0, 0, 0, 0, 0, 0x05, 0, 0, 0, 0, 0, 0, 0, 0x07
    ]

    // Sequence 1, command cmd, live, controller, host h/1, connection c/2, set p = 0.25 normalized, "perm".
    static let goldenCommand: [UInt8] = [
        0x04,
        0, 0, 0, 0, 0, 0, 0, 0x01,
        0x03, 0x63, 0x6D, 0x64, 0x01, 0x02,
        0x01, 0x68, 0, 0, 0, 0, 0, 0, 0, 0x01,
        0x01, 0x01, 0x63, 0, 0, 0, 0, 0, 0, 0, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0, 0x05,
        0x01, 0x01, 0x70, 0x3F, 0xD0, 0, 0, 0, 0, 0, 0, 0x02,
        0x00, 0x04, 0x70, 0x65, 0x72, 0x6D
    ]

    // Sequence 1, command cmd, refused(command(rejected(staleRevision(expected 3, found 4)))).
    static let goldenResult: [UInt8] = [
        0x05,
        0, 0, 0, 0, 0, 0, 0, 0x01,
        0x03, 0x63, 0x6D, 0x64,
        0x04, 0x01, 0x02, 0x03, 0, 0, 0, 0, 0, 0, 0, 0x03, 0, 0, 0, 0, 0, 0, 0, 0x04
    ]

    static var goldenSnapshotMessage: PeerControlMessage {
        snapshot([pid("a"): value(-6, .decibels), pid("b"): value(0.5)])
    }

    static var goldenDeltaMessage: PeerControlMessage {
        let deltaRevisions = CommandRevisions(patch: rev(1), capability: rev(2), permission: rev(3),
                                              parameter: rev(4), graph: rev(6))
        return .delta(PeerSyncDelta(session: session(), sequence: seq(6), revisions: deltaRevisions,
                                    updates: [pid("a"): value(1, .percent)], removals: [pid("b"), pid("c")]))
    }

    static var goldenResyncMessage: PeerControlMessage { resync(.gap(expected: seq(5), found: seq(7))) }
    static var goldenCommandMessage: PeerControlMessage { command() }

    static var goldenResultMessage: PeerControlMessage {
        result(.refused(.command(.rejected(.staleRevision(expected: rev(3), found: rev(4))))))
    }

    /// Every golden message with its bytes.
    static var goldens: [(message: PeerControlMessage, bytes: [UInt8])] {
        [(goldenSnapshotMessage, goldenSnapshot), (goldenDeltaMessage, goldenDelta),
         (goldenResyncMessage, goldenResync), (goldenCommandMessage, goldenCommand),
         (goldenResultMessage, goldenResult)]
    }
}

// swiftlint:disable type_name
extension PeerControlMessageTests {
    @Test func snapshotEncodesToTheGoldenBytesAndDecodesBack() {
        typealias F = Fixture
        #expect(F.encode(F.goldenSnapshotMessage) == .success(F.goldenSnapshot))
        #expect(F.decode(F.goldenSnapshot) == .success(F.goldenSnapshotMessage))
    }

    @Test func deltaEncodesToTheGoldenBytesAndDecodesBack() {
        typealias F = Fixture
        #expect(F.encode(F.goldenDeltaMessage) == .success(F.goldenDelta))
        #expect(F.decode(F.goldenDelta) == .success(F.goldenDeltaMessage))
    }

    @Test func resyncEncodesToTheGoldenBytesAndDecodesBack() {
        typealias F = Fixture
        #expect(F.encode(F.goldenResyncMessage) == .success(F.goldenResync))
        #expect(F.decode(F.goldenResync) == .success(F.goldenResyncMessage))
    }

    @Test func commandEncodesToTheGoldenBytesAndDecodesBack() {
        typealias F = Fixture
        #expect(F.encode(F.goldenCommandMessage) == .success(F.goldenCommand))
        #expect(F.decode(F.goldenCommand) == .success(F.goldenCommandMessage))
    }

    @Test func resultEncodesToTheGoldenBytesAndDecodesBack() {
        typealias F = Fixture
        #expect(F.encode(F.goldenResultMessage) == .success(F.goldenResult))
        #expect(F.decode(F.goldenResult) == .success(F.goldenResultMessage))
    }

    @Test func snapshotEntriesEncodeInByteOrderWhateverTheInsertionOrder() {
        typealias F = Fixture
        let ids = ["a_b", "B", "a.b", "a", "a-b"]
        let expected = [1] + F.sessionBytes + F.u64(5) + F.revisionBytes + F.u32(5)
            + ["B", "a", "a-b", "a.b", "a_b"].flatMap { F.entry($0) }
        for order in [ids, ids.reversed(), [ids[3], ids[1], ids[4], ids[0], ids[2]]] {
            var values: [ParameterID: ParameterValue] = [:]
            for raw in order { values[F.pid(raw)] = F.value(0.5) }
            #expect(F.encode(F.snapshot(values)) == .success(expected))
        }
    }

    @Test func deltaEntriesAndRemovalsEncodeInByteOrderWhateverTheInsertionOrder() {
        typealias F = Fixture
        let expected = F.deltaHead(updates: 3, removals: 3) + ["B", "a", "a.b"].flatMap { F.entry($0) }
            + ["Z", "m", "m-1"].flatMap { F.idBytes($0) }
        let updateOrders = [["a.b", "B", "a"], ["a", "a.b", "B"]]
        let removalOrders = [["m-1", "Z", "m"], ["Z", "m", "m-1"]]
        for (updateOrder, removalOrder) in zip(updateOrders, removalOrders) {
            var updates: [ParameterID: ParameterValue] = [:]
            for raw in updateOrder { updates[F.pid(raw)] = F.value(0.5) }
            let message = F.delta(updates: updates, removals: Set(removalOrder.map(F.pid)))
            #expect(F.encode(message) == .success(expected))
        }
    }

    @Test func snapshotValueLimitIsNOnEncodeAndNPlusOneIsRefused() {
        typealias F = Fixture
        func message(_ count: Int) -> PeerControlMessage {
            F.snapshot(Dictionary(uniqueKeysWithValues: (0..<count).map { (F.pid("p\($0)"), F.value(0.5)) }))
        }
        let accepted = F.encode(message(4_096))
        #expect((try? accepted.get().count) == 73 + entryBytes(count: 4_096))
        #expect(F.encode(message(4_097)) == .failure(.tooManyEntries(4_097)))
        #expect(F.encode(message(0)) == .success(F.snapshotHead(count: 0)))
    }

    @Test func deltaChangeLimitIsNOnEncodeAndNPlusOneIsRefused() {
        typealias F = Fixture
        func message(updates: Int, removals: Int) -> PeerControlMessage {
            F.delta(updates: Dictionary(uniqueKeysWithValues: (0..<updates).map { (F.pid("u\($0)"), F.value(0.5)) }),
                    removals: Set((0..<removals).map { F.pid("r\($0)") }))
        }
        #expect((try? F.encode(message(updates: 256, removals: 0)).get().isEmpty) == false)
        #expect((try? F.encode(message(updates: 0, removals: 256)).get().isEmpty) == false)
        #expect((try? F.encode(message(updates: 200, removals: 56)).get().isEmpty) == false)
        #expect(F.encode(message(updates: 257, removals: 0)) == .failure(.tooManyEntries(257)))
        #expect(F.encode(message(updates: 0, removals: 257)) == .failure(.tooManyEntries(257)))
        #expect(F.encode(message(updates: 200, removals: 57)) == .failure(.tooManyEntries(257)))
        #expect(F.encode(message(updates: 0, removals: 0)) == .success(F.deltaHead(updates: 0, removals: 0)))
    }

    @Test func snapshotValueLimitIsNOnDecodeAndNPlusOneIsRefused() {
        typealias F = Fixture
        func payload(_ count: Int) -> [UInt8] {
            F.snapshotHead(count: UInt64(count)) + (0..<count).flatMap { F.entry(String(format: "p%05d", $0)) }
        }
        #expect((try? F.decode(payload(4_096)).get().tag) == .snapshot)
        #expect(F.decode(payload(4_097)) == .failure(.tooManyEntries(4_097)))
        #expect(F.decode(F.snapshotHead(count: 0)) == .success(F.snapshot([:])))
    }

    @Test func deltaChangeLimitIsNOnDecodeAndNPlusOneIsRefused() {
        typealias F = Fixture
        func payload(updates: Int, removals: Int) -> [UInt8] {
            F.deltaHead(updates: UInt64(updates), removals: UInt64(removals))
                + (0..<updates).flatMap { F.entry(String(format: "u%04d", $0)) }
                + (0..<removals).flatMap { F.idBytes(String(format: "r%04d", $0)) }
        }
        #expect((try? F.decode(payload(updates: 256, removals: 0)).get().tag) == .delta)
        #expect((try? F.decode(payload(updates: 0, removals: 256)).get().tag) == .delta)
        #expect((try? F.decode(payload(updates: 100, removals: 156)).get().tag) == .delta)
        #expect(F.decode(payload(updates: 257, removals: 0)) == .failure(.tooManyEntries(257)))
        #expect(F.decode(payload(updates: 0, removals: 257)) == .failure(.tooManyEntries(257)))
        #expect(F.decode(payload(updates: 100, removals: 157)) == .failure(.tooManyEntries(257)))
        #expect(F.decode(F.deltaHead(updates: 0, removals: 0)) == .success(F.delta()))
    }

    @Test func callerLimitsAreHonouredNotTheStandardOnes() {
        typealias F = Fixture
        let small = F.syncLimits(snapshot: 2, delta: 1)
        let three = F.snapshot([F.pid("a"): F.value(1), F.pid("b"): F.value(1), F.pid("c"): F.value(1)])
        let two = F.snapshot([F.pid("a"): F.value(1), F.pid("b"): F.value(1)])
        #expect(F.encode(three, limits: small) == .failure(.tooManyEntries(3)))
        #expect((try? F.encode(two, limits: small).get().isEmpty) == false)
        let twoBytes = F.bytes(two)
        #expect(F.decode(F.bytes(three), limits: small) == .failure(.tooManyEntries(3)))
        #expect(F.decode(twoBytes, limits: small) == .success(two))
        let pair = F.delta(updates: [F.pid("a"): F.value(1)], removals: [F.pid("b")])
        #expect(F.encode(pair, limits: small) == .failure(.tooManyEntries(2)))
        #expect(F.decode(F.bytes(pair), limits: small) == .failure(.tooManyEntries(2)))
        let large = F.syncLimits(snapshot: 65_536, delta: 4_096)
        let many = F.snapshot(Dictionary(uniqueKeysWithValues: (0..<5_000).map { (F.pid("p\($0)"), F.value(0.5)) }))
        #expect((try? F.encode(many, limits: large).get().isEmpty) == false)
        #expect(F.decode(F.bytes(many, limits: large), limits: large) == .success(many))
    }

    @Test func payloadAtTheFrameLimitIsAcceptedAndOneByteMoreIsRefused() {
        typealias F = Fixture
        let ids = (0..<80).map { String(format: "p.%02d", $0) }
        let message = F.snapshot(Dictionary(uniqueKeysWithValues: ids.map { (F.pid($0), F.value(0.5)) }))
        let size = 73 + 80 * (1 + 4 + 9)
        #expect(size == 1_193)
        #expect((try? F.encode(message, frame: F.frameLimits(size)).get().count) == size)
        #expect(F.encode(message, frame: F.frameLimits(size - 1)) == .failure(.payloadTooLarge(size)))
        let bytes = F.bytes(message)
        #expect((try? F.decode(bytes, frame: F.frameLimits(size)).get().tag) == .snapshot)
        #expect(F.decode(bytes, frame: F.frameLimits(size - 1)) == .failure(.payloadTooLarge(size)))
    }

    @Test func frameLimitsParameterIsUsedNotTheStandardFrame() {
        typealias F = Fixture
        let ids = (0..<1_400).map { String(format: "p%04d", $0) }
        let message = F.snapshot(Dictionary(uniqueKeysWithValues: ids.map { (F.pid($0), F.value(0.5)) }))
        let bytes = F.bytes(message)
        #expect(bytes.count > PeerFrameLimits.standard.maximumPayloadBytes)
        #expect(F.encode(message, frame: .standard) == .failure(.payloadTooLarge(bytes.count)))
        #expect(F.decode(bytes, frame: .standard) == .failure(.payloadTooLarge(bytes.count)))
        #expect(F.decode(bytes) == .success(message))
    }

    private func entryBytes(count: Int) -> Int {
        (0..<count).reduce(0) { $0 + 1 + "p\($1)".utf8.count + 9 }
    }
}
// swiftlint:enable type_name
