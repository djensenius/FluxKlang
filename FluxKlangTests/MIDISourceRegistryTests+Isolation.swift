import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDISourceRegistryTests {
    @Test func interleavedByteByByteFeedsEqualEachSourceFedAlone() throws {
        let bytesA = Self.stream(count: 1_500, seed: 1)
        let bytesB = Self.stream(count: 1_500, seed: 2)
        var mixed = try Self.registry([1, 2])
        var outputsA: [MIDISourceOutput] = []
        var outputsB: [MIDISourceOutput] = []
        for index in bytesA.indices {
            outputsA += try mixed.feed([bytesA[index]], from: Self.id(1))
            outputsB += try mixed.feed([bytesB[index]], from: Self.id(2))
        }
        var aloneA = try Self.registry([1])
        var aloneB = try Self.registry([2])
        let expectedA = try aloneA.feed(bytesA, from: Self.id(1))
        let expectedB = try aloneB.feed(bytesB, from: Self.id(2))
        #expect(expectedA.count > 100 && expectedB.count > 100)
        #expect(outputsA == expectedA)
        #expect(outputsB == expectedB)
        #expect(Self.state(mixed, 1) == Self.state(aloneA, 1))
        #expect(Self.state(mixed, 2) == Self.state(aloneB, 2))
    }

    @Test func aHalfMessageOnOneSourceIsNotCompletedByTheBytesOfAnother() throws {
        var registry = try Self.registry([1, 2])
        #expect(try registry.feed([0x90, 60], from: Self.id(1)).isEmpty)
        #expect(try registry.feed([0x05], from: Self.id(2)).isEmpty)
        #expect(try registry.feed(Self.noteOn(1, 70), from: Self.id(2)).count == 1)
        #expect(Self.held(registry, 1).isEmpty)
        let completed = try registry.feed([100], from: Self.id(1))
        #expect(Self.events(completed) == [.channel(status: 0x90, data1: 60, data2: 100)])
        #expect(Self.held(registry, 1) == [MIDI1HeldNote(note: 60, velocity: 100, phase: .keyDown)])
        #expect(Self.held(registry, 2) == [MIDI1HeldNote(note: 70, velocity: 100, phase: .keyDown)])
    }

    @Test func runningStatusBelongsToItsOwnSource() throws {
        var registry = try Self.registry([1, 2])
        _ = try registry.feed(Self.noteOn(1, 60), from: Self.id(1))
        _ = try registry.feed(Self.control(1, 7, 100), from: Self.id(2))
        let outputsA = try registry.feed([61, 101], from: Self.id(1))
        let outputsB = try registry.feed([8, 50], from: Self.id(2))
        #expect(Self.events(outputsA) == [.channel(status: 0x90, data1: 61, data2: 101)])
        #expect(Self.events(outputsB) == [.channel(status: 0xB0, data1: 8, data2: 50)])
        #expect(Self.held(registry, 2).isEmpty)
    }

    @Test func aSysExOnOneSourceIsNotClosedByTheEndOfAnother() throws {
        var registry = try Self.registry([1, 2])
        _ = try registry.feed([0xF0, 1, 2], from: Self.id(1))
        let bare = try registry.feed([0xF7], from: Self.id(2))
        #expect(Self.events(bare) == [.systemCommon(status: 0xF7, data1: nil, data2: nil)])
        let closed = try registry.feed([3, 0xF7], from: Self.id(1))
        #expect(Self.events(closed) == [.sysEx(payload: [1, 2, 3])])
    }

    @Test func delayedDataEntryStillLandsOnTheParameterItsSourceSelected() throws {
        var registry = try Self.registry([1, 2])
        _ = try registry.feed(Self.selectRPN(1, msb: 0, lsb: 0), from: Self.id(1))
        _ = try registry.feed(Self.selectRPN(1, msb: 0, lsb: 2) + Self.control(1, 6, 5), from: Self.id(2))
        for note in UInt8(0)..<100 {
            _ = try registry.feed(Self.noteOn(1, note) + Self.noteOff(1, note), from: Self.id(2))
        }
        let landed = try registry.feed(Self.control(1, 6, 12), from: Self.id(1))
        let bend = MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 0)
        let tuning = MIDI1ParameterNumber.coarseTuning
        let update = MIDI1StateUpdate(channel: 1, effect: .parameter(bend, value: 12 << 7))
        #expect(landed.map(\.outcome) == [.applied(update)])
        #expect(Self.state(registry, 1)?.channels[0].parameters == [MIDI1ParameterValue(number: bend, value: 12 << 7)])
        #expect(Self.state(registry, 2)?.channels[0].parameters == [MIDI1ParameterValue(number: tuning, value: 5 << 7)])
    }

    @Test func aNoteOffForTheSameNoteOnAnotherSourceDoesNotReleaseIt() throws {
        var registry = try Self.registry([1, 2])
        _ = try registry.feed(Self.noteOn(1, 60), from: Self.id(1))
        _ = try registry.feed(Self.noteOn(1, 60), from: Self.id(2))
        _ = try registry.feed(Self.noteOff(1, 60), from: Self.id(2))
        #expect(Self.held(registry, 1) == [MIDI1HeldNote(note: 60, velocity: 100, phase: .keyDown)])
        #expect(Self.held(registry, 2).isEmpty)
    }

    @Test func eachSourceKeepsItsOwnProfileStatePolicy() throws {
        var registry = try Self.registry([])
        let retain = try Self.profile(policy: Self.policy(retainLSB: true))
        try registry.register(Self.id(1), key: Self.key(1))
        try registry.register(Self.id(2), key: Self.key(2), profile: retain)
        let bytes = Self.selectRPN(1, msb: 0, lsb: 0) + Self.control(1, 38, 5) + Self.control(1, 6, 2)
        let standard = try registry.feed(bytes, from: Self.id(1))
        let retained = try registry.feed(bytes, from: Self.id(2))
        let number = MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 0)
        let low = MIDI1StateUpdate(channel: 1, effect: .parameter(number, value: 256))
        let high = MIDI1StateUpdate(channel: 1, effect: .parameter(number, value: 261))
        #expect(standard.last?.outcome == .applied(low))
        #expect(retained.last?.outcome == .applied(high))
        #expect(registry.snapshot.sources.map(\.state.policy) == [.standard, try Self.policy(retainLSB: true)])
    }

    @Test func aMessageSplitAtEveryByteBoundaryEqualsOnePacket() throws {
        let messages: [[UInt8]] = [
            Self.noteOn(1, 60), [0xC0, 5], [0xF0, 1, 2, 3, 0xF7], [0xF2, 1, 2],
            Self.noteOn(1, 60) + [61, 101] + Self.control(2, 7, 9)
        ]
        for message in messages {
            var whole = try Self.registry([1])
            let expected = try whole.feed(message, from: Self.id(1))
            #expect(!expected.isEmpty)
            for split in 1..<message.count {
                var parts = try Self.registry([1])
                let outputs = try Self.feedChunks(&parts, [Array(message[..<split]), Array(message[split...])], from: 1)
                #expect(outputs == expected)
                #expect(Self.state(parts, 1) == Self.state(whole, 1))
            }
        }
    }

    @Test func aRealTimeByteInsideAMessageIsTransparentAtEverySplit() throws {
        let message: [UInt8] = [0x90, 0xF8, 60, 0xFE, 100]
        let expected: [MIDI1Event] = [
            .realTime(status: 0xF8), .realTime(status: 0xFE), .channel(status: 0x90, data1: 60, data2: 100)
        ]
        for split in 0...message.count {
            var registry = try Self.registry([1])
            let chunks = [Array(message[..<split]), Array(message[split...])]
            #expect(Self.events(try Self.feedChunks(&registry, chunks, from: 1)) == expected)
            #expect(Self.held(registry, 1) == [MIDI1HeldNote(note: 60, velocity: 100, phase: .keyDown)])
        }
    }

    @Test func stateAndFramingPersistAcrossFeeds() throws {
        var registry = try Self.registry([1])
        _ = try registry.feed(Self.noteOn(1, 60) + Self.noteOn(1, 62), from: Self.id(1))
        _ = try registry.feed(Self.noteOn(1, 61), from: Self.id(1))
        #expect(Self.held(registry, 1).map(\.note) == [60, 61, 62])
        _ = try registry.feed(Self.noteOff(1, 61), from: Self.id(1))
        #expect(Self.held(registry, 1).map(\.note) == [60, 62])
    }

    @Test func everyOutputNamesTheSourceItCameFrom() throws {
        var registry = try Self.registry([4, 9])
        let first = try registry.feed(Self.noteOn(1, 60) + [0xF8], from: Self.id(9))
        let second = try registry.feed(Self.noteOn(1, 60), from: Self.id(4))
        #expect(first.map(\.input) == [Self.id(9), Self.id(9)])
        #expect(second.map(\.input) == [Self.id(4)])
    }

    @Test func aFeedNeverChangesTheSnapshotOfAnotherSource() throws {
        var registry = try Self.registry([1, 2, 3])
        _ = try registry.feed(Self.noteOn(1, 50) + Self.control(1, 7, 9), from: Self.id(2))
        let before = registry.snapshot
        try #require(before.sources.count == 3)
        _ = try registry.feed(Self.noteOn(1, 60) + Self.noteOn(1, 61), from: Self.id(1))
        _ = try registry.feed(Self.noteOn(1, 70) + Self.noteOff(1, 70) + Self.noteOn(1, 71), from: Self.id(3))
        try #require(registry.snapshot.sources.count == 3)
        #expect(registry.snapshot.sources[1] == before.sources[1])
        #expect(Self.held(registry, 2).map(\.note) == [50])
        #expect(Self.held(registry, 1).map(\.note) == [60, 61])
        #expect(Self.held(registry, 3).map(\.note) == [71])
        let fresh = Self.state(try Self.registry([1]), 1)
        #expect(before.sources[0].state == fresh)
        #expect(before.sources[2].state == fresh)
    }

    @Test func performanceEventsExistExactlyForAppliedChannelMessages() throws {
        var registry = try Self.registry([7])
        let bytes = Self.noteOn(1, 60) + [0xF8] + [0xF2, 1, 2] + [0xF0, 5, 0xF7] + Self.control(3, 7, 9)
        let outputs = try registry.feed(bytes, from: Self.id(7))
        try #require(outputs.count == 5)
        #expect(outputs.map { $0.performanceEvent != nil } == [true, false, false, false, true])
        #expect(outputs[0].performanceEvent == MIDIPerformanceEvent(
            input: Self.id(7), message: .noteOn(channel: 1, note: 60, velocity: 100)
        ))
        #expect(outputs[4].performanceEvent == MIDIPerformanceEvent(
            input: Self.id(7), message: .controlChange(channel: 3, controller: 7, value: 9)
        ))
        let others = try registry.feed([0x91, 60, 0, 0xC2, 4, 0xE0, 1, 2], from: Self.id(7))
        #expect(others.compactMap(\.performanceEvent?.message) == [
            .noteOff(channel: 2, note: 60, velocity: 64), .programChange(channel: 3, program: 4),
            .pitchBend(channel: 1, value: 257)
        ])
    }

    @Test func refusedAndResetOutputsCarryNoPerformanceEvent() throws {
        let limited = try Self.profile(reset: .resetSource, policy: Self.policy(heldNotes: 1))
        var registry = try Self.registry([7], profile: limited)
        let outputs = try registry.feed(Self.noteOn(1, 60) + Self.noteOn(1, 61) + [0xFF], from: Self.id(7))
        try #require(outputs.count == 3)
        #expect(outputs[0].performanceEvent != nil)
        #expect(outputs[1].outcome == .refused(.heldNoteLimit(channel: 1, note: 61)))
        #expect(outputs[1].performanceEvent == nil)
        #expect(outputs[2].performanceEvent == nil)
    }
}
