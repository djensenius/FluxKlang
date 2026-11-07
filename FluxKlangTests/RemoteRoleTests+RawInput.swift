import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteRoleTests {
    @Test func notesAndPolyphonicPressureAreRefusedRawNotes() throws {
        let notes: [MIDI1Semantic] = [
            .noteOff(channel: 1, note: 60, velocity: 0), .noteOn(channel: 16, note: 127, velocity: 127),
            .polyphonicPressure(channel: 3, note: 0, pressure: 64)
        ]
        for semantic in notes { #expect(RemoteRoleGuard.classify(semantic) == .refusedRawNote) }
    }

    @Test func aNoteOnWithVelocityZeroArrivesAsNoteOffAndIsARawNote() throws {
        let semantic = try #require(MIDI1Event.channel(status: 0x90, data1: 60, data2: 0).semantic)
        #expect(semantic == .noteOff(channel: 1, note: 60, velocity: 64))
        #expect(RemoteRoleGuard.classify(semantic) == .refusedRawNote)
        let loud = try #require(MIDI1Event.channel(status: 0x9F, data1: 60, data2: 1).semantic)
        #expect(RemoteRoleGuard.classify(loud) == .refusedRawNote)
    }

    @Test func clockStartContinueAndStopAreRefusedRawClocks() throws {
        for status: UInt8 in [0xF8, 0xFA, 0xFB, 0xFC] {
            #expect(RemoteRoleGuard.classify(.realTime(status: status)) == .refusedRawClock)
        }
    }

    @Test func everyOtherRealTimeByteAndTheEdgesAroundTheClockBytesAreRefusedRawOther() throws {
        for status: UInt8 in [0xF9, 0xFD, 0xFE, 0xFF, 0xF7, 0x00] {
            #expect(RemoteRoleGuard.classify(.realTime(status: status)) == .refusedRawOther)
        }
    }

    @Test func theRealTimeBytesF8ToFFClassifyExactlyAsDocumented() throws {
        let classes = (UInt8(0xF8)...UInt8(0xFF)).map { RemoteRoleGuard.classify(.realTime(status: $0)) }
        #expect(classes == [
            .refusedRawClock, .refusedRawOther, .refusedRawClock, .refusedRawClock,
            .refusedRawClock, .refusedRawOther, .refusedRawOther, .refusedRawOther
        ])
    }

    @Test func systemCommonAndSystemExclusiveAreRefusedRawOther() throws {
        let others: [MIDI1Semantic] = [
            .systemCommon(status: 0xF1, data1: 0x10, data2: nil), .systemCommon(status: 0xF2, data1: 1, data2: 2),
            .systemCommon(status: 0xF3, data1: 5, data2: nil), .systemCommon(status: 0xF6, data1: nil, data2: nil),
            .sysEx(payload: []), .sysEx(payload: [0x7E, 0x7F])
        ]
        for semantic in others { #expect(RemoteRoleGuard.classify(semantic) == .refusedRawOther) }
    }

    @Test func controlChangeAndTheOtherBindableMessagesNeedBinding() throws {
        let bindable: [MIDI1Semantic] = [
            .controlChange(channel: 1, controller: 7, value: 100), .programChange(channel: 2, program: 5),
            .channelPressure(channel: 3, pressure: 9), .pitchBend(channel: 4, value: 8_192)
        ]
        for semantic in bindable { #expect(RemoteRoleGuard.classify(semantic) == .needsBinding) }
    }

    @Test func noWireNoteOrClockMessageCanEverNeedBinding() throws {
        for channel in 0..<16 {
            for note in [0, 1, 60, 127] {
                for velocity in [0, 1, 64, 127] {
                    for family in [0x80, 0x90, 0xA0] {
                        let event = MIDI1Event.channel(
                            status: UInt8(family + channel), data1: UInt8(note), data2: UInt8(velocity)
                        )
                        let semantic = try #require(event.semantic)
                        #expect(RemoteRoleGuard.classify(semantic) == .refusedRawNote)
                    }
                }
            }
        }
        for status in 0xF8...0xFF {
            let semantic = try #require(MIDI1Event.realTime(status: UInt8(status)).semantic)
            #expect(RemoteRoleGuard.classify(semantic) != .needsBinding)
        }
    }

    @Test func aControlChangeFromTheWireNeedsBindingAndIsNeverRawInput() throws {
        let semantic = try #require(MIDI1Event.channel(status: 0xB0, data1: 7, data2: 0).semantic)
        #expect(semantic == .controlChange(channel: 1, controller: 7, value: 0))
        #expect(RemoteRoleGuard.classify(semantic) == .needsBinding)
    }

    @Test func rawInputClassesAreExactlyTheFourDocumentedOnes() throws {
        #expect(RawInputClass.allCases == [.refusedRawNote, .refusedRawClock, .refusedRawOther, .needsBinding])
    }
}
