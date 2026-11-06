import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Standard MIDI File reader")
struct StandardMIDIFileReaderTests {
    typealias SMF = StandardMIDIFileTests
    typealias Clip = MIDIClipTimingTests
    static let quarter = MusicalTime.ticksPerQuarter
    static let end: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

    @Test
    func runningStatusAndNoteOnVelocityZeroAreReadAtTheFileDivision() throws {
        // Division 960: each file tick is 16 clip ticks. Velocity-0 Note Ons release with velocity 64.
        let events: [UInt8] = [0x00, 0x91, 0x3C, 0x64, 0x60, 0x3E, 0x50, 0x60, 0x3C, 0x00, 0x00, 0x3E, 0x00,
                               0x00, 0xE1, 0x7F, 0x7F, 0x83, 0x60, 0x7F, 0x00]
        let read = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(events, endDelta: [0x10])]))
        let expected = try MIDIClip.make(lengthTicks: (96 + 96 + 480 + 16) * 16, items: [
            Clip.note(0, 192 * 16, channel: 2),
            Clip.note(96 * 16, 192 * 16, pitch: 62, channel: 2, velocity: 0x50),
            .event(ticks: 192 * 16, message: .pitchBend(channel: 2, value: 0x3FFF)),
            .event(ticks: 672 * 16, message: .pitchBend(channel: 2, value: 0x7F))
        ])
        #expect(read.clip == expected)
        #expect(read.report.division == 960)
    }

    @Test
    func metaEventsAreCountedByKindAndNeverConverted() throws {
        let metas: [UInt8] = [
            0x00, 0xFF, 0x00, 0x02, 0x00, 0x01, 0x00, 0xFF, 0x03, 0x04, 0x4C, 0x65, 0x61, 0x64,
            0x00, 0xFF, 0x06, 0x01, 0x41, 0x00, 0xFF, 0x20, 0x01, 0x00, 0x00, 0xFF, 0x21, 0x01, 0x00,
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xFF, 0x54, 0x05, 0x60, 0x00, 0x00, 0x00, 0x00,
            0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08, 0x00, 0xFF, 0x59, 0x02, 0x00, 0x00,
            0x00, 0xFF, 0x7F, 0x02, 0x00, 0x41, 0x00, 0xFF, 0x60, 0x00, 0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40
        ]
        let read = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(metas + [0x00, 0x90, 0x3C, 0x64,
                                                                                  0x78, 0x80, 0x3C, 0x40])]))
        #expect(read.clip == (try MIDIClip.make(lengthTicks: 120 * 16, items: [Clip.note(0, 120 * 16)])))
        #expect(read.report.ignoredMeta == [
            .sequenceNumber: 1, .text: 2, .channelPrefix: 1, .port: 1, .tempo: 2, .smpteOffset: 1,
            .timeSignature: 1, .keySignature: 1, .sequencerSpecific: 1, .other(type: 0x60): 1
        ])
        #expect(SMFMetaKind(type: 0x0F) == .text)
        #expect(SMFMetaKind(type: 0x10) == .other(type: 0x10))
        #expect(SMFMetaKind(type: 0x2F) == .other(type: 0x2F))
    }

    @Test
    func metaEventsCancelRunningStatus() {
        let events: [UInt8] = [0x00, 0xB0, 0x07, 0x10, 0x00, 0xFF, 0x01, 0x00, 0x00, 0x07, 0x20]
        #expect(SMF.refusal(SMF.file(chunks: [SMF.track(events)])) == .missingRunningStatus(track: 0, offset: 31))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.track([0x00, 0x3C, 0x64])])) ==
            .missingRunningStatus(track: 0, offset: 23))
    }

    @Test
    func unknownChunksAndExtraHeaderBytesAreSkippedAndCounted() throws {
        let note = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        let bytes = SMF.file(headerExtra: [0xAA, 0xBB], chunks: [SMF.chunk("XFIH", [1, 2, 3]), note,
                                                                 SMF.chunk("mtrk", [])])
        let read = try StandardMIDIFile.read(bytes)
        #expect(read.clip == (try MIDIClip.make(lengthTicks: 16, items: [Clip.note(0, 16)])))
        #expect(read.report == SMFReadReport(format: 0, division: 960, tracks: 1, ignoredMeta: [:],
                                             unknownChunks: 2, ignoredHeaderBytes: 2))
    }

    @Test
    func headersAndChunksAreChecked() {
        let note = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        #expect(SMF.refusal([]) == .missingHeader)
        #expect(SMF.refusal(Array(SMF.file(chunks: [note]).prefix(7))) == .missingHeader)
        #expect(SMF.refusal(note + SMF.file(chunks: [note])) == .missingHeader)
        #expect(SMF.refusal(SMF.chunk("MThd", [0, 0, 0, 1, 0x03]) + note) == .missingHeader)
        #expect(SMF.refusal(SMF.file(chunks: [note]) + [0x4D, 0x54, 0x72]) == .truncated(offset: 34))
        #expect(SMF.refusal(SMF.file(chunks: [note]).dropLast()) == .chunkOverrunsFile(offset: 14, length: 12))
        #expect(SMF.refusal(SMF.file(format: 2, chunks: [note])) == .unsupportedFormat(2))
        #expect(SMF.refusal(SMF.file(format: 3, chunks: [note])) == .unsupportedFormat(3))
        #expect(SMF.refusal(SMF.file(division: 0xE728, chunks: [note])) == .smpteDivision(0xE728))
        #expect(SMF.refusal(SMF.file(division: 0x8000, chunks: [note])) == .smpteDivision(0x8000))
        #expect(SMF.refusal(SMF.file(division: 1000, chunks: [note])) == .unsupportedDivision(1000))
        #expect(SMF.refusal(SMF.file(division: 0, chunks: [note])) == .unsupportedDivision(0))
        #expect(SMF.refusal(SMF.file(division: 30_720, chunks: [note])) == .unsupportedDivision(30_720))
        #expect(SMF.refusal(SMF.file(tracks: 0, chunks: [])) == .trackCountOutOfRange(declared: 0, limit: 64))
        #expect(SMF.refusal(SMF.file(format: 1, tracks: 0, chunks: [])) ==
            .trackCountOutOfRange(declared: 0, limit: 64))
        #expect(SMF.refusal(SMF.file(tracks: 2, chunks: [note, note])) == .trackCountOutOfRange(declared: 2, limit: 64))
        #expect(SMF.refusal(SMF.file(format: 1, tracks: 2, chunks: [note])) ==
            .trackCountMismatch(declared: 2, found: 1))
        #expect(SMF.refusal(SMF.file(chunks: [note, note])) == .trackCountMismatch(declared: 1, found: 2))
        for division: UInt16 in [1, 96, 120, 480, 960, 15_360] {
            #expect(SMF.refusal(SMF.file(division: division, chunks: [note])) == nil)
        }
    }

    @Test
    func readsAreBounded() throws {
        let note = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        let bytes = SMF.file(chunks: [note])
        #expect(SMF.refusal(bytes, limits: SMFReadLimits(maximumFileBytes: 33)) == .fileTooLarge(bytes: 34, limit: 33))
        #expect(SMF.refusal(bytes, limits: SMFReadLimits(maximumFileBytes: 34)) == nil)
        #expect(SMF.refusal(bytes, limits: SMFReadLimits(maximumEvents: 2)) == .tooManyEvents(limit: 2))
        #expect(SMF.refusal(bytes, limits: SMFReadLimits(maximumEvents: 3)) == nil)
        let three = SMF.file(format: 1, tracks: 3, chunks: [note, SMF.track([]), SMF.track([])])
        #expect(SMF.refusal(three, limits: SMFReadLimits(maximumEvents: 4)) == .tooManyEvents(limit: 4))
        #expect(SMF.refusal(three, limits: SMFReadLimits(maximumTracks: 2)) == .trackCountOutOfRange(declared: 3,
                                                                                                      limit: 2))
        #expect(SMF.refusal(three, limits: SMFReadLimits(maximumTracks: 3)) == nil)
        #expect(SMFReadLimits.standard == SMFReadLimits(maximumFileBytes: 4 << 20, maximumTracks: 64,
                                                        maximumEvents: 65_536))
        // 4096 file ticks at division 1 is exactly the maximum clip length; one more is past it.
        let atLimit = SMF.file(division: 1, chunks: [SMF.track([], endDelta: [0xA0, 0x00])])
        #expect(try StandardMIDIFile.read(atLimit).clip.lengthTicks == MIDIClip.maximumLengthTicks)
        let past = SMF.file(division: 1, chunks: [SMF.track([0x9F, 0x7F, 0xC0, 0x05], endDelta: [0x02])])
        #expect(SMF.refusal(past) == .timeBeyondLimit(track: 0, ticks: 4097 * Self.quarter))
        let farthest = SMF.file(division: 1, chunks: [SMF.track([], endDelta: [0xFF, 0xFF, 0xFF, 0x7F])])
        #expect(SMF.refusal(farthest) == .timeBeyondLimit(track: 0, ticks: 0x0FFF_FFFF * Self.quarter))
    }

    @Test
    func eventsAndTracksAreChecked() {
        func refusal(_ events: [UInt8], endDelta: [UInt8] = [0x00]) -> SMFRefusal? {
            SMF.refusal(SMF.file(chunks: [SMF.track(events, endDelta: endDelta)]))
        }
        #expect(refusal([0x00, 0xF0, 0x02, 0x7E, 0xF7]) == .sysExNotRepresentable(track: 0, ticks: 0))
        #expect(refusal([0x01, 0xF7, 0x01, 0xF8]) == .sysExNotRepresentable(track: 0, ticks: 16))
        #expect(refusal([0x00, 0xF1, 0x00]) == .invalidStatus(track: 0, offset: 23, status: 0xF1))
        #expect(refusal([0x00, 0xFE]) == .invalidStatus(track: 0, offset: 23, status: 0xFE))
        #expect(refusal([0x00, 0x90, 0x3C, 0x80]) == .invalidDataByte(track: 0, offset: 24))
        #expect(refusal([0x00, 0xC0, 0x80]) == .invalidDataByte(track: 0, offset: 24))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0x90, 0x3C])])) == .truncated(offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00])])) == .truncated(offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xFF])])) == .truncated(offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xFF, 0x01, 0x02, 0x41])])) ==
            .truncated(offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xC0, 0x01])])) == .missingEndOfTrack(track: 0))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [])])) == .missingEndOfTrack(track: 0))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xFF, 0x2F, 0x01, 0x00])])) ==
            .malformedEndOfTrack(track: 0, offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", Self.end + [0x00, 0xC0, 0x01])])) ==
            .eventAfterEndOfTrack(track: 0, offset: 26))
    }

    @Test
    func notesMustPairWithinTheClip() {
        func refusal(_ events: [UInt8], endDelta: [UInt8] = [0x00]) -> SMFRefusal? {
            SMF.refusal(SMF.file(chunks: [SMF.track(events, endDelta: endDelta)]))
        }
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x01, 0x90, 0x3C, 0x64]) ==
            .noteOnWhileSounding(track: 0, ticks: 16, channel: 1, note: 60))
        #expect(refusal([0x02, 0x83, 0x3C, 0x40]) == .noteOffWithoutNoteOn(track: 0, ticks: 32, channel: 4, note: 60))
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x00, 0x90, 0x3D, 0x64, 0x01, 0x80, 0x3C, 0x40, 0x00, 0x91, 0x3D,
                         0x64, 0x01, 0x81, 0x3D, 0x40]) == .noteNotReleased(channel: 1, note: 61, startTicks: 0))
        #expect(refusal([0x05, 0x9F, 0x7F, 0x01]) == .noteNotReleased(channel: 16, note: 127, startTicks: 80))
        #expect(refusal([0x00, 0x90, 0x3E, 0x64, 0x01, 0x90, 0x3C, 0x64, 0x00, 0x90, 0x3D, 0x64]) ==
            .noteNotReleased(channel: 1, note: 62, startTicks: 0))
    }

    @Test
    func clipRefusalsAreSurfaced() {
        func refusal(_ events: [UInt8], endDelta: [UInt8] = [0x01]) -> SMFRefusal? {
            SMF.refusal(SMF.file(chunks: [SMF.track(events, endDelta: endDelta)]))
        }
        #expect(refusal([], endDelta: [0x00]) == .clip(.lengthOutOfRange(0)))
        #expect(refusal([0x00, 0xB0, 0x40, 0x7F]) == .clip(.unsupportedMessage(item: 0)))
        #expect(refusal([0x00, 0xB0, 0x07, 0x7F, 0x00, 0xB0, 0x7B, 0x00]) == .clip(.unsupportedMessage(item: 1)))
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x00, 0x80, 0x3C, 0x40]) ==
            .clip(.invalidNoteSpan(item: 0, startTicks: 0, endTicks: 0)))
        #expect(refusal([0x01, 0xC0, 0x05], endDelta: [0x00]) == .clip(.eventOutsideClip(item: 0, ticks: 16)))
        let many = [UInt8]((0...MIDIClip.maximumItems).map { _ in [UInt8(0x00), 0xC0, 0x05] }.joined())
        #expect(refusal(many) == .clip(.tooManyItems(count: MIDIClip.maximumItems + 1, limit: MIDIClip.maximumItems)))
    }

    @Test
    func formatOneTracksMergeByTickThenTrack() throws {
        let tempo = SMF.track([0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xFF, 0x03, 0x00])
        let first = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0xB0, 0x07, 0x01], endDelta: [0x03])
        // The second track releases the first track's note and adds a CC at the same tick.
        let second = SMF.track([0x01, 0xB0, 0x07, 0x02, 0x01, 0x80, 0x3C, 0x20])
        let read = try StandardMIDIFile.read(SMF.file(format: 1, tracks: 3, chunks: [tempo, first, second]))
        let expected = try MIDIClip.make(lengthTicks: 64, items: [
            Clip.note(0, 32, velocity: 100, release: 0x20), Clip.controlChange(16, value: 1),
            Clip.controlChange(16, value: 2)
        ])
        #expect(read.clip == expected)
        #expect(read.report == SMFReadReport(format: 1, division: 960, tracks: 3,
                                             ignoredMeta: [.tempo: 1, .text: 1], unknownChunks: 0,
                                             ignoredHeaderBytes: 0))
        let swapped = try StandardMIDIFile.read(SMF.file(format: 1, tracks: 3, chunks: [tempo, second, first]))
        #expect(swapped.clip.items.map { if case .event(_, let message) = $0 { "\(message)" } else { "note" } } ==
            ["note", "\(MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 2))",
             "\(MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 1))"])
        // A later track's Note On cannot start a note that an earlier track releases at the same tick.
        let retrigger = SMF.track([0x01, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        let release = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        #expect(SMF.refusal(SMF.file(format: 1, tracks: 2, chunks: [retrigger, release])) ==
            .noteOnWhileSounding(track: 0, ticks: 16, channel: 1, note: 60))
        #expect(SMF.refusal(SMF.file(format: 1, tracks: 2, chunks: [release, retrigger])) == nil)
    }
}
