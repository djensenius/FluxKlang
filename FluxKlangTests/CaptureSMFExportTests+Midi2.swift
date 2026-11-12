import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// MT 0x4 captures are translated by `UMPMIDI2ToMIDI1Translator`; their §9.3 losses come from the classifier only.
extension CaptureSMFExportTests {
    private static func export(_ words: [[UInt32]], endpoint: MIDIEndpointProtocol = .midi2) throws
        -> CaptureClipExport {
        var feed = try Fixture.Feed([Fixture.streamA])
        for (index, packet) in words.enumerated() {
            try feed.addMIDI2(Fixture.streamA, packet, tick: Int64(10 + 10 * index), endpoint: endpoint)
        }
        return try Fixture.export(feed.log, [Fixture.streamA])
    }

    @Test func aGenuineMIDI2NoteWithExactVelocitiesIsWrittenWithNoLoss() throws {
        let export = try Self.export([Fixture.noteOn2(1, 60, 0xC924), Fixture.noteOff2(1, 60, 0)])
        #expect(export.clip.items == [Fixture.note(1, 60, velocity: 100, release: 0, from: 10, to: 20)])
        #expect(export.smf().losses.losses == [:])
        #expect(export.smf().losses.lossless)
        let released = try Self.export([Fixture.noteOn2(1, 60, 0xC924), Fixture.noteOff2(1, 60, 0xC924)])
        #expect(released.clip.items == [Fixture.note(1, 60, velocity: 100, release: 100, from: 10, to: 20)])
    }

    @Test func aNoteOnVelocityThatIsNotExactCountsVelocityDownscaled() throws {
        let export = try Self.export([Fixture.noteOn2(1, 60, 0xC925), Fixture.noteOff2(1, 60, 0)])
        #expect(export.clip.items == [Fixture.note(1, 60, velocity: 100, release: 0, from: 10, to: 20)])
        #expect(export.smf().losses.losses == [.velocityDownscaled: 1])
    }

    @Test func aNoteOnWhoseVelocityScalesToZeroIsWrittenWithVelocityOneAndCountsTheRemap() throws {
        let export = try Self.export([Fixture.noteOn2(1, 60, 0x0100), Fixture.noteOff2(1, 60, 0)])
        #expect(export.clip.items == [Fixture.note(1, 60, velocity: 1, release: 0, from: 10, to: 20)])
        #expect(export.smf().losses.losses == [.noteOnVelocityRemapped: 1, .velocityDownscaled: 1])
    }

    @Test func anAttributeTypeOtherThanZeroCountsAttributeDropped() throws {
        let typed = try Self.export([Fixture.noteOn2(1, 60, 0xC924, attributeType: 3, attribute: 0x1234),
                                     Fixture.noteOff2(1, 60, 0)])
        #expect(typed.clip.items == [Fixture.note(1, 60, velocity: 100, release: 0, from: 10, to: 20)])
        #expect(typed.smf().losses.losses == [.attributeDropped: 1])
        let untyped = try Self.export([Fixture.noteOn2(1, 60, 0xC924, attribute: 0x1234), Fixture.noteOff2(1, 60, 0)])
        #expect(untyped.smf().losses.losses == [:])
    }

