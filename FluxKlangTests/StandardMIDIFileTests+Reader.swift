import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Standard MIDI File reader", .productionAccessAudit)
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
                                             unknownChunks: 2, ignoredHeaderBytes: 2, ignoredSysEx: [:],
                                             ignoredControllers: [:], ignoredNoteOffs: 0, ignoredZeroLengthNotes: 0,
                                             ignoredEventsAtEnd: 0))
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
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x00, 0x90, 0x3D, 0x64, 0x01, 0x80, 0x3C, 0x40, 0x00, 0x91, 0x3D,
                         0x64, 0x01, 0x81, 0x3D, 0x40]) == .noteNotReleased(channel: 1, note: 61, startTicks: 0))
        #expect(refusal([0x05, 0x9F, 0x7F, 0x01]) == .noteNotReleased(channel: 16, note: 127, startTicks: 80))
        // A retrigger written Note On first: the tick's Note Off closes the earlier note, leaving the new one open.
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x10, 0x90, 0x3C, 0x50, 0x00, 0x80, 0x3C, 0x40]) ==
            .noteNotReleased(channel: 1, note: 60, startTicks: 256))
        #expect(refusal([0x00, 0x90, 0x3E, 0x64, 0x01, 0x90, 0x3C, 0x64, 0x00, 0x90, 0x3D, 0x64]) ==
            .noteNotReleased(channel: 1, note: 62, startTicks: 0))
    }

    @Test
    func clipRefusalsAreSurfaced() {
        func refusal(_ events: [UInt8], endDelta: [UInt8] = [0x01]) -> SMFRefusal? {
            SMF.refusal(SMF.file(chunks: [SMF.track(events, endDelta: endDelta)]))
        }
        #expect(refusal([], endDelta: [0x00]) == .clip(.lengthOutOfRange(0)))
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
                                             ignoredHeaderBytes: 0, ignoredSysEx: [:], ignoredControllers: [:],
                                             ignoredNoteOffs: 0, ignoredZeroLengthNotes: 0, ignoredEventsAtEnd: 0))
        let swapped = try StandardMIDIFile.read(SMF.file(format: 1, tracks: 3, chunks: [tempo, second, first]))
        #expect(swapped.clip.items.map { if case .event(_, let message) = $0 { "\(message)" } else { "note" } } ==
            ["note", "\(MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 2))",
             "\(MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 1))"])
        // An earlier track's Note On at the tick a later track releases the same note: the Note Off comes first,
        // in either track order, so the note retriggers.
        let retrigger = SMF.track([0x01, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        let release = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        for chunks in [[retrigger, release], [release, retrigger]] {
            let notes = try StandardMIDIFile.read(SMF.file(format: 1, tracks: 2, chunks: chunks))
            #expect(notes.clip.items == [Clip.note(0, 16), Clip.note(16, 32)])
            #expect(notes.report.ignoredNoteOffs == 0)
        }
    }

    @Test
    func atOneTickNoteOffsComeBeforeOtherMessages() throws {
        // A retrigger written Note On first: at tick 16 the new note's On precedes the old note's Off.
        let events: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x01, 0x90, 0x3C, 0x50, 0x00, 0x80, 0x3C, 0x20,
                               0x01, 0x80, 0x3C, 0x40]
        let read = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(events)]))
        #expect(read.clip.items == [Clip.note(0, 16, release: 0x20), Clip.note(16, 32, velocity: 0x50)])
        #expect(read.report.ignoredNoteOffs == 0)
    }

    @Test
    func zeroLengthNotesAreSkippedAndCountedAndNeverStretch() throws {
        func read(_ events: [UInt8]) throws -> SMFReadResult {
            try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(events)]))
        }
        // A zero-length note, then a redundant Note Off: no note at all, never one stretched to tick 256.
        let redundant = try read([0x00, 0x90, 0x3C, 0x64, 0x00, 0x80, 0x3C, 0x40, 0x10, 0x80, 0x3C, 0x40])
        #expect(redundant.clip == (try MIDIClip.make(lengthTicks: 256, items: [])))
        #expect((redundant.report.ignoredZeroLengthNotes, redundant.report.ignoredNoteOffs) == (1, 1))
        // A zero-length drum hit, then a normal hit of the same note: one note.
        let drums = try read([0x00, 0x99, 0x24, 0x64, 0x00, 0x89, 0x24, 0x40, 0x10, 0x99, 0x24, 0x64,
                              0x10, 0x89, 0x24, 0x40])
        #expect(drums.clip.items == [Clip.note(256, 512, pitch: 36, channel: 10)])
        #expect((drums.report.ignoredZeroLengthNotes, drums.report.ignoredNoteOffs) == (1, 0))
        // The same with velocity-0 Note Ons under running status.
        let running = try read([0x00, 0x99, 0x24, 0x64, 0x00, 0x24, 0x00, 0x10, 0x24, 0x64, 0x10, 0x24, 0x00])
        #expect(running.clip == drums.clip)
        #expect((running.report.ignoredZeroLengthNotes, running.report.ignoredNoteOffs) == (1, 0))
        // A Note Off earlier in the file than the Note On at its tick does not pair: it is a stray Note Off.
        let strayEvents: [UInt8] = [0x00, 0x80, 0x3C, 0x40, 0x00, 0x90, 0x3C, 0x64, 0x10, 0x80, 0x3C, 0x40]
        let stray = try read(strayEvents)
        #expect(stray.clip.items == [Clip.note(0, 256)])
        #expect((stray.report.ignoredZeroLengthNotes, stray.report.ignoredNoteOffs) == (0, 1))
        // The Note On moves its key's cursor past that Note Off without taking it: one pairing step.
        let strayFile = SMF.file(chunks: [SMF.track(strayEvents)])
        #expect(try StandardMIDIFile.readCountingPairingStepsForTesting(strayFile).pairingSteps == 1)
        // Two Note Ons and one later Note Off at one tick: the first On pairs, the second sounds until tick 16.
        let twice = try read([0x00, 0x90, 0x3C, 0x64, 0x00, 0x90, 0x3C, 0x50, 0x00, 0x80, 0x3C, 0x40,
                              0x01, 0x80, 0x3C, 0x40])
        #expect(twice.clip.items == [Clip.note(0, 16, velocity: 0x50)])
        #expect(twice.report.ignoredZeroLengthNotes == 1)
        // Each Note On takes the earliest pending Note Off after it in the file: both notes pair, none is stray.
        let interleaved = try read([0x00, 0x90, 0x3C, 0x64, 0x00, 0x80, 0x3C, 0x40, 0x00, 0x90, 0x3C, 0x65,
                                    0x00, 0x80, 0x3C, 0x41, 0x10, 0xC0, 0x01])
        #expect(interleaved.clip.items.isEmpty)
        #expect((interleaved.report.ignoredZeroLengthNotes, interleaved.report.ignoredNoteOffs) == (2, 0))
        #expect(interleaved.report.ignoredEventsAtEnd == 1)
    }

    @Test
    func theLargestTickOfZeroLengthNotesPairsInLinearSteps() throws {
        // The most zero-length notes one tick holds under the standard limits: 32,767 of one key at tick 0, End of
        // Track at tick 1 (65,535 events; one more pair makes 65,537, over the 65,536 limit). Pins the exact counts,
        // and that each On takes the next pending Off in one step (32,767 steps in all), never rescanning from the
        // start.
        let pair: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x00, 0x80, 0x3C, 0x40]
        func file(pairs: Int) -> [UInt8] {
            SMF.file(chunks: [SMF.track(Array([[UInt8]](repeating: pair, count: pairs).joined()), endDelta: [0x01])])
        }
        let bytes = file(pairs: 32_767)
        #expect(bytes.count == 262_162)
        let (read, steps) = try StandardMIDIFile.readCountingPairingStepsForTesting(bytes)
        #expect(read.clip == (try MIDIClip.make(lengthTicks: 16, items: [])))
        #expect((read.report.ignoredZeroLengthNotes, read.report.ignoredNoteOffs) == (32_767, 0))
        #expect(steps == 32_767)
        #expect(try StandardMIDIFile.read(bytes) == read)
        #expect(SMF.refusal(file(pairs: 32_768)) == .tooManyEvents(limit: 65_536))
    }

    @Test
    func zeroLengthNotesPairAcrossTracksInFileOrder() throws {
        func read(_ tracks: [[UInt8]]) throws -> SMFReadResult {
            try StandardMIDIFile.read(SMF.file(format: 1, tracks: UInt16(tracks.count), chunks: tracks.map {
                SMF.track($0)
            }))
        }
        // The Note On in track 0 comes before the Note Off in track 1 in the file: a zero-length note.
        let paired = try read([[0x01, 0x90, 0x3C, 0x64], [0x01, 0x80, 0x3C, 0x40]])
        #expect(paired.clip == (try MIDIClip.make(lengthTicks: 16, items: [])))
        #expect((paired.report.ignoredZeroLengthNotes, paired.report.ignoredNoteOffs) == (1, 0))
        // The Note Off in track 0 comes first in the file: a stray Note Off, and track 1's note sounds on.
        let stray = try read([[0x01, 0x80, 0x3C, 0x40], [0x01, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40]])
        #expect(stray.clip.items == [Clip.note(16, 32)])
        #expect((stray.report.ignoredZeroLengthNotes, stray.report.ignoredNoteOffs) == (0, 1))
        // A stray Note Off pends only for its own tick: it cannot pair with a Note On at a later tick.
        let later = try read([[0x10, 0x90, 0x3C, 0x64, 0x10, 0x80, 0x3C, 0x40], [0x00, 0x80, 0x3C, 0x40]])
        #expect(later.clip.items == [Clip.note(256, 512)])
        #expect((later.report.ignoredZeroLengthNotes, later.report.ignoredNoteOffs) == (0, 1))
    }

    @Test
    func nonNoteEventsAtTheClipEndAreSkippedAndCounted() throws {
        // CC 7 and a pitch-bend reset at the End of Track tick; the Note Off there still closes its note, and a CC
        // one file tick earlier stays.
        let events: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x0F, 0xB0, 0x07, 0x50, 0x01, 0x80, 0x3C, 0x40,
                               0x00, 0xB0, 0x07, 0x64, 0x00, 0xE0, 0x00, 0x40]
        let read = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(events)]))
        #expect(read.clip.items == [Clip.note(0, 256),
                                    .event(ticks: 240, message: .controlChange(channel: 1, controller: 7, value: 80))])
        #expect(read.report.ignoredEventsAtEnd == 2)
        // A format 1 track ending early: its event at the clip end is skipped, its earlier event kept.
        let tracks = [SMF.track([0x00, 0xC0, 0x05], endDelta: [0x10]), SMF.track([0x10, 0xC0, 0x06])]
        let merged = try StandardMIDIFile.read(SMF.file(format: 1, tracks: 2, chunks: tracks))
        #expect(merged.clip.items == [.event(ticks: 0, message: .programChange(channel: 1, program: 5))])
        #expect(merged.report.ignoredEventsAtEnd == 1)
        // A Note On at the clip end is not skipped: it is never released.
        #expect(SMF.refusal(SMF.file(chunks: [SMF.track([0x10, 0x90, 0x3C, 0x64])])) ==
            .noteNotReleased(channel: 1, note: 60, startTicks: 256))
    }

    @Test
    func strayNoteOffsAreSkippedAndCounted() throws {
        // A Note Off with nothing sounding, one repeated after its note ends, and a velocity-0 Note On.
        let events: [UInt8] = [0x02, 0x83, 0x3C, 0x40, 0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40,
                               0x00, 0x3C, 0x40, 0x00, 0x90, 0x3E, 0x00]
        let read = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(events)]))
        #expect(read.clip == (try MIDIClip.make(lengthTicks: 48, items: [Clip.note(32, 48)])))
        #expect(read.report.ignoredNoteOffs == 3)
    }

    @Test
    func sysExIsSkippedAndCountedByKind() throws {
        let gmReset: [UInt8] = [0x00, 0xF0, 0x05, 0x7E, 0x7F, 0x09, 0x01, 0xF7]
        let gsReset: [UInt8] = [0x00, 0xF0, 0x0A, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
        let note: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40]
        let resets = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(gmReset + gsReset + note)]))
        #expect(resets.clip == (try MIDIClip.make(lengthTicks: 16, items: [Clip.note(0, 16)])))
        #expect(resets.report == SMFReadReport(format: 0, division: 960, tracks: 1, ignoredMeta: [:],
                                               unknownChunks: 0, ignoredHeaderBytes: 0,
                                               ignoredSysEx: [.message: 2], ignoredControllers: [:],
                                               ignoredNoteOffs: 0, ignoredZeroLengthNotes: 0, ignoredEventsAtEnd: 0))
        // An escape's delta time still moves the track: the note starts one file tick (16 clip ticks) later.
        let escape = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track([0x01, 0xF7, 0x01, 0xF8] + note)]))
        #expect(escape.clip == (try MIDIClip.make(lengthTicks: 32, items: [Clip.note(16, 32)])))
        #expect(escape.report.ignoredSysEx == [.escape: 1])
        // A divided message (F0 without a final F7, then F7 continuation packets), then empty F0 and F7 events.
        let divided: [UInt8] = [0x00, 0xF0, 0x03, 0x43, 0x12, 0x00, 0x01, 0xF7, 0x02, 0x34, 0x56,
                                0x01, 0xF7, 0x02, 0x78, 0xF7]
        let empty: [UInt8] = [0x00, 0xF0, 0x00, 0x00, 0xF7, 0x00]
        let packets = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(divided + empty + note)]))
        #expect(packets.clip == (try MIDIClip.make(lengthTicks: 48, items: [Clip.note(32, 48)])))
        #expect(packets.report.ignoredSysEx == [.message: 2, .escape: 3])
    }

    @Test
    func sysExCancelsRunningStatusAndIsBounded() {
        func refusal(_ events: [UInt8], limits: SMFReadLimits = .standard) -> SMFRefusal? {
            SMF.refusal(SMF.file(chunks: [SMF.track(events)]), limits: limits)
        }
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x00, 0xF0, 0x01, 0xF7, 0x10, 0x3C, 0x00]) ==
            .missingRunningStatus(track: 0, offset: 31))
        #expect(refusal([0x00, 0x90, 0x3C, 0x64, 0x00, 0xF7, 0x01, 0xF8, 0x10, 0x3C, 0x00]) ==
            .missingRunningStatus(track: 0, offset: 31))
        // Lengths past the chunk end (the event starts at offset 23), one of them by a single byte.
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xF0, 0x05, 0x7E, 0x7F])])) ==
            .truncated(offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xF7, 0x03, 0x7E, 0x7F])])) ==
            .truncated(offset: 23))
        #expect(SMF.refusal(SMF.file(chunks: [SMF.chunk("MTrk", [0x00, 0xF0])])) == .truncated(offset: 24))
        #expect(refusal([0x00, 0xF0, 0x80, 0x80, 0x80, 0x80, 0x00]) == .overlongQuantity(offset: 24))
        // SysEx counts toward the event bound: SysEx, Note On, Note Off and End of Track are 4 events.
        let counted: [UInt8] = [0x00, 0xF0, 0x00, 0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40]
        #expect(refusal(counted, limits: SMFReadLimits(maximumEvents: 3)) == .tooManyEvents(limit: 3))
        #expect(refusal(counted, limits: SMFReadLimits(maximumEvents: 4)) == nil)
    }

    @Test
    func refusedControllersAreSkippedAndCountedByNumber() throws {
        // A typical General MIDI start: Reset All Controllers (CC 121) at tick 0, then a note held by sustain.
        let events: [UInt8] = [0x00, 0xB0, 0x79, 0x00, 0x00, 0x90, 0x3C, 0x64, 0x00, 0xB0, 0x40, 0x7F,
                               0x01, 0x80, 0x3C, 0x40, 0x01, 0xB0, 0x40, 0x00]
        let read = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(events)]))
        #expect(read.clip == (try MIDIClip.make(lengthTicks: 32, items: [Clip.note(0, 16)])))
        #expect(read.report.ignoredControllers == [121: 1, 64: 2])
        // Every refused controller is counted under its number, through running status; its neighbours stay events.
        let controllers: [UInt8] = [63, 64, 65, 66, 67, 68, 69, 70, 119, 120, 121, 123, 127]
        let running: [UInt8] = controllers.dropFirst().flatMap { [0x00, $0, 0x00] }
        let bytes: [UInt8] = [0x00, 0xB5, controllers[0], 0x00] + running
        let mixed = try StandardMIDIFile.read(SMF.file(chunks: [SMF.track(bytes, endDelta: [0x01])]))
        #expect(mixed.clip.items == [63, 65, 67, 68, 70, 119].map { controller in
            MIDIClipItem.event(ticks: 0, message: .controlChange(channel: 6, controller: controller, value: 0))
        })
        #expect(mixed.report.ignoredControllers == [64: 1, 66: 1, 69: 1, 120: 1, 121: 1, 123: 1, 127: 1])
    }

    @Test
    func extraTrackChunksAreRefusedAtTheFirstExtraOne() {
        let note = SMF.track([0x00, 0x90, 0x3C, 0x64, 0x01, 0x80, 0x3C, 0x40])
        #expect(SMF.refusal(SMF.file(chunks: [note, note, note])) == .trackCountMismatch(declared: 1, found: 2))
        // The third chunk overruns the file, but the refusal comes first, before that chunk is scanned.
        let cut = Array(SMF.file(chunks: [note, note, note]).dropLast())
        #expect(SMF.refusal(cut) == .trackCountMismatch(declared: 1, found: 2))
    }
}
