import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `groupsFlattened`: every fixture of the other CL5 files sits in group 0, so only these tests span groups.
extension CaptureSMFExportTests {
    private static func inGroup(_ group: UInt32, _ words: [UInt32]) -> [UInt32] {
        [words[0] | group << 24] + words.dropFirst()
    }

    private static func controlChanges(in groups: [UInt32]) throws -> Fixture.Feed {
        var feed = try Fixture.Feed([Fixture.streamA])
        for (index, group) in groups.enumerated() {
            try feed.add(Fixture.streamA, inGroup(group, Fixture.controlChange(1, 7, UInt8(index))), tick: Int64(index))
        }
        return feed
    }

    @Test func aSelectionInOneGroupFlattensNothingAndReportsNoGroupLoss() throws {
        let feed = try Self.controlChanges(in: [4, 4, 4])
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.groupsFlattened == 0)
        #expect(export.smf().losses.losses == [:])
    }

    @Test func twoGroupsCountExactlyTheCapturesOutsideTheLowestGroup() throws {
        let feed = try Self.controlChanges(in: [0, 0, 0, 1])
        #expect(try Fixture.export(feed.log, [Fixture.streamA]).groupsFlattened == 1)
        let more = try Self.controlChanges(in: [0, 3, 1, 3, 0, 0])
        #expect(try Fixture.export(more.log, [Fixture.streamA]).groupsFlattened == 3)
    }

    @Test func theLowestGroupNeedNotBeGroupZeroNorTheGroupOfTheFirstCapture() throws {
        let feed = try Self.controlChanges(in: [5, 2, 5])
        #expect(try Fixture.export(feed.log, [Fixture.streamA]).groupsFlattened == 2)
    }

    @Test func aGrouplessCaptureNeverAddsAGroupNorCounts() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: 0)
        try feed.add(Fixture.streamA, Self.inGroup(5, Fixture.utility), tick: 1)
        try feed.add(Fixture.streamA, Self.inGroup(7, Fixture.utility), tick: 2)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.droppedUMPOnly == 2)
        #expect(export.groupsFlattened == 0)
    }

    @Test func aDroppedDataCaptureInAnotherGroupStillCountsAsFlattened() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: 0)
        try feed.add(Fixture.streamB, Self.inGroup(3, Fixture.data128), tick: 1, endpoint: .midi2, port: .midi2)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.droppedUMPOnly == 1)
        #expect(export.clip.items.count == 1)
        #expect(export.groupsFlattened == 1)
    }

    @Test func theFlattenedCountReachesTheSMFLossReport() throws {
        let feed = try Self.controlChanges(in: [0, 2, 2])
        let losses = try Fixture.export(feed.log, [Fixture.streamA]).smf().losses
        #expect(losses.losses == [.groupsFlattened: 2])
    }

    @Test func aNoteOffOfAnotherGroupClosesTheNoteOnOfTheFirstGroup() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Self.inGroup(1, Fixture.noteOff(1, 60, 40)), tick: 100)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [.note(MIDIClipNote(channel: 1, note: 60, velocity: 64, releaseVelocity: 40,
                                                         startTicks: 0, endTicks: 100))])
        #expect(export.unpairedOffs == 0 && export.openNotesClosed == 0)
        #expect(export.groupsFlattened == 1)
    }
}