    @Test func polyPressureControlChangeAndChannelPressureAreWrittenAndCountInexactValues() throws {
        let exact = try Self.export([Fixture.voice2(0xA, 2, 60, data: Fixture.exactMid),
                                     Fixture.controlChange2(3, 7, Fixture.exactHigh),
                                     Fixture.voice2(0xD, 4, 0, data: Fixture.exactLow)])
        #expect(exact.clip.items == [
            Fixture.event(10, .polyphonicPressure(channel: 2, note: 60, pressure: 64)),
            Fixture.ccItem(20, 3, 7, 127), Fixture.event(30, .channelPressure(channel: 4, pressure: 0))])
        #expect(exact.smf().losses.losses == [:])
        let inexact = try Self.export([Fixture.voice2(0xA, 2, 60, data: 0x8000_0001),
                                       Fixture.controlChange2(3, 7, 0x8000_0001),
                                       Fixture.voice2(0xD, 4, 0, data: 0x8000_0001)])
        #expect(inexact.clip.items == [
            Fixture.event(10, .polyphonicPressure(channel: 2, note: 60, pressure: 64)),
            Fixture.ccItem(20, 3, 7, 64), Fixture.event(30, .channelPressure(channel: 4, pressure: 64))])
        #expect(inexact.smf().losses.losses == [.valueDownscaled: 3])
    }

    @Test func pitchBendIsWrittenAs14BitsAndCountsValueDownscaledOnlyWhenInexact() throws {
        let exact = try Self.export([Fixture.voice2(0xE, 1, 0, data: Fixture.exactMid),
                                     Fixture.voice2(0xE, 1, 0, data: Fixture.exactHigh)])
        #expect(exact.clip.items == [Fixture.event(10, .pitchBend(channel: 1, value: 0x2000)),
                                     Fixture.event(20, .pitchBend(channel: 1, value: 0x3FFF))])
        #expect(exact.smf().losses.losses == [:])
        let inexact = try Self.export([Fixture.voice2(0xE, 1, 0, data: 0x8000_0001)])
        #expect(inexact.clip.items == [Fixture.event(10, .pitchBend(channel: 1, value: 0x2000))])
        #expect(inexact.smf().losses.losses == [.valueDownscaled: 1])
    }

    @Test func aProgramChangeSendsItsBankOnlyWhenTheBankChanges() throws {
        let plain = try Self.export([Fixture.program2(1, 5)])
        #expect(plain.clip.items == [Fixture.event(10, .programChange(channel: 1, program: 5))])
        let export = try Self.export([Fixture.program2(1, 5, bank: (1, 2)), Fixture.program2(1, 6, bank: (1, 2)),
                                      Fixture.program2(1, 7, bank: (1, 3)), Fixture.program2(1, 8)])
        #expect(export.clip.items == Fixture.bankItems(10, 1, 5, bank: (1, 2))
            + [Fixture.event(20, .programChange(channel: 1, program: 6))]
            + Fixture.bankItems(30, 1, 7, bank: (1, 3))
            + [Fixture.event(40, .programChange(channel: 1, program: 8))])
        #expect(export.smf().losses.losses == [:])
    }

    @Test func aRegisteredControllerWriteSendsOnlyWhatTheReceiverHasNotSeen() throws {
        let export = try Self.export([Fixture.parameter2(1, 1, 2, Fixture.exactMid),
                                      Fixture.parameter2(1, 1, 2, Fixture.exactMid),
                                      Fixture.parameter2(1, 1, 2, Fixture.exactHigh),
                                      Fixture.parameter2(1, 1, 3, Fixture.exactHigh)])
        #expect(export.clip.items == Fixture.parameterItems(10, 1, 1, 2)
            + [Fixture.ccItem(20, 1, 38, 0), Fixture.ccItem(30, 1, 6, 127), Fixture.ccItem(30, 1, 38, 127)]
            + Fixture.parameterItems(40, 1, 1, 3, msb: 127, lsb: 127))
        #expect(export.smf().losses.losses == [:])
    }

    @Test func anAssignableControllerWriteUsesTheNRPNControllers() throws {
        let export = try Self.export([Fixture.parameter2(2, 4, 5, Fixture.exactMid, assignable: true),
                                      Fixture.parameter2(2, 4, 5, Fixture.exactMid, assignable: true),
                                      Fixture.parameter2(2, 4, 5, Fixture.exactHigh, assignable: true),
                                      Fixture.parameter2(2, 4, 6, Fixture.exactHigh, assignable: true)])
        #expect(export.clip.items == Fixture.parameterItems(10, 2, 4, 5, assignable: true)
            + [Fixture.ccItem(20, 2, 38, 0), Fixture.ccItem(30, 2, 6, 127), Fixture.ccItem(30, 2, 38, 127)]
            + Fixture.parameterItems(40, 2, 4, 6, msb: 127, lsb: 127, assignable: true))
        #expect(export.smf().losses.losses == [:])
    }

    @Test func theEndpointDecidesWhichLossesTheSameNoteWithAnAttributeCounts() throws {
        let note = Fixture.noteOn2(1, 60, 0xC924, attributeType: 3, attribute: 0x0100)
        let expected: [(MIDIEndpointProtocol, [SMFExportLoss: Int])] = [
            (.midi2, [.attributeDropped: 1]), (.unknown, [.fidelityUnverified: 2]), (.midi1, [:])]
        for (endpoint, losses) in expected {
            let export = try Self.export([note, Fixture.noteOff2(1, 60, 0)], endpoint: endpoint)
            #expect(export.clip.items == [Fixture.note(1, 60, velocity: 100, release: 0, from: 10, to: 20)])
            #expect(export.smf().losses.losses == losses)
        }
    }
}
