import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct MIDIClockPulseScheduleTests {
    private static func map(rate: Int = 48_000, tempos: [(Int64, Int64)] = [(0, 500_000)],
                            anchorFrame: Int64 = 0, anchorTicks: Int64 = 0) throws -> MusicalClockMap {
        let anchor = ClockAnchor(sample: .init(clock: ClockID(validated: "clock.sample"), generation: .initial,
                                               frame: anchorFrame),
                                 host: .init(ticks: 0),
                                 musical: .init(transport: .initial, musicalMap: .initial,
                                                ticks: anchorTicks, loopIteration: 0))
        let segments = try tempos.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) }
        let map = try MusicalMap(clock: ClockID(validated: "clock.musical"), revision: .initial, segments: segments)
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                   currentSample: .initial, currentTransport: .initial)
    }

    private static func frames(_ map: MusicalClockMap, _ start: Int64, _ count: Int64,
                               capacity: Int = 64) throws -> [Int64] {
        try MIDIClockPulseSchedule.pulses(in: map, startFrame: start, frameCount: count, capacity: capacity)
            .map(\.frame)
    }

    @Test
    func pulsesFallEveryThousandFramesAtOneTwentyBPMAndFortyEightKilohertz() throws {
        let map = try Self.map()
        let pulses = try MIDIClockPulseSchedule.pulses(in: map, startFrame: 0, frameCount: 4_096, capacity: 8)
        #expect(pulses.map(\.frame) == [0, 1_000, 2_000, 3_000, 4_000])
        #expect(pulses.map(\.ticks) == [0, 640, 1_280, 1_920, 2_560])
        #expect(pulses.map(\.pulseIndex) == [0, 1, 2, 3, 4])
        #expect(try Self.frames(map, 1, 999).isEmpty)
        #expect(try Self.frames(map, 999, 2) == [1_000])
        #expect(try Self.frames(map, 1_000, 1) == [1_000])
    }

    @Test
    func roundedFramesAssignEachPulseToExactlyOneBlock() throws {
        let map = try Self.map(rate: 44_100)
        #expect(try Self.frames(map, 0, 4_000) == [0, 919, 1_838, 2_756, 3_675])
        #expect(try Self.frames(map, 0, 919) == [0])
        #expect(try Self.frames(map, 919, 919) == [919])
        #expect(try Self.frames(map, 1_838, 1) == [1_838])
        var collected: [MIDIClockPulseFrame] = []
        var start: Int64 = 0
        while start < 44_100 {
            collected += try MIDIClockPulseSchedule.pulses(in: map, startFrame: start, frameCount: 64, capacity: 4)
            start += 64
        }
        let whole = try MIDIClockPulseSchedule.pulses(in: map, startFrame: 0, frameCount: start, capacity: 64)
        #expect(collected == whole)
        #expect(whole.count == 49)
        #expect(zip(whole, whole.dropFirst()).allSatisfy { $1.ticks - $0.ticks == 640 && $1.frame > $0.frame })
    }

    @Test
    func temposComeFromTheMapIncludingSegmentChanges() throws {
        let fastest = try Self.map(rate: 192_000, tempos: [(0, 60_000)])
        #expect(try Self.frames(fastest, 0, 4_096, capacity: 9) == Array(stride(from: 0, through: 3_840, by: 480)))
        #expect(throws: MIDIClockError.pulseCapacityExceeded(capacity: 8)) {
            try Self.frames(fastest, 0, 4_096, capacity: 8)
        }
        let twoSegments = try Self.map(tempos: [(0, 500_000), (1_280, 250_000)])
        #expect(try Self.frames(twoSegments, 0, 3_001) == [0, 1_000, 2_000, 2_500, 3_000])
    }

    @Test
    func noPulsesPrecedeMusicalZero() throws {
        let map = try Self.map(anchorFrame: 10_000)
        #expect(try Self.frames(map, 0, 4_096).isEmpty)
        #expect(try Self.frames(map, 9_000, 2_001) == [10_000, 11_000])
        let midSong = try Self.map(anchorTicks: 1_000)
        #expect(try Self.frames(midSong, 0, 438).isEmpty)
        let first = try MIDIClockPulseSchedule.pulses(in: midSong, startFrame: 438, frameCount: 1, capacity: 1)
        #expect(first == [MIDIClockPulseFrame(frame: 438, ticks: 1_280)])
    }

    @Test
    func invalidBlocksAndOverflowAreRefused() throws {
        let map = try Self.map()
        for capacity in [0, 4_097] {
            #expect(throws: MIDIClockError.invalidCapacity(capacity)) { try Self.frames(map, 0, 1, capacity: capacity) }
        }
        #expect(try Self.frames(map, 0, 1, capacity: 4_096) == [0])
        for count: Int64 in [0, -1] {
            #expect(throws: MIDIClockError.invalidBlock(startFrame: 0, frameCount: count)) {
                try Self.frames(map, 0, count)
            }
        }
        #expect(throws: MIDIClockError.invalidBlock(startFrame: .max - 1, frameCount: 2)) {
            try Self.frames(map, .max - 1, 2)
        }
        let late = try Self.map(anchorFrame: .max - 100)
        #expect(throws: MIDIClockError.clockMap(.overflow)) { try Self.frames(late, .max - 1_000, 999) }
    }
}
