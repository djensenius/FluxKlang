import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The registry fixtures, shared rather than copied.
private typealias Sources = MIDISourceRegistryTests

/// Seeded LCG (the constants of `MIDISourceRegistryTests.stream`): no clock and no system randomness, so every run
/// sees the same traffic and the same packet boundaries.
private struct AcceptanceRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// 0..<bound, for a positive bound.
    mutating func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state >> 33) % bound
    }

    mutating func data() -> UInt8 { UInt8(next(below: 128)) }
}

private let rpnZero = MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 0)

private func selection(_ msb: UInt8, _ lsb: UInt8, _ program: UInt8) -> MIDI1ProgramSelection {
    MIDI1ProgramSelection(bankMSB: msb, bankLSB: lsb, program: program)
}

/// One complete message on wire channels 2...16 (never channel 1), a real-time byte F8...FE, a short SysEx or a
/// Song Position Pointer. CC 0...119 only, so RPN/NRPN selection and Data Entry happen on other channels too.
private func otherChannelMessage(_ random: inout AcceptanceRandom) -> (status: UInt8, data: [UInt8]) {
    let channel = UInt8(1 + random.next(below: 15))
    switch random.next(below: 9) {
    case 0: return (0x90 | channel, [random.data(), UInt8(1 + random.next(below: 127))])
    case 1: return (0x80 | channel, [random.data(), random.data()])
    case 2: return (0xB0 | channel, [UInt8(random.next(below: 120)), random.data()])
    case 3: return (0xC0 | channel, [random.data()])
    case 4: return (0xD0 | channel, [random.data()])
    case 5: return (0xE0 | channel, [random.data(), random.data()])
    case 6: return (0xF8 + UInt8(random.next(below: 7)), [])
    case 7:
        var payload: [UInt8] = []
        for _ in 0..<random.next(below: 9) { payload.append(random.data()) }
        return (0xF0, payload + [0xF7])
    default: return (0xF2, [random.data(), random.data()])
    }
}

/// At least `byteCount` bytes of other-channel traffic; a repeated channel status is left out (running status).
private func otherChannelTraffic(byteCount: Int, _ random: inout AcceptanceRandom) -> [UInt8] {
    var bytes: [UInt8] = []
    var running: UInt8?
    while bytes.count < byteCount {
        let message = otherChannelMessage(&random)
        if message.status >= 0xF8 {
            bytes.append(message.status)
            continue
        }
        if message.status != running { bytes.append(message.status) }
        bytes += message.data
        running = message.status < 0xF0 ? message.status : nil
    }
    return bytes
}

/// Splits `bytes` at seeded boundaries into packets of 1...`maximum` bytes, with an occasional empty packet.
private func packets(_ bytes: [UInt8], maximum: Int, _ random: inout AcceptanceRandom) -> [[UInt8]] {
    var chunks: [[UInt8]] = []
    var start = bytes.startIndex
    while start < bytes.endIndex {
        if random.next(below: 16) == 0 { chunks.append([]) }
        let end = min(start + 1 + random.next(below: maximum), bytes.endIndex)
        chunks.append(Array(bytes[start..<end]))
        start = end
    }
    return chunks
}

/// The outcomes of the channel voice messages a source received on channel `channel` (1...16), in order.
private func outcomes(_ outputs: [MIDISourceOutput], channel: UInt8) -> [MIDISourceOutcome] {
    outputs.filter { output in
        guard case let .channel(status, _, _) = output.event else { return false }
        return status & 0x0F == channel - 1
    }.map(\.outcome)
}

private func applied(_ effects: [MIDI1StateEffect], channel: UInt8) -> [MIDISourceOutcome] {
    effects.map { .applied(MIDI1StateUpdate(channel: channel, effect: $0)) }
}

