import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// What the one translator remembers across the sorted queue: order, groups, MT 0x2 controllers, SysEx, the item cap.
extension CaptureSMFExportTests {
    private static let write = Fixture.parameter2(1, 1, 2, Fixture.exactMid)

    @Test func translationFollowsTheSortedOrderNotTheCaptureOrder() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.addMIDI2(Fixture.streamA, Self.write, tick: 100)
        try feed.addMIDI2(Fixture.streamB, Self.write, tick: 50)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.clip.items == Fixture.parameterItems(50, 1, 1, 2) + [Fixture.ccItem(100, 1, 38, 0)])
    }

    @Test func sameTickVoicesTranslateByStreamBytesThenRecordIndexWhateverTheStreamsOrder() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.addMIDI2(Fixture.streamB, Self.write, tick: 100)
        try feed.addMIDI2(Fixture.streamA, Self.write, tick: 100)
        try feed.addMIDI2(Fixture.streamA, Self.write, tick: 100)
        let forward = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        let backward = try Fixture.export(feed.log, [Fixture.streamB, Fixture.streamA])
        #expect(forward.clip.items == Fixture.parameterItems(100, 1, 1, 2)
            + [Fixture.ccItem(100, 1, 38, 0), Fixture.ccItem(100, 1, 38, 0)])
        #expect(forward == backward)
        #expect(forward.smf().bytes == backward.smf().bytes)
    }

    @Test func everyGroupOfAChannelSharesOneTranslatorState() throws {
        for (first, second, flattened) in [(UInt32(0), UInt32(1), 2), (5, 2, 3)] {
            var feed = try Fixture.Feed([Fixture.streamA])
            try feed.addMIDI2(Fixture.streamA, Fixture.parameter2(1, 1, 2, Fixture.exactMid, group: first), tick: 10)
            try feed.addMIDI2(Fixture.streamA, Fixture.parameter2(1, 3, 4, Fixture.exactMid, group: second), tick: 20)
            try feed.addMIDI2(Fixture.streamA, Fixture.parameter2(1, 1, 2, Fixture.exactMid, group: first), tick: 30)
            try feed.addMIDI2(Fixture.streamA, Fixture.program2(2, 5, bank: (1, 2), group: first), tick: 40)
            try feed.addMIDI2(Fixture.streamA, Fixture.program2(2, 6, bank: (1, 2), group: second), tick: 50)
            let export = try Fixture.export(feed.log, [Fixture.streamA])
            #expect(export.clip.items == Fixture.parameterItems(10, 1, 1, 2) + Fixture.parameterItems(20, 1, 3, 4)
                + Fixture.parameterItems(30, 1, 1, 2) + Fixture.bankItems(40, 2, 5, bank: (1, 2))
                + [Fixture.event(50, .programChange(channel: 2, program: 6))])
            #expect(export.groupsFlattened == flattened)
            #expect(export.smf().losses.losses == [.groupsFlattened: flattened])
        }
    }

    private static let resetControllers: [UInt8] = [0, 6, 32, 96, 97, 98, 99, 100, 101]

    /// Channel 1 gets a bank and a parameter write, then a MT 0x2 Control Change on `channel`, then both writes again.
    /// The MIDI 1 capture sits on its own stream: a stream keeps one protocol.
    private static func stateExport(controller: UInt8, on channel: UInt8) throws -> CaptureClipExport {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.addMIDI2(Fixture.streamA, Fixture.program2(1, 5, bank: (1, 2)), tick: 10)
        try feed.addMIDI2(Fixture.streamA, Self.write, tick: 11)
        try feed.add(Fixture.streamB, Fixture.controlChange(channel, controller, 0), tick: 20)
        try feed.addMIDI2(Fixture.streamA, Fixture.program2(1, 6, bank: (1, 2)), tick: 30)
        try feed.addMIDI2(Fixture.streamA, Self.write, tick: 31)
        return try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
    }

    private static func firstWrites() -> [MIDIClipItem] {
        Fixture.bankItems(10, 1, 5, bank: (1, 2)) + Fixture.parameterItems(11, 1, 1, 2)
    }

    @Test func aMIDI1ControllerThatTheTranslatorCachesResetsItsChannelAtItsSortedPosition() throws {
        for controller in Self.resetControllers {
            let export = try Self.stateExport(controller: controller, on: 1)
            #expect(export.clip.items == Self.firstWrites() + [Fixture.ccItem(20, 1, controller, 0)]
                + Fixture.bankItems(30, 1, 6, bank: (1, 2)) + Fixture.parameterItems(31, 1, 1, 2),
                    "CC \(controller)")
        }
    }

    @Test func dataEntryLSBAndAnotherChannelResetNothing() throws {
        for (controller, channel) in [(UInt8(38), UInt8(1))] + Self.resetControllers.map({ ($0, UInt8(2)) }) {
            let export = try Self.stateExport(controller: controller, on: channel)
            let reset = Fixture.event(30, .programChange(channel: 1, program: 6))
            #expect(export.clip.items == Self.firstWrites() + [Fixture.ccItem(20, channel, controller, 0), reset,
                                                               Fixture.ccItem(31, 1, 38, 0)],
                    "CC \(controller) on channel \(channel)")
        }
    }

    /// Bank on channel 1 and a parameter write on channel 2, then `sysExTick`'s message (when any), then both again.
    private static func sysExExport(_ packet: [UInt32]?, tick sysExTick: Int64) throws -> CaptureClipExport {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.addMIDI2(Fixture.streamA, Fixture.program2(1, 5, bank: (1, 2)), tick: 10)
        try feed.addMIDI2(Fixture.streamA, Fixture.parameter2(2, 1, 2, Fixture.exactMid), tick: 11)
        try feed.addMIDI2(Fixture.streamA, Fixture.program2(1, 6, bank: (1, 2)), tick: 30)
        try feed.addMIDI2(Fixture.streamA, Fixture.parameter2(2, 1, 2, Fixture.exactMid), tick: 31)
        if let packet { try feed.add(Fixture.streamB, packet, tick: sysExTick) }
        return try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
    }

    private static let afterSysEx: [MIDIClipItem] = Fixture.bankItems(30, 1, 6, bank: (1, 2))
        + Fixture.parameterItems(31, 2, 1, 2)
    private static let beforeSysEx: [MIDIClipItem] = Fixture.bankItems(10, 1, 5, bank: (1, 2))
        + Fixture.parameterItems(11, 2, 1, 2)
    private static let omitted: [MIDIClipItem] = [Fixture.event(30, .programChange(channel: 1, program: 6)),
                                                  Fixture.ccItem(31, 2, 38, 0)]

    @Test func aDeliveredSysExResetsEveryChannelAtItsTickOrBefore() throws {
        for tick: Int64 in [20, 30] {
            let export = try Self.sysExExport(Fixture.sysEx, tick: tick)
            #expect(export.sysEx == [SMFSysExEvent(ticks: tick, payload: [1, 2, 3, 0])])
            #expect(export.clip.items == Self.beforeSysEx + Self.afterSysEx, "SysEx at \(tick)")
        }
    }

    @Test func aDeliveredSysExResetsOnlyTheVoicesAtOrAfterItsTick() throws {
        let between = try Self.sysExExport(Fixture.sysEx, tick: 31)
        #expect(between.clip.items == Self.beforeSysEx + [Fixture.event(30, .programChange(channel: 1, program: 6))]
            + Fixture.parameterItems(31, 2, 1, 2))
        let after = try Self.sysExExport(Fixture.sysEx, tick: 32)
        #expect(after.clip.items == Self.beforeSysEx + Self.omitted)
    }

    @Test func anOrphanOrNoSysExResetsNothing() throws {
        let orphan = try Self.sysExExport(Fixture.orphanSysEx, tick: 20)
        #expect(orphan.sysEx.isEmpty)
        #expect(orphan.clip.items == Self.beforeSysEx + Self.omitted)
        let none = try Self.sysExExport(nil, tick: 20)
        #expect(none.clip.items == orphan.clip.items)
    }

    @Test func theItemCapCountsEveryItemAVoiceTranslatesTo() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        for index in 0..<5_461 {
            let bank = (msb: UInt8(index / 128), lsb: UInt8(index % 128))
            try feed.addMIDI2(Fixture.streamA, Fixture.program2(1, UInt8(index % 128), bank: bank), tick: Int64(index))
        }
        try feed.addMIDI2(Fixture.streamA, Fixture.controlChange2(1, 7, Fixture.exactMid), tick: 5_461)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items.count == MIDIClip.maximumItems)
        try feed.addMIDI2(Fixture.streamA, Fixture.controlChange2(1, 7, Fixture.exactMid), tick: 5_462)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .tooManyItems(count: 16_385, limit: 16_384))
    }
}
