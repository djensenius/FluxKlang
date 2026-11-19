import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension UMPTranslationStreamTests {
    static let sysExLengths = [0, 1, 6, 7, 12, 13, 4_096]

    static func sysExPayload(_ length: Int) -> [UInt8] {
        (0..<length).map { UInt8($0 % 128) }
    }

    /// Independent wire goldens for the boundary payloads; never calls the packetizer or its encoder.
    static func sysExWords(_ length: Int, group: UInt8) -> [[UInt32]] {
        let words: [[UInt32]]
        switch length {
        case 0: words = [[0x3000_0000, 0]]
        case 1: words = [[0x3001_0000, 0]]
        case 6: words = [[0x3006_0001, 0x0203_0405]]
        case 7: words = [[0x3016_0001, 0x0203_0405], [0x3031_0600, 0]]
        case 12: words = [[0x3016_0001, 0x0203_0405], [0x3036_0607, 0x0809_0A0B]]
        case 13:
            words = [[0x3016_0001, 0x0203_0405], [0x3026_0607, 0x0809_0A0B], [0x3031_0C00, 0]]
        case 4_096:
            // 682 full packets, then four bytes. Serialize independently as network-order octets.
            words = (0..<683).map { index in
                let header: UInt8 = index == 0 ? 0x16 : (index == 682 ? 0x34 : 0x26)
                let data = (0..<6).map { slot -> UInt8 in
                    let offset = index * 6 + slot
                    return offset < 4_096 ? UInt8(offset % 128) : 0
                }
                let octets: [UInt8] = [0x30, header] + data
                return [octets.prefix(4), octets.suffix(4)].map {
                    $0.reduce(UInt32(0)) { $0 * 256 + UInt32($1) }
                }
            }
        default:
            Issue.record("missing independent SysEx golden for \(length)")
            return []
        }
        return words.map { [$0[0] | UInt32(group) << 24, $0[1]] }
    }

    static func checkSysExItems(_ items: [UMPTranslationStreamItem], length: Int, group: UInt8) throws {
        let expected = sysExWords(length, group: group)
        #expect(items.count == expected.count)
        var payload: [UInt8] = []
        for (item, words) in zip(items, expected) {
            guard case let .sysEx7(packet) = item else {
                Issue.record("expected a SysEx7 packet")
                continue
            }
            #expect(packet.packet.words == words)
            #expect(packet.group == (try UMPGroup(group)))
            #expect(packet.status.rawValue == UInt8((words[0] >> 20) & 15))
            #expect(packet.bytes.count == Int((words[0] >> 16) & 15))
            payload += packet.bytes
        }
        #expect(payload == sysExPayload(length))
    }

    /// Existing driver API: before #852 this valid complete payload was intentionally refused.
    @Test func sysExDriverAcceptsACompleteEvent() async throws {
        let fixture = Fixture()
        try await fixture.driver.receive(.sysEx(payload: [0x7E]), group: UMPGroup(5), stream: Self.two,
                                         atNanoseconds: 1)
        #expect(fixture.sink.received.count == 1)
        #expect(fixture.sink.streams == [Self.two])
        #expect(fixture.timer.armCount == 0)
    }

    @Test(arguments: sysExLengths)
    func sysExDriverBoundariesAreOneOrderedBatch(length: Int) async throws {
        for group: UInt8 in [0, 5, 15] {
            let fixture = Fixture()
            try await Self.hold(fixture, Self.two, at: 0)
            try await fixture.driver.receive(.sysEx(payload: Self.sysExPayload(length)), group: UMPGroup(group),
                                             stream: Self.two, atNanoseconds: 1)
            #expect(fixture.sink.streams == [Self.two])
            #expect(fixture.sink.received.count == 1)
            let batch = try #require(fixture.sink.received.first)
            #expect(batch.first == .voice(try Self.mpe(15)))
            try Self.checkSysExItems(Array(batch.dropFirst()), length: length, group: group)
            if length == 4_096 { #expect(batch.count == 684) }
            #expect(fixture.timer.armCount == 1)
            #expect(fixture.timer.cancelCount == 1)
            #expect(fixture.timer.armedAt == nil)
            #expect(await fixture.driver.stream(Self.two)?.idleFlushes == 0)
            await fixture.fire(at: 10 * Self.msec)
            #expect(fixture.sink.received == [batch])
        }
    }

    /// New stream API coverage, not an assertion that this overload existed before #852.
    @Test(arguments: sysExLengths)
    func sysExStreamBoundariesPreserveUnheldState(length: Int) throws {
        var stream = UMPTranslationStream()
        let translator = stream.translator
        let items = try stream.receive(sysEx: Self.sysExPayload(length), group: UMPGroup(9), at: UInt64.max)
        try Self.checkSysExItems(items, length: length, group: 9)
        #expect(stream.translator == translator)
        #expect(stream.lastAcceptedTime == UInt64.max)
        #expect(stream.deadline == nil)
        #expect(stream.idleFlushes + stream.endOfStreamFlushes + stream.resetFlushes == 0)
        #expect(stream.losses.total == 0)
        #expect(try stream.poll(at: UInt64.max).isEmpty)
    }

    @Test(arguments: [-1, 0, 1])
    func sysExHeldDeadlineAndRetainedState(offset: Int) async throws {
        let fixture = Fixture()
        let group = try UMPGroup(0)
        for (controller, value) in [(UInt8(0), UInt8(2)), (32, 3)] {
            try await fixture.driver.receive(Self.control(0, controller, value), group: group, stream: Self.one,
                                             atNanoseconds: 0)
        }
        try await Self.hold(fixture, Self.one, at: 0)
        let before = try #require(await fixture.driver.stream(Self.one))
        let state = before.translator.state(group: group, channel: try UMPChannel(0))
        #expect(state.bankMSB?.value == 2 && state.bankLSB?.value == 3)
        #expect(state.parameter != nil && state.dataEntryMSB?.value == 15)
        let time = UInt64(Int(5 * Self.msec) + offset)
        try await fixture.driver.receive(.sysEx(payload: Self.sysExPayload(13)), group: UMPGroup(9),
                                         stream: Self.one, atNanoseconds: time)
        let batch = try #require(fixture.sink.received.last)
        #expect(batch.first == .voice(try Self.mpe(15)))
        try Self.checkSysExItems(Array(batch.dropFirst()), length: 13, group: 9)
        #expect(fixture.sink.received.count == 1)
        let after = try #require(await fixture.driver.stream(Self.one))
        #expect(after.translator.state(group: group, channel: try UMPChannel(0)) == state)
        #expect(after.translator.heldDataEntry == nil && after.deadline == nil)
        #expect(after.lastAcceptedTime == time)
        #expect(after.idleFlushes == (offset < 0 ? 0 : 1))
        #expect(after.resetFlushes == 0 && after.endOfStreamFlushes == 0 && after.losses.total == 0)
        #expect(fixture.timer.armCount == 1 && fixture.timer.cancelCount == 1)
        await fixture.fire(at: 10 * Self.msec)
        #expect(fixture.sink.received == [batch])
        try await fixture.driver.receive(Self.control(0, 38, 3), group: group, stream: Self.one,
                                         atNanoseconds: time + 1)
        #expect(fixture.sink.received == [batch, try Self.batch(15, lsb: 3)])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == after.idleFlushes)
    }
}

extension UMPTranslationStreamTests {
    struct SysExRefusalExample {
        let payload: [UInt8]
        let time: UInt64
        let error: UMPTranslationStreamRefusal

        init(_ payload: [UInt8], _ time: UInt64, _ error: UMPTranslationStreamRefusal) {
            self.payload = payload
            self.time = time
            self.error = error
        }
    }

    /// Each example has a precise first refusal, including defects after an otherwise complete first packet.
    static func sysExRefusalExample(_ index: Int) -> SysExRefusalExample {
        let oversized = UMPTranslationStreamRefusal.sysExPayloadTooLarge(count: 4_097, limit: 4_096)
        let backward = UMPTranslationStreamRefusal.timeWentBackward(previous: 10 * msec, got: 9 * msec)
        switch index {
        case 0: return .init(Array(repeating: 0, count: 4_097), 20 * msec, oversized)
        case 1: return .init(Array(repeating: 0xFF, count: 4_097), 9 * msec, oversized)
        case 2: return .init([0x80], 20 * msec, .translation(.valueOutOfRange(field: .sevenBit, value: 0x80)))
        case 3: return .init([0xF7, 0x80], 9 * msec, .translation(.valueOutOfRange(field: .sevenBit, value: 0xF7)))
        case 4:
            return .init(Array(repeating: 0, count: 4_095) + [0xFF], 20 * msec,
                    .translation(.valueOutOfRange(field: .sevenBit, value: 0xFF)))
        case 5: return .init(sysExPayload(13), 9 * msec, backward)
        default:
            return .init(Array(repeating: 0x80, count: 4_097), 20 * msec, oversized)
        }
    }

    @Test(arguments: Array(0...6))
    func sysExRefusalsAreAtomicForStreamAndDriver(index: Int) async throws {
        let example = Self.sysExRefusalExample(index)
        let group = try UMPGroup(0)
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        let before = try #require(await fixture.driver.stream(Self.one))
        var stream = before
        #expect(throws: example.error) {
            try stream.receive(sysEx: example.payload, group: group, at: example.time)
        }
        #expect(stream == before)
        let batches = fixture.sink.received
        let ids = fixture.sink.streams
        let arms = fixture.timer.armCount
        let cancels = fixture.timer.cancelCount
        let deadline = fixture.timer.armedAt
        await #expect(throws: example.error) {
            try await fixture.driver.receive(.sysEx(payload: example.payload), group: group, stream: Self.one,
                                             atNanoseconds: example.time)
        }
        #expect(await fixture.driver.stream(Self.one) == before)
        #expect(fixture.sink.received == batches && fixture.sink.streams == ids)
        #expect(fixture.timer.armCount == arms && fixture.timer.cancelCount == cancels)
        #expect(fixture.timer.armedAt == deadline)
        // A rejected future stamp must not change the driver's hidden lastReceived baseline either.
        try await fixture.driver.receive(.sysEx(payload: []), group: group, stream: Self.one,
                                         atNanoseconds: 10 * Self.msec)
        #expect(fixture.sink.received.count == 1)
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 0)
    }

    @Test func sysExRefusalDoesNotCreateANewStreamOrDisturbAnother() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        let before = await fixture.driver.stream(Self.one)
        for index in [0, 1, 2, 3, 4, 6] {
            let example = Self.sysExRefusalExample(index)
            await #expect(throws: example.error) {
                try await fixture.driver.receive(.sysEx(payload: example.payload), group: UMPGroup(15),
                                                 stream: Self.two, atNanoseconds: example.time)
            }
            #expect(await fixture.driver.stream(Self.two) == nil)
            #expect(await fixture.driver.stream(Self.one) == before)
            #expect(fixture.sink.received.isEmpty)
            #expect(fixture.timer.armedAt == 5 * Self.msec)
            #expect(fixture.timer.armCount == 1 && fixture.timer.cancelCount == 0)
        }
    }

    @Test(arguments: [-1, 0, 1])
    func sysExStreamAdmissionTimeDoesNotDecideTheFlushCounter(offset: Int) throws {
        var stream = try Self.holding()
        let time = UInt64(Int(5 * Self.msec) + offset)
        let sent = try stream.receive(sysEx: Self.sysExPayload(7), group: UMPGroup(5),
                                      at: time, admittedAt: 100 * Self.msec)
        #expect(sent.first == .voice(try Self.mpe(15)))
        try Self.checkSysExItems(Array(sent.dropFirst()), length: 7, group: 5)
        #expect(stream.lastAcceptedTime == 100 * Self.msec)
        #expect(stream.idleFlushes == (offset < 0 ? 0 : 1))
        #expect(stream.deadline == nil)
        #expect(try stream.poll(at: 100 * Self.msec).isEmpty)
        #expect(try stream.receive(Self.cc(0, 38, 3), at: time + 1, admittedAt: 100 * Self.msec).messages
            == [try Self.mpe(15, lsb: 3)])
        let before = stream
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 100 * Self.msec, got: time + 2)) {
            try stream.receive(sysEx: [], group: UMPGroup(0), at: time + 2, admittedAt: 0)
        }
        #expect(stream == before)
        // An admission earlier than the event is raised to the event, as for the other stream paths.
        _ = try stream.receive(sysEx: [], group: UMPGroup(0), at: 101 * Self.msec, admittedAt: 0)
        #expect(stream.lastAcceptedTime == 101 * Self.msec)
    }
}

