import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDISourceRegistryTests {
    private static let freshApplied = MIDISourceOutcome.applied(MIDI1StateUpdate(channel: nil, effect: .unchanged))

    /// Notes held on channels 1 and 3 in a deliberately scrambled order; channel 1 has one sustained note.
    private static let scrambledNotes: [UInt8] =
        noteOn(3, 70) + noteOn(1, 72) + sustain(1, down: true) + noteOn(1, 60) + noteOff(1, 60) + noteOn(3, 5)

    private static let scrambledReleases = [
        MIDISourceRelease(channel: 1, note: 60, phase: .sustained),
        MIDISourceRelease(channel: 1, note: 72, phase: .keyDown),
        MIDISourceRelease(channel: 3, note: 5, phase: .keyDown),
        MIDISourceRelease(channel: 3, note: 70, phase: .keyDown)
    ]

    private static func resetRegistry(_ raws: [UInt32] = [1, 2]) throws -> MIDISourceRegistry {
        try registry(raws, profile: profile(reset: .resetSource))
    }

    @Test func systemResetIsIgnoredByDefaultAndPassesThroughWithoutChangingState() throws {
        #expect(MIDISourceProfile.standard.systemReset == .ignore)
        #expect(try MIDISourceProfile.make().systemReset == .ignore)
        var registry = try Self.registry([1])
        _ = try registry.feed(Self.scrambledNotes + [0x90, 7], from: Self.id(1))
        let before = registry
        let outputs = try registry.feed([0xFF], from: Self.id(1))
        #expect(outputs.map(\.event) == [.realTime(status: 0xFF)])
        #expect(outputs.map(\.outcome) == [Self.freshApplied])
        #expect(registry.snapshot == before.snapshot)
        #expect(try Self.continuation(registry) == Self.continuation(before))
    }

    @Test func resetSourceReleasesEveryHeldNoteAscendingWithItsPhase() throws {
        var registry = try Self.resetRegistry([1])
        _ = try registry.feed(Self.scrambledNotes, from: Self.id(1))
        let outputs = try registry.feed([0xFF], from: Self.id(1))
        #expect(outputs.map(\.outcome) == [.systemReset(released: Self.scrambledReleases)])
        #expect(outputs.map(\.event) == [.realTime(status: 0xFF)])
        #expect(outputs.map { $0.performanceEvent == nil } == [true])
    }

    @Test func aFullChannelOfHeldNotesIsReportedAscending() throws {
        var registry = try Self.resetRegistry([1])
        for note in stride(from: UInt8(127), through: 0, by: -1) {
            _ = try registry.feed(Self.noteOn(2, note), from: Self.id(1))
        }
        let outputs = try registry.feed([0xFF], from: Self.id(1))
        let expected = (0...127).map { MIDISourceRelease(channel: 2, note: UInt8($0), phase: .keyDown) }
        #expect(outputs.map(\.outcome) == [.systemReset(released: expected)])
    }

    @Test func resetSourceReplacesTheStateWithAFreshOneOfTheSourcesOwnPolicy() throws {
        let policy = try Self.policy(heldNotes: 2)
        let profile = try Self.profile(reset: .resetSource, policy: policy)
        var registry = try Self.registry([1], profile: profile)
        let fresh = Self.state(registry, 1)
        let busy = Self.scrambledNotes + Self.selectRPN(1, msb: 0, lsb: 2) + Self.control(1, 6, 9)
            + [0xE0, 5, 5, 0xC0, 3]
        _ = try registry.feed(busy + Self.sustain(3, down: true) + Self.control(2, 7, 99), from: Self.id(1))
        #expect(Self.state(registry, 1) != fresh)
        _ = try registry.feed([0xFF], from: Self.id(1))
        #expect(Self.state(registry, 1) == fresh)
        #expect(Self.state(registry, 1)?.policy == policy)
        let limited = try registry.feed(Self.noteOn(1, 1) + Self.noteOn(1, 2) + Self.noteOn(1, 3), from: Self.id(1))
        #expect(limited.last?.outcome == .refused(.heldNoteLimit(channel: 1, note: 3)))
        _ = try registry.feed(Self.noteOff(1, 1), from: Self.id(1))
        #expect(Self.held(registry, 1).map(\.note) == [2])
    }

    @Test func bytesAfterTheResetInTheSameFeedAreParsedFromTheFreshState() throws {
        var registry = try Self.resetRegistry([1])
        let running = try registry.feed(Self.noteOn(1, 60) + [0xFF, 61, 100], from: Self.id(1))
        #expect(running.map(\.event) == [.channel(status: 0x90, data1: 60, data2: 100), .realTime(status: 0xFF)])
        #expect(Self.held(registry, 1).isEmpty)
        let after = try registry.feed([0xFF] + Self.noteOn(1, 62), from: Self.id(1))
        #expect(after.count == 2)
        #expect(Self.held(registry, 1).map(\.note) == [62])
        let selected = Self.selectRPN(1, msb: 0, lsb: 0) + [0xFF] + Self.control(1, 6, 4)
        let refused = try registry.feed(selected, from: Self.id(1))
        #expect(refused.last?.outcome == .refused(.noParameterSelected(channel: 1, controller: 6)))
    }

    @Test func aResetInsideASysExDropsTheOpenSysExOnlyWhenTheSourceResets() throws {
        let bytes: [UInt8] = [0xF0, 1, 2, 0xFF, 3, 0xF7]
        var resetting = try Self.resetRegistry([1])
        let dropped = try resetting.feed(bytes, from: Self.id(1))
        #expect(dropped.map(\.event) == [.realTime(status: 0xFF), .systemCommon(status: 0xF7, data1: nil, data2: nil)])
        #expect(dropped.map(\.outcome) == [.systemReset(released: []), Self.freshApplied])
        var ignoring = try Self.registry([1])
        let kept = try ignoring.feed(bytes, from: Self.id(1))
        #expect(kept.map(\.event) == [.realTime(status: 0xFF), .sysEx(payload: [1, 2, 3])])
        #expect(kept.map(\.outcome) == [Self.freshApplied, Self.freshApplied])
    }

    @Test func aResetDropsAHalfMessageOnlyWhenTheSourceResets() throws {
        var resetting = try Self.resetRegistry([1])
        let dropped = try resetting.feed([0x90, 60, 0xFF, 100], from: Self.id(1))
        #expect(dropped.map(\.event) == [.realTime(status: 0xFF)])
        var ignoring = try Self.registry([1])
        let kept = try ignoring.feed([0x90, 60, 0xFF, 100], from: Self.id(1))
        #expect(kept.map(\.event) == [.realTime(status: 0xFF), .channel(status: 0x90, data1: 60, data2: 100)])
    }

    @Test func aResetOfOneSourceLeavesEveryOtherSourceUntouched() throws {
        var registry = try Self.registry([1, 2, 3])
        try registry.register(Self.id(4), key: Self.key(4), profile: Self.profile(reset: .resetSource))
        for raw in UInt32(1)...4 { _ = try registry.feed(Self.scrambledNotes + [0x90, 7], from: Self.id(raw)) }
        let before = registry
        _ = try registry.feed([0xFF], from: Self.id(4))
        for raw in UInt32(1)...3 { #expect(Self.state(registry, raw) == Self.state(before, raw)) }
        #expect(Self.held(registry, 4).isEmpty)
        let resumed = try Self.continuation(registry)
        let expected = try Self.continuation(before)
        try #require(resumed.count >= 3 && expected.count >= 3)
        #expect(Array(resumed[0..<3]) == Array(expected[0..<3]))
        _ = try registry.resetSource(Self.id(2))
        #expect(Self.state(registry, 1) == Self.state(before, 1))
        #expect(Self.state(registry, 3) == Self.state(before, 3))
    }

    @Test func aResetByteOnOneSourceDoesNotResetAnotherSourceThatResetsToo() throws {
        var registry = try Self.resetRegistry([1, 2])
        _ = try registry.feed(Self.noteOn(1, 60), from: Self.id(1))
        _ = try registry.feed(Self.noteOn(1, 61), from: Self.id(2))
        _ = try registry.feed([0xFF], from: Self.id(1))
        #expect(Self.held(registry, 1).isEmpty)
        #expect(Self.held(registry, 2).map(\.note) == [61])
    }

    @Test func detachReportsTheSameReleasesAsAResetAndRemovesTheSource() throws {
        for policy in [MIDISystemResetPolicy.ignore, .resetSource] {
            var registry = try Self.registry([1, 2], profile: Self.profile(reset: policy))
            _ = try registry.feed(Self.scrambledNotes, from: Self.id(1))
            _ = try registry.feed(Self.noteOn(1, 40), from: Self.id(2))
            let report = try registry.detach(Self.id(1))
            #expect(report == Self.scrambledReleases)
            #expect(registry.sources.map(\.input) == [Self.id(2)])
            #expect(Self.held(registry, 2).map(\.note) == [40])
            #expect(Self.refusal { try registry.feed([0xF8], from: Self.id(1)) } == .unknownInput(Self.id(1)))
        }
    }

    @Test func resetSourceWorksUnderIgnoreAndDropsTheHalfMessage() throws {
        var registry = try Self.registry([1, 2])
        _ = try registry.feed(Self.scrambledNotes + [0x90, 7], from: Self.id(1))
        _ = try registry.feed(Self.noteOn(1, 40), from: Self.id(2))
        let report = try registry.resetSource(Self.id(1))
        #expect(report == Self.scrambledReleases)
        #expect(Self.state(registry, 1) == Self.state(try Self.registry([1]), 1))
        #expect(try Self.continuation(registry).first == Self.continuation(Self.registry([1])).first)
        #expect(Self.held(registry, 2).map(\.note) == [40])
        #expect(registry.sources.count == 2)
    }

    @Test func aResetWithNothingHeldReportsNoReleases() throws {
        var registry = try Self.resetRegistry([1])
        let outputs = try registry.feed([0xFF, 0xFF], from: Self.id(1))
        #expect(outputs.map(\.outcome) == [.systemReset(released: []), .systemReset(released: [])])
        #expect(try registry.resetSource(Self.id(1)).isEmpty)
        #expect(try registry.detach(Self.id(1)).isEmpty)
    }

    @Test func theSecondResetInARowReportsNothingAfterTheFirstReleasedEverything() throws {
        var registry = try Self.resetRegistry([1])
        _ = try registry.feed(Self.scrambledNotes, from: Self.id(1))
        let outputs = try registry.feed([0xFF, 0xFF], from: Self.id(1))
        #expect(outputs.map(\.outcome) == [.systemReset(released: Self.scrambledReleases), .systemReset(released: [])])
    }

    @Test func detachAndResetOfAnUnknownInputAreRefusedAndChangeNothing() throws {
        var registry = try Self.registry([1, 2], profile: Self.profile(reset: .resetSource))
        _ = try registry.feed(Self.scrambledNotes + [0x90, 7], from: Self.id(1))
        let before = registry
        #expect(Self.refusal { try registry.detach(Self.id(3)) } == .unknownInput(Self.id(3)))
        #expect(Self.refusal { try registry.resetSource(Self.id(3)) } == .unknownInput(Self.id(3)))
        #expect(Self.refusal { try registry.feed([0xFF], from: Self.id(3)) } == .unknownInput(Self.id(3)))
        #expect(registry.snapshot == before.snapshot)
        #expect(try Self.continuation(registry) == Self.continuation(before))
    }
}
