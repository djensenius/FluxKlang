import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Event-level structure of the scan: running status, skipped events, End of Track and truncation inside each field.
/// The first track body starts at byte 22 of every file built by `Fixture.file`.
extension SMFTempoImportTests {
    @Test func runningStatusAcrossSkippedEventsKeepsEveryLaterTempoAtItsTick() throws {
        // Three channel events share one status byte; the tempo then sits 0x10 file ticks after the third.
        let notes: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x10, 0x3E, 0x64, 0x10, 0x40, 0x64]
        let events = notes + F.tempo(400_000, after: 0x10)
        let proposal = try F.proposal(F.single(events))
        #expect(proposal.segments == (try F.segments([[0, 500_000], [48 * 32, 400_000]])))
        let program: [UInt8] = [0x00, 0xC3, 0x05, 0x08, 0x06] + F.tempo(400_000)
        #expect(try F.proposal(F.single(program)).segments == (try F.segments([[0, 500_000], [8 * 32, 400_000]])))
    }

    @Test func aMetaOrSysExEventCancelsRunningStatusAndAnOrdinaryDataByteIsRefused() {
        let afterMeta: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x00, 0xFF, 0x01, 0x00, 0x00, 0x3E, 0x64]
        #expect(F.refusal(F.single(afterMeta)) == .file(.missingRunningStatus(track: 0, offset: 31)))
        let afterSysEx: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x00, 0xF0, 0x01, 0x7F, 0x00, 0x3E, 0x64]
        #expect(F.refusal(F.single(afterSysEx)) == .file(.missingRunningStatus(track: 0, offset: 31)))
        let afterEscape: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x00, 0xF7, 0x01, 0x7F, 0x00, 0x3E, 0x64]
        #expect(F.refusal(F.single(afterEscape)) == .file(.missingRunningStatus(track: 0, offset: 31)))
        #expect(F.refusal(F.single([0x00, 0x3C, 0x64])) == .file(.missingRunningStatus(track: 0, offset: 23)))
        let secondTrack = F.header(tracks: 2) + F.track([]) + F.track([0x00, 0x3C, 0x64])
        #expect(F.refusal(secondTrack) == .file(.missingRunningStatus(track: 1, offset: 35)))
    }

    @Test func runningStatusDoesNotCarryAcrossTracks() {
        let first: [UInt8] = [0x00, 0x90, 0x3C, 0x64]
        let bytes = F.header(tracks: 2) + F.track(first) + F.track([0x00, 0x3E, 0x64])
        #expect(F.refusal(bytes) == .file(.missingRunningStatus(track: 1, offset: 39)))
    }

    @Test func unrelatedMetaSysExAndChannelEventsAreSkippedByTheirLengths() throws {
        let longText = F.meta(0x01, Array(repeating: 0x41, count: 200))
        let events = F.meta(0x03, [0x41, 0x42]) + longText + F.meta(0x54, [0x60, 0, 0, 0, 0]) + F.meta(0x59, [0, 0])
            + F.meta(0x7F, [1, 2, 3]) + F.meta(0x20, [0]) + F.meta(0x09, []) + F.meta(0x60, [9, 9])
            + [0x00, 0xF0, 0x02, 0x7E, 0x7F, 0x00, 0xF7, 0x01, 0x05] + [0x00, 0xE0, 0x00, 0x40, 0x00, 0xD1, 0x7F]
            + F.tempo(750_000) + F.meter(5, 3, after: 4)
        let proposal = try F.proposal(F.single(events))
        #expect(proposal.segments == (try F.segments([[0, 750_000]])))
        #expect(proposal.laterMeterChanges == [try F.change(4 * 32, 5, 8)])
        #expect(proposal.initialMeter == nil)
    }

    @Test func aSkippedControllerAndAnUnpairedNoteAreNotRefusalsHere() throws {
        // The reader refuses a Note On with no Note Off (`noteNotReleased`); the scan does not pair notes.
        let hanging: [UInt8] = [0x00, 0x90, 0x3C, 0x64] + F.tempo(420_000, after: 8)
        #expect(F.readerRefusal(F.single(hanging)) != nil)
        #expect(try F.proposal(F.single(hanging)).segments == (try F.segments([[0, 500_000], [8 * 32, 420_000]])))
        // Sustain (64) and all-sound-off (120) are controllers the reader skips and counts; the scan skips them too.
        let controller: [UInt8] = [0x00, 0xB0, 0x40, 0x7F, 0x00, 0x78, 0x00] + F.tempo(420_000, after: 8)
        #expect(F.readerRefusal(F.single(controller)) == nil)
        #expect(try F.proposal(F.single(controller)).segments == (try F.segments([[0, 500_000], [8 * 32, 420_000]])))
    }

    @Test func invalidStatusAndDataBytesAreRefusedAtTheReadersOffsets() {
        #expect(F.refusal(F.single([0x00, 0xF1, 0x00])) == .file(.invalidStatus(track: 0, offset: 23, status: 0xF1)))
        #expect(F.refusal(F.single([0x00, 0xFE])) == .file(.invalidStatus(track: 0, offset: 23, status: 0xFE)))
        #expect(F.refusal(F.single([0x00, 0xF8])) == .file(.invalidStatus(track: 0, offset: 23, status: 0xF8)))
        #expect(F.refusal(F.single([0x00, 0x90, 0x3C, 0x80])) == .file(.invalidDataByte(track: 0, offset: 24)))
        #expect(F.refusal(F.single([0x00, 0x90, 0x80, 0x40])) == .file(.invalidDataByte(track: 0, offset: 24)))
        #expect(F.refusal(F.single([0x00, 0xC0, 0x80])) == .file(.invalidDataByte(track: 0, offset: 24)))
        #expect(F.refusal(F.single([0x00, 0x90, 0x3C, 0x64, 0x00, 0x3C, 0x80]))
            == .file(.invalidDataByte(track: 0, offset: 27)))
    }

    @Test func endOfTrackDefectsAreRefusedWithTheReadersCases() {
        #expect(F.refusal(F.single([], end: [0x00, 0xFF, 0x2F, 0x01, 0x00]))
            == .file(.malformedEndOfTrack(track: 0, offset: 23)))
        #expect(F.refusal(F.single([], end: [0x00, 0xFF, 0x2F, 0x00, 0x00]))
            == .file(.eventAfterEndOfTrack(track: 0, offset: 26)))
        #expect(F.refusal(F.single([], end: [])) == .file(.missingEndOfTrack(track: 0)))
        #expect(F.refusal(F.single(F.note, end: [])) == .file(.missingEndOfTrack(track: 0)))
        #expect(F.refusal(F.header(tracks: 2) + F.track([]) + F.track(F.tempo(400_000), end: []))
            == .file(.missingEndOfTrack(track: 1)))
    }

    @Test func truncationInsideEveryFieldOfAChannelOrSysExEventIsRefusedAtTheEventStart() {
        let cut = { (bytes: [UInt8]) in F.refusal(F.single(bytes, end: [])) }
        #expect(cut([0x80]) == .file(.truncated(offset: 22)))
        #expect(cut([0x00]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0x90]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0x90, 0x3C]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0xC0]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0xF0]) == .file(.truncated(offset: 24)))
        #expect(cut([0x00, 0xF0, 0x03, 0x01, 0x02]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0xF7, 0x81]) == .file(.truncated(offset: 24)))
        #expect(cut([0x00, 0xFF]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0xFF, 0x01]) == .file(.truncated(offset: 25)))
        #expect(cut([0x00, 0xFF, 0x01, 0x81]) == .file(.truncated(offset: 25)))
        #expect(cut([0x00, 0xFF, 0x01, 0x02, 0x41]) == .file(.truncated(offset: 23)))
        #expect(cut([0x00, 0xFF, 0x01, 0x02, 0x41, 0x42]) == .file(.missingEndOfTrack(track: 0)))
    }

    @Test func aTempoEventCutAtEachFieldBoundaryIsTruncatedAtTheEventStart() {
        let full = F.tempo(600_000)
        let offsets: [Int: SMFTempoRefusal] = [
            1: .file(.truncated(offset: 23)), 2: .file(.truncated(offset: 23)), 3: .file(.truncated(offset: 25)),
            4: .file(.truncated(offset: 23)), 5: .file(.truncated(offset: 23)), 6: .file(.truncated(offset: 23)),
            7: .file(.missingEndOfTrack(track: 0))
        ]
        for count in 1...7 {
            #expect(F.refusal(F.single(Array(full.prefix(count)), end: [])) == offsets[count], "cut at \(count)")
        }
    }

    @Test func aTimeSignatureEventCutAtEachFieldBoundaryIsTruncatedAtTheEventStart() {
        let full = F.meter(6, 3)
        for count in 1...8 {
            let expected: SMFTempoRefusal = count == 3 ? .file(.truncated(offset: 25))
                : count == 8 ? .file(.missingEndOfTrack(track: 0)) : .file(.truncated(offset: 23))
            #expect(F.refusal(F.single(Array(full.prefix(count)), end: [])) == expected, "cut at \(count)")
        }
    }
}