extension UMPTranslationStreamTests {
    @Test(arguments: [-1, 0, 1])
    func sysExAfterALatePollUsesTheEventDeadline(offset: Int) async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        await fixture.fire(at: 100 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        try await fixture.driver.receive(Self.control(0, 6, 20), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 20 * Self.msec)
        #expect(fixture.timer.armedAt == 25 * Self.msec)
        let time = UInt64(Int(25 * Self.msec) + offset)
        try await fixture.driver.receive(.sysEx(payload: Self.sysExPayload(12)), group: UMPGroup(5),
                                         stream: Self.one, atNanoseconds: time)
        let batch = try #require(fixture.sink.received.last)
        #expect(fixture.sink.received.count == 2)
        #expect(batch.first == .voice(try Self.mpe(20)))
        try Self.checkSysExItems(Array(batch.dropFirst()), length: 12, group: 5)
        let state = try #require(await fixture.driver.stream(Self.one))
        #expect(state.lastAcceptedTime == 100 * Self.msec)
        #expect(state.idleFlushes == (offset < 0 ? 1 : 2))
        #expect(state.deadline == nil)
        let arms = fixture.timer.armCount
        let cancels = fixture.timer.cancelCount
        await #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(
            previous: 100 * Self.msec, got: time - 1)) {
            try await fixture.driver.receive(.sysEx(payload: []), group: UMPGroup(5), stream: Self.one,
                                             atNanoseconds: time - 1)
        }
        #expect(await fixture.driver.stream(Self.one) == state)
        #expect(fixture.timer.armCount == arms && fixture.timer.cancelCount == cancels)
        #expect(fixture.sink.received.count == 2)
        await fixture.fire(at: 110 * Self.msec)
        #expect(fixture.sink.received.count == 2)
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: time + 1)
        #expect(fixture.sink.received == [try Self.batch(15), batch, try Self.batch(20, lsb: 3)])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == state.idleFlushes)
        #expect(await fixture.driver.pollRefusals == 0)
    }

    @Test func sysExAfterANonFlushingPollKeepsTheAdmissionBaseline() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 18 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        try await fixture.driver.receive(.sysEx(payload: []), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 19 * Self.msec)
        #expect(await fixture.driver.stream(Self.one)?.lastAcceptedTime == 20 * Self.msec)
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 0)
        #expect(fixture.sink.received.count == 1)
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 19 * Self.msec)
        #expect(fixture.sink.received.last == (try Self.batch(15, lsb: 3)))
        await fixture.fire(at: 30 * Self.msec)
        #expect(fixture.sink.received.count == 2)
    }

    @Test func sysExOnOneStreamRearmsForTheOtherWithoutChangingItsState() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        try await Self.hold(fixture, Self.two, at: 12 * Self.msec, value: 20)
        let other = await fixture.driver.stream(Self.two)
        try await fixture.driver.receive(.sysEx(payload: Self.sysExPayload(7)), group: UMPGroup(0),
                                         stream: Self.one, atNanoseconds: 11 * Self.msec)
        #expect(await fixture.driver.stream(Self.two) == other)
        #expect(fixture.sink.streams == [Self.one])
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        #expect(fixture.timer.armCount == 2 && fixture.timer.cancelCount == 0)
        await fixture.fire(at: 17 * Self.msec)
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(fixture.sink.received.last == (try Self.batch(20)))
        // Equal group/channel, independent event baselines and retained Data Entry values.
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 11 * Self.msec)
        #expect(fixture.sink.received.last == (try Self.batch(15, lsb: 3)))
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 0)
        #expect(await fixture.driver.stream(Self.two)?.idleFlushes == 1)
    }

    @Test func stoppedSysExCallsAreIgnoredBeforeAnyValidation() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        await fixture.driver.stop()
        let batches = fixture.sink.received
        let ids = fixture.sink.streams
        let arms = fixture.timer.armCount
        let cancels = fixture.timer.cancelCount
        for id in [Self.one, Self.two] {
            for payload in [[], [0xFF], Array(repeating: UInt8(0xFF), count: 4_097), Self.sysExPayload(4_096)] {
                try await fixture.driver.receive(.sysEx(payload: payload), group: UMPGroup(15), stream: id,
                                                 atNanoseconds: 0)
                #expect(await fixture.driver.stream(id) == nil)
            }
        }
        await fixture.fire(at: 100 * Self.msec)
        #expect(fixture.sink.received == batches && fixture.sink.streams == ids)
        #expect(fixture.timer.armCount == arms && fixture.timer.cancelCount == cancels)
        #expect(fixture.timer.armedAt == nil)
        #expect(await fixture.driver.pollRefusals == 0)
    }
}
