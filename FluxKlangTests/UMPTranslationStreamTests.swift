import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI 1→2 translation stream")
struct UMPTranslationStreamTests {
    static let msec: UInt64 = 1_000_000
    static let empty = UMPTranslationOutput<UMPMIDI2ChannelVoice>(messages: [], losses: [])

    static func cc(_ channel: UInt8, _ controller: UInt8, _ value: UInt8, group: UInt8 = 0) throws
        -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: 0xB0 | channel, data1: controller,
                                                                           data2: value))
    }

    static func noteOn(_ channel: UInt8, _ note: UInt8, group: UInt8 = 0) throws -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: 0x90 | channel, data1: note,
                                                                           data2: 100))
    }

    static func mt4(_ group: UInt8, _ channel: UInt8, _ message: UMPMIDI2Message) throws -> UMPMIDI2ChannelVoice {
        UMPMIDI2ChannelVoice(group: try UMPGroup(group), channel: try UMPChannel(channel), message: message)
    }

    /// The MIDI 2.0 Note On that `noteOn(_:_:group:)` (velocity 100) becomes.
    static func noteOnMT4(_ channel: UInt8, _ note: UInt8, group: UInt8 = 0) throws -> UMPMIDI2ChannelVoice {
        let velocity = UInt16(try UMPScaling.scaleUp(100, fromBits: 7, toBits: 16))
        return try mt4(group, channel, .noteOn(note: UMPSevenBit(note), velocity: velocity, attributeType: 0,
                                               attribute: 0))
    }

    /// The Registered Controller RPN 0/6 (MPE Configuration) that CC 6 `msb` and CC 38 `lsb` become.
    static func mpe(_ msb: UInt8, lsb: UInt8 = 0, channel: UInt8 = 0, group: UInt8 = 0) throws
        -> UMPMIDI2ChannelVoice {
        let value = try UMPScaling.scaleUp(UInt32(msb) << 7 | UInt32(lsb), fromBits: 14, toBits: 32)
        return try mt4(group, channel, .registeredController(bank: UMPSevenBit(0), index: UMPSevenBit(6),
                                                             value: value))
    }

    static func timeout(_ nanoseconds: UInt64) throws -> UMPTranslationStreamTimeout {
        try UMPTranslationStreamTimeout.make(nanoseconds: nanoseconds)
    }

    /// Selects RPN 0/6 on one group and channel at `time`; the selection is absorbed, so nothing is sent.
    static func selectMPE(_ stream: inout UMPTranslationStream, at time: UInt64, channel: UInt8 = 0,
                          group: UInt8 = 0) throws {
        #expect(try stream.receive(cc(channel, 101, 0, group: group), at: time) == empty)
        #expect(try stream.receive(cc(channel, 100, 6, group: group), at: time) == empty)
    }

    @Test(arguments: [UInt64(1_000_000), UInt64(5_000_000), UInt64(100_000_000)])
    func aLoneDataEntryIsSentExactlyAtItsDeadline(timeoutNanoseconds: UInt64) throws {
        var stream = UMPTranslationStream(timeout: try Self.timeout(timeoutNanoseconds))
        try Self.selectMPE(&stream, at: 0)
        #expect(stream.deadline == nil)
        #expect(try stream.receive(Self.cc(0, 6, 15), at: 10 * Self.msec) == Self.empty)
        let deadline = 10 * Self.msec + timeoutNanoseconds
        #expect(stream.deadline == deadline)
        #expect(try stream.poll(at: deadline - 1).isEmpty)
        #expect(stream.deadline == deadline)
        #expect(stream.translator.heldDataEntry == (try Self.mpe(15)))
        #expect(stream.idleFlushes == 0)
        #expect(try stream.poll(at: deadline) == [try Self.mpe(15)])
        #expect(stream.deadline == nil)
        #expect(stream.translator.heldDataEntry == nil)
        #expect(stream.idleFlushes == 1)
        // Sent exactly once.
        #expect(try stream.poll(at: deadline).isEmpty)
        #expect(try stream.poll(at: deadline + 10 * Self.msec).isEmpty)
        #expect(stream.endOfStream().isEmpty)
        #expect(stream.idleFlushes == 1)
        #expect(stream.endOfStreamFlushes == 0)
        #expect(stream.resetFlushes == 0)
        #expect(stream.losses.total == 0)
    }

    @Test func endOfStreamSendsAHeldDataEntryAndKeepsTheTranslatorState() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 100 * Self.msec)
        _ = try stream.receive(Self.cc(0, 6, 15), at: 101 * Self.msec)
        // Sent at once, without waiting for the deadline.
        #expect(stream.endOfStream() == [try Self.mpe(15)])
        #expect(stream.endOfStreamFlushes == 1)
        #expect(stream.idleFlushes == 0)
        #expect(stream.deadline == nil)
        #expect(stream.lastAcceptedTime == nil)
        #expect(stream.translator.heldDataEntry == nil)
        #expect(stream.endOfStream().isEmpty)
        #expect(stream.endOfStreamFlushes == 1)
        // The selection is kept, so the next stream's CC 6 is held again.
        #expect(stream.translator.state(group: try UMPGroup(0), channel: try UMPChannel(0)).parameter != nil)
        #expect(try stream.receive(Self.cc(0, 6, 3), at: 101 * Self.msec) == Self.empty)
        #expect(stream.deadline == 106 * Self.msec)
        #expect(stream.endOfStream() == [try Self.mpe(3)])
        #expect(stream.endOfStreamFlushes == 2)
        #expect(stream.losses.total == 0)
    }

    @Test func aStreamAfterEndOfStreamMayStartAtAnEarlierTime() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 50 * Self.msec)
        _ = try stream.receive(Self.noteOn(0, 60), at: 60 * Self.msec)
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 60 * Self.msec, got: 0)) {
            try stream.poll(at: 0)
        }
        #expect(stream.endOfStream().isEmpty)
        #expect(stream.lastAcceptedTime == nil)
        // The next track starts at 0; its own times then run forward from there.
        #expect(try stream.receive(Self.cc(0, 6, 3), at: 0) == Self.empty)
        #expect(stream.lastAcceptedTime == 0)
        #expect(stream.deadline == 5 * Self.msec)
        #expect(try stream.poll(at: 5 * Self.msec) == [try Self.mpe(3)])
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 5 * Self.msec, got: 4 * Self.msec)) {
            try stream.poll(at: 4 * Self.msec)
        }
    }

    @Test(arguments: [UInt64(1_000_000), UInt64(6_000_000 - 1)])
    func aDataEntryCompletedWithinTheTimeoutIsOneControllerAndNoFlush(lsbTime: UInt64) throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 0)
        #expect(try stream.receive(Self.cc(0, 6, 15), at: Self.msec) == Self.empty)
        #expect(try stream.receive(Self.cc(0, 38, 3), at: lsbTime)
            == UMPTranslationOutput(messages: [try Self.mpe(15, lsb: 3)], losses: []))
        #expect(stream.deadline == nil)
        #expect(try stream.poll(at: 1_000 * Self.msec).isEmpty)
        #expect(stream.endOfStream().isEmpty)
        #expect(stream.idleFlushes == 0)
        #expect(stream.endOfStreamFlushes == 0)
        #expect(stream.losses.total == 0)
    }

    /// Observed translator behaviour, unchanged here: a flush keeps the Data Entry MSB, so a late CC 38 sends the
    /// controller again with the last MSB and its LSB, and declares no loss.
    @Test func aLateDataEntryLSBAfterAnIdleFlushSendsTheControllerAgainWithItsLSB() throws {
        // Received at the deadline: the idle flush (LSB 0) comes first, then the late CC 38's own output.
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 0)
        _ = try stream.receive(Self.cc(0, 6, 15), at: 0)
        #expect(try stream.receive(Self.cc(0, 38, 3), at: 5 * Self.msec)
            == UMPTranslationOutput(messages: [try Self.mpe(15), try Self.mpe(15, lsb: 3)], losses: []))
        #expect(stream.idleFlushes == 1)
        #expect(stream.deadline == nil)
        // Polled first: the CC 38 alone sends the completed value, exactly as the bare translator does after
        // flushAll().
        var polled = UMPTranslationStream()
        try Self.selectMPE(&polled, at: 0)
        _ = try polled.receive(Self.cc(0, 6, 15), at: 0)
        #expect(try polled.poll(at: 9 * Self.msec) == [try Self.mpe(15)])
        var bare = UMPMIDI1ToMIDI2Translator()
        for (controller, value) in [(UInt8(101), UInt8(0)), (100, 6), (6, 15)] {
            _ = try bare.translate(Self.cc(0, controller, value))
        }
        #expect(bare.flushAll() == [try Self.mpe(15)])
        let late = try polled.receive(Self.cc(0, 38, 3), at: 9 * Self.msec)
        #expect(late == UMPTranslationOutput(messages: [try Self.mpe(15, lsb: 3)], losses: []))
        #expect(late == (try bare.translate(Self.cc(0, 38, 3))))
        #expect(polled.translator == bare)
        #expect(polled.idleFlushes == 1)
        #expect(polled.losses.total == 0)
    }

    @Test func anyOtherMessageAtOrAfterTheDeadlineSendsTheHeldDataEntryFirst() throws {
        let loss = UMPTranslationLoss(reason: .dataEntryWithoutParameter, group: try UMPGroup(0),
                                      channel: try UMPChannel(1))
        let program = try Self.mt4(0, 0, .programChange(program: UMPSevenBit(7), bank: nil))
        let sixteen = try Self.mpe(16)
        // Only the new CC 6 stays held after the flush.
        let newDataEntry = try Self.cc(0, 6, 16)
        let cases: [(UMPMIDI1ChannelVoice, UMPTranslationOutput<UMPMIDI2ChannelVoice>)] = [
            (try Self.noteOn(2, 60, group: 1), UMPTranslationOutput(
                messages: [try Self.mpe(15), try Self.noteOnMT4(2, 60, group: 1)], losses: [])),
            (try UMPMIDI1ChannelVoice(group: UMPGroup(0), event: .channel(status: 0xC0, data1: 7, data2: nil)),
             UMPTranslationOutput(messages: [try Self.mpe(15), program], losses: [])),
            (try Self.cc(0, 101, 1), UMPTranslationOutput(messages: [try Self.mpe(15)], losses: [])),
            (try Self.cc(1, 38, 2), UMPTranslationOutput(messages: [try Self.mpe(15)], losses: [loss])),
            (newDataEntry, UMPTranslationOutput(messages: [try Self.mpe(15)], losses: []))
        ]
        for (voice, expected) in cases {
            let held = voice == newDataEntry
            for time in [5 * Self.msec, 8 * Self.msec] {
                var stream = UMPTranslationStream()
                try Self.selectMPE(&stream, at: 0)
                _ = try stream.receive(Self.cc(0, 6, 15), at: 0)
                #expect(try stream.receive(voice, at: time) == expected, "\(voice.event) at \(time)")
                #expect(stream.idleFlushes == 1)
                #expect(stream.deadline == (held ? time + 5 * Self.msec : nil))
                #expect(stream.translator.heldDataEntry == (held ? sixteen : nil))
            }
        }
        // One nanosecond before the deadline the translator sends the held CC 6 itself: same order, no idle flush.
        var early = UMPTranslationStream()
        try Self.selectMPE(&early, at: 0)
        _ = try early.receive(Self.cc(0, 6, 15), at: 0)
        #expect(try early.receive(Self.noteOn(2, 60, group: 1), at: 5 * Self.msec - 1).messages
            == [try Self.mpe(15), try Self.noteOnMT4(2, 60, group: 1)])
        #expect(early.idleFlushes == 0)
        #expect(early.deadline == nil)
    }

    @Test func aNewDataEntryRestartsTheDeadline() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 0)
        _ = try stream.receive(Self.cc(0, 6, 10), at: 0)
        #expect(stream.deadline == 5 * Self.msec)
        // The translator sends the first CC 6 itself before holding the second.
        #expect(try stream.receive(Self.cc(0, 6, 11), at: 3 * Self.msec).messages == [try Self.mpe(10)])
        #expect(stream.deadline == 8 * Self.msec)
        #expect(try stream.poll(at: 5 * Self.msec).isEmpty)
        #expect(try stream.poll(at: 8 * Self.msec - 1).isEmpty)
        #expect(try stream.poll(at: 8 * Self.msec) == [try Self.mpe(11)])
        #expect(stream.idleFlushes == 1)
    }

    @Test func aTimeEarlierThanTheLastAcceptedOneIsRefusedAndChangesNothing() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 10 * Self.msec)
        _ = try stream.receive(Self.cc(0, 6, 15), at: 20 * Self.msec)
        let before = stream
        let refusal = UMPTranslationStreamRefusal.timeWentBackward(previous: 20 * Self.msec, got: 20 * Self.msec - 1)
        #expect(throws: refusal) {
            try stream.receive(Self.noteOn(0, 60), at: 20 * Self.msec - 1)
        }
        #expect(stream == before)
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 20 * Self.msec, got: 0)) {
            try stream.poll(at: 0)
        }
        #expect(stream == before)
        // An accepted poll moves the baseline.
        #expect(try stream.poll(at: 22 * Self.msec).isEmpty)
        #expect(stream.lastAcceptedTime == 22 * Self.msec)
        let polled = stream
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 22 * Self.msec, got: 21 * Self.msec)) {
            try stream.receive(Self.cc(0, 38, 1), at: 21 * Self.msec)
        }
        #expect(stream == polled)
        // The refused CC 38 did not complete the held CC 6; an accepted one does.
        #expect(try stream.receive(Self.cc(0, 38, 1), at: 22 * Self.msec).messages == [try Self.mpe(15, lsb: 1)])
        #expect(stream.losses.total == 0)
    }

    @Test func equalTimestampsAreAccepted() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 7 * Self.msec)
        _ = try stream.receive(Self.cc(0, 6, 15), at: 7 * Self.msec)
        #expect(try stream.poll(at: 7 * Self.msec).isEmpty)
        #expect(try stream.receive(Self.cc(0, 38, 3), at: 7 * Self.msec).messages == [try Self.mpe(15, lsb: 3)])
        _ = try stream.receive(Self.cc(0, 6, 4), at: 7 * Self.msec)
        #expect(try stream.poll(at: 12 * Self.msec) == [try Self.mpe(4)])
        #expect(try stream.poll(at: 12 * Self.msec).isEmpty)
        #expect(try stream.receive(Self.noteOn(0, 60), at: 12 * Self.msec).messages == [try Self.noteOnMT4(0, 60)])
        #expect(stream.lastAcceptedTime == 12 * Self.msec)
    }

    @Test func pollWithNothingHeldSendsNothing() throws {
        var stream = UMPTranslationStream()
        #expect(try stream.poll(at: 0).isEmpty)
        #expect(stream.lastAcceptedTime == 0)
        #expect(try stream.poll(at: UInt64.max).isEmpty)
        #expect(stream.lastAcceptedTime == UInt64.max)
        #expect(stream.deadline == nil)
        #expect(stream.idleFlushes == 0)
        // A CC 6 with no parameter selected declares a loss and holds nothing.
        var lone = UMPTranslationStream()
        let output = try lone.receive(Self.cc(0, 6, 1), at: 0)
        #expect(output == UMPTranslationOutput(messages: [], losses: [UMPTranslationLoss(
            reason: .dataEntryWithoutParameter, group: try UMPGroup(0), channel: try UMPChannel(0))]))
        #expect(lone.deadline == nil)
        #expect(try lone.poll(at: 5 * Self.msec).isEmpty)
        #expect(lone.losses.count(.dataEntryWithoutParameter) == 1)
        #expect(lone.losses == lone.translator.losses)
        #expect(lone.idleFlushes == 0)
    }

    @Test func timeoutBoundaries() throws {
        #expect(UMPTranslationStreamTimeout.allowedNanoseconds == 1_000_000...100_000_000)
        #expect(try Self.timeout(1_000_000).nanoseconds == 1_000_000)
        #expect(try Self.timeout(100_000_000).nanoseconds == 100_000_000)
        #expect(UMPTranslationStreamTimeout.standard.nanoseconds == 5_000_000)
        #expect(try Self.timeout(5_000_000) == .standard)
        #expect(UMPTranslationStream().timeout == .standard)
        for refused: UInt64 in [0, 1_000_000 - 1, 100_000_000 + 1, UInt64.max] {
            #expect(throws: UMPTranslationStreamRefusal.timeoutOutOfRange(nanoseconds: refused)) {
                try Self.timeout(refused)
            }
        }
    }

    @Test func aDeadlinePastUInt64MaxIsRefusedAndChangesNothing() throws {
        let timeout = 5 * Self.msec
        var selected = UMPTranslationStream()
        try Self.selectMPE(&selected, at: 0)
        // The latest hold whose deadline fits ends exactly at UInt64.max.
        var fits = selected
        #expect(try fits.receive(Self.cc(0, 6, 15), at: UInt64.max - timeout) == Self.empty)
        #expect(fits.deadline == UInt64.max)
        #expect(try fits.poll(at: UInt64.max - 1).isEmpty)
        #expect(try fits.poll(at: UInt64.max) == [try Self.mpe(15)])
        // One nanosecond later the deadline would wrap: refused, nothing changes.
        var late = selected
        for heldAt in [UInt64.max - timeout + 1, UInt64.max] {
            #expect(throws: UMPTranslationStreamRefusal.deadlineOverflow(heldAt: heldAt, timeoutNanoseconds: timeout)) {
                try late.receive(Self.cc(0, 6, 15), at: heldAt)
            }
            #expect(late == selected)
        }
        // A message that holds nothing has no deadline and is accepted at UInt64.max.
        #expect(try late.receive(Self.noteOn(0, 60), at: UInt64.max).messages == [try Self.noteOnMT4(0, 60)])
        // A refused call does not perform the idle flush it was due: the CC 6 stays held for the next call.
        var due = selected
        _ = try due.receive(Self.cc(0, 6, 1), at: 0)
        let dueBefore = due
        #expect(throws: UMPTranslationStreamRefusal.deadlineOverflow(heldAt: UInt64.max, timeoutNanoseconds: timeout)) {
            try due.receive(Self.cc(0, 6, 2), at: UInt64.max)
        }
        #expect(due == dueBefore)
        #expect(due.idleFlushes == 0)
        #expect(try due.poll(at: UInt64.max) == [try Self.mpe(1)])
        #expect(due.idleFlushes == 1)
    }

    @Test func resetSendsTheHeldDataEntryAndStartsANewStream() throws {
        let timeout = try Self.timeout(2 * Self.msec)
        var stream = UMPTranslationStream(timeout: timeout)
        try Self.selectMPE(&stream, at: 10 * Self.msec)
        _ = try stream.receive(Self.cc(0, 96, 0), at: 10 * Self.msec)
        // One idle flush and one end-of-stream flush before the reset.
        _ = try stream.receive(Self.cc(0, 6, 13), at: 10 * Self.msec)
        #expect(try stream.poll(at: 12 * Self.msec) == [try Self.mpe(13)])
        _ = try stream.receive(Self.cc(0, 6, 14), at: 12 * Self.msec)
        #expect(stream.endOfStream() == [try Self.mpe(14)])
        _ = try stream.receive(Self.cc(0, 6, 15), at: 20 * Self.msec)
        #expect(stream.losses.count(.dataIncrementUnmapped) == 1)
        #expect(stream.reset() == [try Self.mpe(15)])
        #expect(stream.resetFlushes == 1)
        #expect(stream.idleFlushes == 1)
        #expect(stream.endOfStreamFlushes == 1)
        // A new stream with the same timeout; only the cumulative telemetry is kept.
        #expect(stream.translator == UMPMIDI1ToMIDI2Translator())
        #expect(stream.timeout == timeout)
        #expect(stream.deadline == nil)
        #expect(stream.lastAcceptedTime == nil)
        #expect(stream.losses.count(.dataIncrementUnmapped) == 1)
        #expect(stream.translator.losses.total == 0)
        #expect(stream.reset().isEmpty)
        #expect(stream.resetFlushes == 1)
        // The selection was forgotten, and any start time is accepted.
        #expect(try stream.receive(Self.cc(0, 6, 1), at: 0).losses == [UMPTranslationLoss(
            reason: .dataEntryWithoutParameter, group: try UMPGroup(0), channel: try UMPChannel(0))])
        #expect(stream.losses.total == 2)
        #expect(stream.deadline == nil)
    }

    @Test func resetOfOneGroupAndChannelSendsADataEntryHeldOnIt() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 0, channel: 4, group: 2)
        try Self.selectMPE(&stream, at: 0, channel: 3, group: 2)
        _ = try stream.receive(Self.cc(3, 6, 15, group: 2), at: Self.msec)
        // Another channel: nothing sent, the held CC 6 and its deadline stay.
        #expect(stream.reset(group: try UMPGroup(2), channel: try UMPChannel(5)).isEmpty)
        #expect(stream.deadline == 6 * Self.msec)
        #expect(stream.translator.heldDataEntry == (try Self.mpe(15, channel: 3, group: 2)))
        #expect(stream.resetFlushes == 0)
        #expect(stream.reset(group: try UMPGroup(2), channel: try UMPChannel(3))
            == [try Self.mpe(15, channel: 3, group: 2)])
        #expect(stream.resetFlushes == 1)
        #expect(stream.deadline == nil)
        #expect(stream.translator.heldDataEntry == nil)
        // The time baseline is kept.
        #expect(stream.lastAcceptedTime == Self.msec)
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: Self.msec, got: 0)) {
            try stream.poll(at: 0)
        }
        #expect(try stream.poll(at: 1_000 * Self.msec).isEmpty)
        #expect(stream.idleFlushes == 0)
        // Channel 3 was forgotten; channel 4 keeps its selection, so its CC 6 is held with a new deadline.
        #expect(stream.translator.state(group: try UMPGroup(2), channel: try UMPChannel(3)) == UMPUpChannelState())
        #expect(try stream.receive(Self.cc(4, 6, 2, group: 2), at: 1_000 * Self.msec) == Self.empty)
        #expect(stream.deadline == 1_005 * Self.msec)
        #expect(stream.reset(group: try UMPGroup(2), channel: try UMPChannel(4))
            == [try Self.mpe(2, channel: 4, group: 2)])
        #expect(stream.resetFlushes == 2)
        #expect(stream.deadline == nil)
    }
}
