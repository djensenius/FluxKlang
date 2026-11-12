import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The contract's examples 09 and 10 through the export, and the loss map's invariants.
extension CaptureSMFExportTests {
    typealias Examples = MIDICaptureFixture

    @Test func example09WritesEveryMIDI2CaptureAsItsMIDI1EquivalentWithNoLoss() throws {
        let log = try Examples.example09Captures()
        let export = try Fixture.export(log, [Examples.keysA, Examples.keysB])
        var plain = try Examples.log([Examples.keysA, Examples.keysB])
        try plain.observe(anchor: Examples.anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try Examples.capture(&plain, Examples.keysA, [0x2090_3C64], host: 2_412_000_000)
        try Examples.capture(&plain, Examples.keysA, [0x2080_3C00], host: 2_424_000_000)
        try Examples.capture(&plain, Examples.keysB, [0x2090_3C64], host: 2_436_000_000)
        try Examples.capture(&plain, Examples.keysB, [0x20B0_0740], host: 2_442_000_000)
        try Examples.capture(&plain, Examples.keysB, [0x2080_3C00], host: 2_472_000_000)
        let equivalent = try Fixture.export(plain, [Examples.keysA, Examples.keysB])
        #expect(export.clip.items == [Fixture.note(1, 60, velocity: 100, release: 0, from: 2_560, to: 5_120),
                                      Fixture.note(1, 60, velocity: 100, release: 0, from: 7_680, to: 15_360),
                                      Fixture.ccItem(8_960, 1, 7, 64)])
        #expect(export.clip == equivalent.clip)
        #expect(export.smf().losses.losses == [:])
        #expect(export.smf().bytes == equivalent.smf().bytes)
        #expect(export.droppedUMPOnly == 0)
    }

    /// Example 10 at this export's division (15,360 ticks per quarter, the log's musical ticks) and not the contract's
    /// 960: the other seven categories are the contract's exactly, and `timingQuantized` is 0 (every capture's frame
    /// is already a whole tick, where the contract's 1 came from the coarser division).
    @Test func example10CountsTheContractsLossesAndItsOwnTimingQuantized() throws {
        let log = try Examples.example10()
        let export = try Fixture.export(log, [Examples.synth, Examples.legacy, Examples.unknown])
        #expect(export.clip.lengthTicks == 76_800)
        #expect(export.clip.items == [
            Fixture.note(1, 60, velocity: 100, release: 0, from: 15_363, to: 46_080),
            Fixture.ccItem(30_720, 1, 74, 77),
            Fixture.note(1, 64, velocity: 1, release: 0, from: 38_400, to: 53_760),
            Fixture.note(1, 60, velocity: 100, release: 64, from: 61_440, to: 69_120),
            Fixture.note(1, 60, velocity: 100, release: 64, from: 69_120, to: 76_800)])
        #expect(export.retriggeredNotes == 1)
        #expect(export.openNotesClosed == 1)
        #expect(export.unpairedOffs == 0 && export.widenedNotes == 0)
        #expect(export.groupsFlattened == 0 && export.passesOverlaid == 0)
        var losses = export.smf().losses.losses
        let timing = losses.removeValue(forKey: .timingQuantized)
        #expect(losses == [.velocityDownscaled: 2, .attributeDropped: 1, .perNoteDropped: 1, .valueDownscaled: 1,
                           .noteOnVelocityRemapped: 1, .fidelityUnverified: 1, .umpOnlyDropped: 1])
        #expect(timing == nil)
        #expect(export.timingQuantized == 0)
    }

    @Test func droppedUMPOnlyIsTheUMPOnlyDroppedCountAndCaptureLossesHoldNoZero() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB, Fixture.streamC])
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.addMIDI2(Fixture.streamA, Fixture.noteOn2(2, 61, 0xC925), tick: 5)
        try feed.addMIDI2(Fixture.streamA, Fixture.controlChange2(1, 38, Fixture.exactLow), tick: 6)
        try feed.addMIDI2(Fixture.streamA, Fixture.voice2(0x4, 1, 1, 2, data: 5), tick: 7)
        try feed.addMIDI2(Fixture.streamC, Fixture.voice2(0x6, 1, 60, data: Fixture.exactMid), tick: 8)
        try feed.add(Fixture.streamB, Fixture.data128, tick: 9)
        try feed.add(Fixture.streamB, Fixture.orphanSysEx, tick: 10)
        try feed.add(Fixture.streamB, Fixture.noteOff(1, 60, 64), tick: 20)
        try feed.addMIDI2(Fixture.streamA, Fixture.noteOff2(2, 61, 0), tick: 30)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB, Fixture.streamC])
        let losses = export.smf().losses.losses
        #expect(export.droppedUMPOnly == 4)
        #expect(losses == [.velocityDownscaled: 1, .perNoteDropped: 1, .umpOnlyDropped: 4])
        #expect(export.droppedUMPOnly == losses[.umpOnlyDropped] ?? 0)
        #expect(export.captureLosses == losses)
        #expect(export.captureLosses.values.allSatisfy { $0 > 0 })
        #expect(!export.smf().losses.lossless)
    }
}
