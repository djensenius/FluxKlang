import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - System Common and System Real Time messages (MT 0x1)

extension UMPTranslationStreamTests {
    /// One MT 0x1 message per System Real Time status (0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF) on group 0, as words.
    static let realTimeWords: [UInt32] = [0x10F8_0000, 0x10FA_0000, 0x10FB_0000, 0x10FC_0000, 0x10FE_0000, 0x10FF_0000]
    /// One MT 0x1 message per System Common status (0xF1 piece 3 nibble 2, 0xF2 beat 257, 0xF3 song 5, 0xF6) on
    /// group 0, as words.
    static let commonWords: [UInt32] = [0x10F1_3200, 0x10F2_0102, 0x10F3_0500, 0x10F6_0000]

    static func system(_ word: UInt32, group: UInt8 = 0) throws -> UMPSystemCommonRealTime {
        try UMPSystemCommonRealTime(decoding: .system(word & 0xF0FF_FFFF | UInt32(group) << 24))
    }

    /// A stream holding CC 6 value 15 (RPN 0/6) on group 0, channel 0, received at 0: its deadline is 5 ms.
    static func holding() throws -> UMPTranslationStream {
        var stream = UMPTranslationStream()
        try selectMPE(&stream, at: 0)
        #expect(try stream.receive(cc(0, 6, 15), at: 0) == empty)
        return stream
    }

    @Test(arguments: realTimeWords)
    func realTimeBetweenDataEntryMSBAndLSBStillCompletesThePair(word: UInt32) throws {
        for group: UInt8 in [0, 5] {
            var stream = try Self.holding()
            let realTime = try Self.system(word, group: group)
            // Passed through at once; the CC 6 stays held with its own deadline.
            #expect(try stream.receive(system: realTime, at: Self.msec) == [.system(realTime)])
            #expect(stream.translator.heldDataEntry == (try Self.mpe(15)))
            #expect(stream.deadline == 5 * Self.msec)
            #expect(stream.lastAcceptedTime == Self.msec)
            #expect(try stream.receive(system: realTime, at: 2 * Self.msec) == [.system(realTime)])
            // One controller, with the LSB; nothing was flushed.
            #expect(try stream.receive(Self.cc(0, 38, 3), at: 3 * Self.msec).messages == [try Self.mpe(15, lsb: 3)])
            #expect(stream.deadline == nil)
            #expect(stream.idleFlushes == 0)
            #expect(stream.endOfStreamFlushes == 0)
            #expect(stream.resetFlushes == 0)
            #expect(stream.losses.total == 0)
        }
    }

