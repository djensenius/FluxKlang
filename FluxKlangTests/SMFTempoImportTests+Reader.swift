import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The proposal reads what the shipped reader still reports as ignored, and leaves that reader unchanged.
extension SMFTempoImportTests {
    @Test func theShippedReaderStillIgnoresAndCountsTempoAndTimeSignatureEvents() throws {
        let events = F.tempo(600_000) + F.meter(3, 2) + F.tempo(700_000, after: 480) + F.note
        let bytes = F.single(events)
        let result = try StandardMIDIFile.read(bytes)
        #expect(result.report.ignoredMeta[.tempo] == 2)
        #expect(result.report.ignoredMeta[.timeSignature] == 1)
        let proposal = try F.proposal(bytes)
        #expect(proposal.segments.count == 2)
        #expect(proposal.initialMeter == (try F.meterValue(3, 4)))
    }

    @Test func theProposalIsIndependentOfNotesAndOtherEventsInTheFile() throws {
        let tempos = F.tempo(600_000) + F.meter(3, 2) + F.tempo(700_000, after: 480)
        let bare = try F.proposal(F.single(tempos))
        let noisy = try F.proposal(F.single(tempos + F.meta(0x01, [0x41, 0x42]) + F.note))
        #expect(noisy.segments == bare.segments)
        #expect(noisy.initialMeter == bare.initialMeter)
        #expect(noisy.laterMeterChanges == bare.laterMeterChanges)
    }

    @Test func aStructuralDefectIsRefusedAheadOfATempoDefectThatComesLaterInTheFile() {
        let bytes = F.single(F.tempo(5) + [0x00, 0x90, 0x3C, 0x90])
        #expect(F.refusal(bytes) == .tempoOutOfRange(atTicks: 0, microsPerQuarter: 5))
        let reversed = F.single([0x00, 0x90, 0x3C, 0x90] + F.tempo(5))
        #expect(F.refusal(reversed) == .file(.invalidDataByte(track: 0, offset: 24)))
    }
}