/// #80 acceptance at the byte level: bytes through `MIDISourceRegistry` into each source's MIDI 1 state.
extension MIDIProtocolTests {
    /// An RPN selected on channel 1 survives about 10,000 bytes of other-channel traffic, real-time, SysEx and
    /// System Common split at seeded packet boundaries; the late Data Entry lands under each source's own profile.
    @Test func acceptanceDelayedDataEntryAcrossPacketsAndProfiles() throws {
        var registry = try Sources.registry([])
        try registry.register(Sources.id(1), key: Sources.key(1))
        let retain = try Sources.profile(policy: Sources.policy(retainLSB: true))
        try registry.register(Sources.id(2), key: Sources.key(2), profile: retain)
        try registry.register(Sources.id(3), key: Sources.key(3), profile: .unpaired)
        var random = AcceptanceRandom(seed: 0x4D55_0001)
        let traffic = otherChannelTraffic(byteCount: 10_000, &random)
        // LSB first, then the MSB by running status, with a real-time byte inside each message.
        let entry: [UInt8] = [0xB0, 38, 0xF8, 5, 6, 0xFE, 12]
        let chunks = packets(Sources.selectRPN(1, msb: 0, lsb: 0) + traffic + entry, maximum: 64, &random)
        try #require(chunks.count > 200)
        var outputs: [[MIDISourceOutput]] = []
        for raw in UInt32(1)...3 { outputs.append(try Sources.feedChunks(&registry, chunks, from: raw)) }
        try #require(outputs.count == 3)
        #expect(outputs.allSatisfy { $0.count > 3_000 })

        let selected: [MIDI1StateEffect] = [
            .parameterSelected(MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 127)), .parameterSelected(rpnZero)
        ]
        #expect(outcomes(outputs[0], channel: 1) == applied(
            selected + [.parameter(rpnZero, value: 5), .parameter(rpnZero, value: 12 << 7)], channel: 1
        ))
        #expect(outcomes(outputs[1], channel: 1) == applied(
            selected + [.parameter(rpnZero, value: 5), .parameter(rpnZero, value: 12 << 7 | 5)], channel: 1
        ))
        let plain: [MIDI1StateEffect] = [
            .controller(101, value: 0), .controller(100, value: 0), .controller(38, value: 5), .controller(6, value: 12)
        ]
        #expect(outcomes(outputs[2], channel: 1) == applied(plain, channel: 1))
        let tail: [MIDI1Event] = [
            .realTime(status: 0xF8), .channel(status: 0xB0, data1: 38, data2: 5), .realTime(status: 0xFE),
            .channel(status: 0xB0, data1: 6, data2: 12)
        ]
        for output in outputs { #expect(output.suffix(4).map(\.event) == tail) }

        let firsts = try registry.snapshot.sources.map { try #require($0.state.channels.first) }
        try #require(firsts.count == 3)
        #expect(firsts[0].parameters == [MIDI1ParameterValue(number: rpnZero, value: 12 << 7)])
        #expect(firsts[1].parameters == [MIDI1ParameterValue(number: rpnZero, value: 12 << 7 | 5)])
        #expect(firsts[2].parameters.isEmpty && firsts[2].activeParameterKind == nil)
    }

    /// Half messages, stray data, a SysEx one byte over the bound and data inside aborted SysEx change no state,
    /// whole or byte by byte; the next valid message still lands on the parameter selected before them, and the
    /// null RPN then deselects it.
    @Test func acceptanceFragmentsLeaveSnapshotUnchanged() throws {
        let limit = 4
        var registry = try Sources.registry([1], profile: Sources.profile(sysEx: limit))
        let setup = Sources.selectRPN(1, msb: 0, lsb: 0) + Sources.control(1, 6, 1) + Sources.noteOn(1, 60)
        _ = try registry.feed(setup, from: Sources.id(1))
        let before = registry.snapshot
        let fragments: [[UInt8]] = [
            [0xB0, 6],
            [0x90, 61],
            [0xF7, 6, 9],
            [0xF0] + Array(repeating: 6, count: limit + 1) + [0xF7],
            [0xF0, 1, 2, 0xF4, 6, 9],
            [0xF0, 1, 2, 0xF5, 38, 7],
            [0xE0, 5],
            [0xF6, 0xF7],
            [0xB0, 38]
        ]
        var bytewise = registry
        let whole = try Sources.feedChunks(&registry, fragments, from: 1)
        let single = try Sources.feedChunks(&bytewise, fragments.joined().map { [$0] }, from: 1)
        let statuses: [UInt8] = [0xF7, 0xF4, 0xF5, 0xF6, 0xF7]
        #expect(Sources.events(whole) == statuses.map { .systemCommon(status: $0, data1: nil, data2: nil) })
        let unchanged = MIDISourceOutcome.applied(MIDI1StateUpdate(channel: nil, effect: .unchanged))
        #expect(whole.map(\.outcome) == Array(repeating: unchanged, count: statuses.count))
        #expect(single == whole)
        #expect(registry.snapshot == before)
        #expect(bytewise.snapshot == before)

        let next = try registry.feed([0xB0, 38, 7], from: Sources.id(1))
        #expect(next.map(\.outcome) == applied([.parameter(rpnZero, value: 1 << 7 | 7)], channel: 1))
        let channel = try #require(Sources.state(registry, 1)?.channels.first)
        #expect(channel.heldNotes.map(\.note) == [60])

        // The null RPN (127/127) deselects: the following Data Entry is refused and stores nothing.
        let nullEntry = try registry.feed(Sources.selectRPN(1, msb: 127, lsb: 127) + Sources.control(1, 6, 9),
                                          from: Sources.id(1))
        #expect(nullEntry.map(\.outcome) == applied([
            .parameterSelected(MIDI1ParameterNumber(kind: .registered, msb: 127, lsb: 0)), .parameterSelected(nil)
        ], channel: 1) + [.refused(.noParameterSelected(channel: 1, controller: 6))])
        let deselected = try #require(Sources.state(registry, 1)?.channels.first)
        #expect(deselected.parameters == [MIDI1ParameterValue(number: rpnZero, value: 1 << 7 | 7)])
    }

    /// 14-bit pairs in both orders, the Bank Select latch and Program Change, under three profiles at once.
    @Test func acceptanceFourteenBitBankAndProgram() throws {
        var registry = try Sources.registry([])
        try registry.register(Sources.id(1), key: Sources.key(1))
        let retain = try Sources.profile(policy: Sources.policy(retainLSB: true))
        try registry.register(Sources.id(2), key: Sources.key(2), profile: retain)
        try registry.register(Sources.id(3), key: Sources.key(3), profile: .unpaired)
        let bytes: [UInt8] = [
            0xB0, 1, 0x10, 33, 5, 0xF8, 33, 6, 1, 0x11, // MSB then LSB; then LSB before MSB
            0, 2, 32, 3, // Bank Select 2/3
            0x91, 60, 64, 0xB1, 0, 9, 32, 10, 0xC1, 5, // channel 2 latches and uses its own bank
            0xC0, 7, 0xFE, 8, // two programs, the second by running status
            0xB0, 0, 4 // a new bank MSB keeps the latched LSB
        ]
        var outputs: [[MIDISourceOutput]] = []
        for raw in UInt32(1)...3 {
            let latched = try registry.feed(bytes, from: Sources.id(raw))
            // The new bank waits for the next Program Change: the stored program still carries bank 2/3.
            let pending = try #require(Sources.state(registry, raw)?.channels.first)
            #expect(pending.program == selection(2, 3, 8))
            let programmed = try registry.feed([0xC0, 9], from: Sources.id(raw))
            outputs.append(latched + programmed)
        }
        try #require(outputs.count == 3)

        let programs: [MIDI1StateEffect] = [
            .program(selection(2, 3, 7)), .program(selection(2, 3, 8)), .bankLatched(msb: 4, lsb: 3),
            .program(selection(4, 3, 9))
        ]
        let pairs: [MIDI1StateEffect] = [
            .controller14(1, value: 0x10 << 7), .controller14(1, value: 0x10 << 7 | 5),
            .controller14(1, value: 0x10 << 7 | 6)
        ]
        let banks: [MIDI1StateEffect] = [.bankLatched(msb: 2, lsb: 0), .bankLatched(msb: 2, lsb: 3)]
        #expect(outcomes(outputs[0], channel: 1) == applied(
            pairs + [.controller14(1, value: 0x11 << 7)] + banks + programs, channel: 1
        ))
        #expect(outcomes(outputs[1], channel: 1) == applied(
            pairs + [.controller14(1, value: 0x11 << 7 | 6)] + banks + programs, channel: 1
        ))
        let plain: [MIDI1StateEffect] = [
            .controller(1, value: 0x10), .controller(33, value: 5), .controller(33, value: 6),
            .controller(1, value: 0x11), .controller(0, value: 2), .controller(32, value: 3),
            .program(selection(2, 3, 7)), .program(selection(2, 3, 8)), .controller(0, value: 4),
            .program(selection(4, 3, 9))
        ]
        #expect(outcomes(outputs[2], channel: 1) == applied(plain, channel: 1))

        let sources = registry.snapshot.sources
        try #require(sources.count == 3)
        var lsbs: [UInt8] = []
        for source in sources {
            let channels = source.state.channels
            try #require(channels.count == 16)
            #expect(channels[0].program == selection(4, 3, 9))
            #expect(channels[1].program == selection(9, 10, 5))
            try #require(channels[0].controllers.count == 128)
            lsbs.append(channels[0].controllers[33])
        }
        #expect(lsbs == [0, 6, 6])
    }

    /// The same bytes, System Reset included, reach a `.ignore` and a `.resetSource` source in interleaved seeded
    /// packets: each behaves as documented for its own profile and exactly as it would alone.
    @Test func acceptanceProfilePolicyIsPerSource() throws {
        let resetting = try Sources.profile(reset: .resetSource)
        var registry = try Sources.registry([1])
        try registry.register(Sources.id(2), key: Sources.key(2), profile: resetting)
        let held = Sources.noteOn(1, 60) + Sources.sustain(1, down: true) + Sources.noteOn(1, 62)
            + Sources.noteOff(1, 62) + Sources.selectRPN(1, msb: 0, lsb: 0)
        let lead = held + [0x90, 64]
        let trail: [UInt8] = [100] + Sources.noteOn(1, 70) + Sources.control(1, 6, 3)
        var random = AcceptanceRandom(seed: 0x4D55_0004)
        let chunks = packets(lead + [0xFF] + trail, maximum: 4, &random)
        var ignoring: [MIDISourceOutput] = []
        var reset: [MIDISourceOutput] = []
        for chunk in chunks {
            ignoring += try registry.feed(chunk, from: Sources.id(1))
            reset += try registry.feed(chunk, from: Sources.id(2))
        }

        let isReset: (MIDISourceOutput) -> Bool = { $0.event == .realTime(status: 0xFF) }
        let unchanged = MIDISourceOutcome.applied(MIDI1StateUpdate(channel: nil, effect: .unchanged))
        #expect(ignoring.filter(isReset).map(\.outcome) == [unchanged])
        var transparent = try Sources.registry([1])
        let withoutReset = try transparent.feed(lead + trail, from: Sources.id(1))
        #expect(ignoring.filter { !isReset($0) } == withoutReset)
        #expect(Sources.state(registry, 1) == Sources.state(transparent, 1))
        #expect(Sources.held(registry, 1).map(\.note) == [60, 62, 64, 70])
        let firstIgnoring = try #require(Sources.state(registry, 1)?.channels.first)
        #expect(firstIgnoring.parameters == [MIDI1ParameterValue(number: rpnZero, value: 3 << 7)])

        let released = [
            MIDISourceRelease(channel: 1, note: 60, phase: .keyDown),
            MIDISourceRelease(channel: 1, note: 62, phase: .sustained)
        ]
        #expect(reset.filter(isReset).map(\.outcome) == [.systemReset(released: released)])
        var fresh = try Sources.registry([2], profile: resetting)
        let afterReset = try fresh.feed(trail, from: Sources.id(2))
        #expect(Array(reset.drop(while: { !isReset($0) }).dropFirst()) == afterReset)
        #expect(Sources.state(registry, 2) == Sources.state(fresh, 2))
        #expect(Sources.held(registry, 2).map(\.note) == [70])
        #expect(afterReset.last?.outcome == .refused(.noParameterSelected(channel: 1, controller: 6)))

        var alone = try Sources.registry([2], profile: resetting)
        #expect(try Sources.feedChunks(&alone, chunks, from: 2) == reset)
        #expect(Sources.state(alone, 2) == Sources.state(registry, 2))
    }
}