    @Test(arguments: commonWords)
    func systemCommonSendsTheHeldDataEntryFirst(word: UInt32) throws {
        // The held CC 6 is one slot across groups and channels, so a System Common on any group sends it.
        for (group, channel) in [(UInt8(0), UInt8(0)), (2, 3)] {
            var stream = UMPTranslationStream()
            try Self.selectMPE(&stream, at: 0, channel: channel, group: group)
            _ = try stream.receive(Self.cc(channel, 6, 15, group: group), at: 0)
            let common = try Self.system(word, group: 9)
            let sent = try stream.receive(system: common, at: 5 * Self.msec - 1)
            #expect(sent == [.voice(try Self.mpe(15, channel: channel, group: group)), .system(common)])
            #expect(stream.translator.heldDataEntry == nil)
            #expect(stream.deadline == nil)
            // The translator's own flush, as before a Note On: no flush telemetry.
            #expect(stream.idleFlushes == 0)
            #expect(stream.endOfStreamFlushes == 0)
            #expect(stream.resetFlushes == 0)
            #expect(try stream.poll(at: 10 * Self.msec).isEmpty)
            // A CC 38 after it is late: the controller is sent again with the kept MSB and the LSB.
            #expect(try stream.receive(Self.cc(channel, 38, 3, group: group), at: 10 * Self.msec).messages
                == [try Self.mpe(15, lsb: 3, channel: channel, group: group)])
            #expect(stream.losses.total == 0)
        }
    }

    @Test func realTimeBetweenAnIdleFlushAndALateDataEntryLSBKeepsItLate() throws {
        var stream = try Self.holding()
        #expect(try stream.poll(at: 5 * Self.msec) == [try Self.mpe(15)])
        #expect(stream.idleFlushes == 1)
        let clock = try Self.system(0x10F8_0000, group: 3)
        #expect(try stream.receive(system: clock, at: 6 * Self.msec) == [.system(clock)])
        #expect(stream.deadline == nil)
        // The CC 38 is still late: the controller is sent again with the kept MSB and the new LSB, with no loss.
        #expect(try stream.receive(Self.cc(0, 38, 3), at: 7 * Self.msec)
            == UMPTranslationOutput(messages: [try Self.mpe(15, lsb: 3)], losses: []))
        #expect(stream.idleFlushes == 1)
        #expect(stream.deadline == nil)
        #expect(stream.losses.total == 0)
    }

    @Test func anySystemMessageAtOrAfterTheDeadlineSendsTheHeldDataEntryAsAnIdleFlush() throws {
        for word in Self.realTimeWords + Self.commonWords {
            let message = try Self.system(word, group: 4)
            for time in [5 * Self.msec, 8 * Self.msec] {
                var stream = try Self.holding()
                #expect(try stream.receive(system: message, at: time) == [.voice(try Self.mpe(15)), .system(message)],
                        "\(word) at \(time)")
                #expect(stream.idleFlushes == 1)
                #expect(stream.deadline == nil)
                #expect(stream.translator.heldDataEntry == nil)
                #expect(stream.lastAcceptedTime == time)
                #expect(try stream.poll(at: time).isEmpty)
                #expect(stream.idleFlushes == 1)
            }
        }
        // One nanosecond earlier a Real Time message leaves the CC 6 held; the deadline still sends it.
        var stream = try Self.holding()
        let clock = try Self.system(0x10F8_0000)
        #expect(try stream.receive(system: clock, at: 5 * Self.msec - 1) == [.system(clock)])
        #expect(stream.idleFlushes == 0)
        #expect(stream.deadline == 5 * Self.msec)
        #expect(try stream.poll(at: 5 * Self.msec) == [try Self.mpe(15)])
        #expect(stream.idleFlushes == 1)
    }

    @Test func aSystemMessageAtAnEarlierTimeIsRefusedAndChangesNothing() throws {
        var stream = UMPTranslationStream()
        try Self.selectMPE(&stream, at: 10 * Self.msec)
        _ = try stream.receive(Self.cc(0, 6, 15), at: 20 * Self.msec)
        let before = stream
        let refusal = UMPTranslationStreamRefusal.timeWentBackward(previous: 20 * Self.msec, got: 20 * Self.msec - 1)
        for word in Self.realTimeWords + Self.commonWords {
            let message = try Self.system(word)
            #expect(throws: refusal) {
                try stream.receive(system: message, at: 20 * Self.msec - 1)
            }
            #expect(stream == before, "\(word)")
        }
        // Equal times are accepted; Real Time leaves the held CC 6 and its deadline.
        let clock = try Self.system(0x10F8_0000)
        #expect(try stream.receive(system: clock, at: 20 * Self.msec) == [.system(clock)])
        #expect(stream.translator == before.translator)
        #expect(stream.deadline == before.deadline)
        // An accepted system message moves the baseline.
        #expect(try stream.receive(system: clock, at: 22 * Self.msec) == [.system(clock)])
        #expect(stream.lastAcceptedTime == 22 * Self.msec)
        let moved = stream
        #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 22 * Self.msec, got: 21 * Self.msec)) {
            try stream.receive(Self.cc(0, 38, 1), at: 21 * Self.msec)
        }
        #expect(stream == moved)
        #expect(try stream.receive(Self.cc(0, 38, 1), at: 22 * Self.msec).messages == [try Self.mpe(15, lsb: 1)])
    }

    @Test func eachSystemStatusPassesThroughUnchangedWithItsGroup() throws {
        var stream = UMPTranslationStream()
        var time: UInt64 = 0
        for word in Self.realTimeWords + Self.commonWords {
            for group: UInt8 in [0, 7, 15] {
                let message = try Self.system(word, group: group)
                let sent = try stream.receive(system: message, at: time)
                #expect(sent == [.system(message)], "\(word) group \(group)")
                guard case let .system(passed) = try #require(sent.first) else {
                    Issue.record("\(word) group \(group) was not passed through")
                    continue
                }
                #expect(passed.group == (try UMPGroup(group)))
                #expect(passed.packet == UMPPacket.system(word & 0xF0FF_FFFF | UInt32(group) << 24))
                time += Self.msec
            }
        }
        #expect(stream.translator == UMPMIDI1ToMIDI2Translator())
        #expect(stream.deadline == nil)
        #expect(stream.idleFlushes + stream.endOfStreamFlushes + stream.resetFlushes == 0)
        #expect(stream.losses.total == 0)
    }

    @Test func systemResetIsPassedThroughAndDoesNotResetTheStream() throws {
        var stream = try Self.holding()
        let reset = try Self.system(0x10FF_0000)
        #expect(try stream.receive(system: reset, at: Self.msec) == [.system(reset)])
        #expect(stream.translator.heldDataEntry == (try Self.mpe(15)))
        #expect(stream.lastAcceptedTime == Self.msec)
        #expect(stream.translator.state(group: try UMPGroup(0), channel: try UMPChannel(0)).parameter != nil)
        // The I/O layer decides to reset: the held CC 6 is sent and the stream starts again.
        #expect(stream.reset() == [try Self.mpe(15)])
        #expect(stream.resetFlushes == 1)
        #expect(stream.translator == UMPMIDI1ToMIDI2Translator())
        #expect(try stream.receive(system: reset, at: 0) == [.system(reset)])
        #expect(stream.lastAcceptedTime == 0)
    }

    @Test func endOfStreamAfterSystemMessages() throws {
        var stream = try Self.holding()
        let clock = try Self.system(0x10F8_0000)
        let tune = try Self.system(0x10F6_0000)
        // After Real Time the CC 6 is still held, so the end of the segment sends it.
        _ = try stream.receive(system: clock, at: Self.msec)
        #expect(stream.endOfStream() == [try Self.mpe(15)])
        #expect(stream.endOfStreamFlushes == 1)
        #expect(stream.lastAcceptedTime == nil)
        // The next segment may start earlier; after System Common nothing is left to send.
        #expect(try stream.receive(Self.cc(0, 6, 3), at: 0) == Self.empty)
        #expect(try stream.receive(system: tune, at: 0) == [.voice(try Self.mpe(3)), .system(tune)])
        #expect(stream.endOfStream().isEmpty)
        #expect(stream.endOfStreamFlushes == 1)
        #expect(stream.idleFlushes == 0)
        #expect(stream.resetFlushes == 0)
        #expect(stream.losses.total == 0)
    }
}
