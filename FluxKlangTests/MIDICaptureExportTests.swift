import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixtures of the #112 CL4 capture suites. Its name is lane-unique because every test file shares one module.
enum MIDICaptureFixture {
    static let clock = ClockID(validated: "smp.main")
    static let musicalClock = ClockID(validated: "mus.main")
    /// Example 09 and 10: 125/3 ns per host tick.
    static let timebase = HostTimebase(numer: 125, denom: 3)
    static let keysA = StreamID(validated: "str.keys-a")
    static let keysB = StreamID(validated: "str.keys-b")
    static let idle = StreamID(validated: "str.idle")
    static let synth = StreamID(validated: "str.synth")
    static let legacy = StreamID(validated: "str.synth-legacy")
    static let unknown = StreamID(validated: "str.synth-unknown")
    static let umpExport = ExportID(validated: "exp.ump")

    static func log(_ streams: [StreamID], timebase: HostTimebase = timebase,
                    nominalRate: Int = 48_000) throws -> MIDICaptureLog {
        try MIDICaptureLog(streams: streams, clock: clock, timebase: timebase, nominalRate: nominalRate)
    }

    /// An anchor of `smp.main`; with `transport`, it also anchors `mus.main` at `ticks`.
    static func anchor(_ generation: Int, frame: Int64, host: UInt64, transport: Int? = nil,
                       ticks: Int64 = 0) throws -> ClockAnchor {
        let musical = try transport.map {
            MusicalStamp(transport: try Generation($0), musicalMap: .initial, ticks: ticks, loopIteration: 0)
        }
        return ClockAnchor(sample: SampleStamp(clock: clock, generation: try Generation(generation), frame: frame),
                           host: HostStamp(ticks: host), musical: musical)
    }

    static func discontinuity(_ kind: RuntimeDiscontinuityKind, generation: UInt64 = 1,
                              frame: Int64 = 0, host: UInt64?) -> RuntimeDiscontinuity {
        RuntimeDiscontinuity(kind: kind, sample: RuntimeSampleStamp(clock: 0, generation: generation, frame: frame),
                             frames: nil, stream: nil, host: host.map { HostStamp(ticks: $0) })
    }

    static func restart(_ generation: UInt64, host: UInt64?, frame: Int64 = 0) -> RuntimeDiscontinuity {
        discontinuity(.clockRestart(previousFrame: 0), generation: generation, frame: frame, host: host)
    }

    /// A one-segment musical map through `anchor`, which must carry a musical stamp.
    static func musicalMap(_ anchor: ClockAnchor, microsPerQuarter: Int64,
                           nominalRate: Int = 48_000) throws -> MusicalClockMap {
        let map = try MusicalMap(clock: musicalClock, revision: .initial,
                                 segments: [TempoSegment(atTicks: 0, microsPerQuarter: microsPerQuarter)])
        let musical = try #require(anchor.musical)
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: nominalRate,
                                   currentSample: anchor.sample.generation, currentTransport: musical.transport)
    }

    /// Captures in the current generation, through a musical map on the current anchor (at the current generation's
    /// rate) when it carries a transport.
    @discardableResult
    static func capture(_ log: inout MIDICaptureLog, _ stream: StreamID, _ words: [UInt32], host: UInt64,
                        endpoint: MIDIEndpointProtocol = .midi1, port: MIDIPortProtocol = .midi1,
                        microsPerQuarter: Int64 = 3_000_000) throws -> MIDICaptureOutcome {
        let anchor = try #require(log.currentAnchor)
        let map = try anchor.musical.map { _ in
            try musicalMap(anchor, microsPerQuarter: microsPerQuarter, nominalRate: log.nominalRate)
        }
        return try log.capture(words, stream: stream, host: HostStamp(ticks: host), endpoint: endpoint, port: port,
                               musicalMap: map, current: anchor.sample.generation)
    }

    static func refusal(_ body: () throws -> some Any) -> MIDICaptureRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? MIDICaptureRefusal
        }
    }

    static func origin(_ generation: Int, frame: Int64) throws -> SampleStamp {
        SampleStamp(clock: clock, generation: try Generation(generation), frame: frame)
    }

    /// Example 09 through seq 6: two streams, five captures, before the restart.
    static func example09Captures() throws -> MIDICaptureLog {
        var log = try log([keysA, keysB])
        try log.observe(anchor: anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try capture(&log, keysA, [0x2090_3C64], host: 2_412_000_000)
        try capture(&log, keysA, [0x2080_3C00], host: 2_424_000_000)
        try capture(&log, keysB, [0x4090_3C00, 0xC924_0000], host: 2_436_000_000, port: .midi2)
        try capture(&log, keysB, [0x40B0_0700, 0x8000_0000], host: 2_442_000_000, port: .midi2)
        try capture(&log, keysB, [0x4080_3C00, 0x0000_0000], host: 2_472_000_000, port: .midi2)
        return log
    }

    /// Example 09 seq 8 and 10: the device restart and generation 2's anchor.
    static func restartExample09(_ log: inout MIDICaptureLog) throws {
        try log.observe(restart(2, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
        try log.observe(anchor: anchor(2, frame: 0, host: 2_490_000_000, transport: 2, ticks: 16_000))
    }

    static let example09Offsets: [Int64] = [500_000_000, 1_000_000_000, 1_500_000_000, 1_750_000_000, 3_000_000_000]

    /// Example 10 through seq 10: three streams at 120 BPM, nine captures.
    static func example10() throws -> MIDICaptureLog {
        var log = try log([synth, legacy, unknown])
        try log.observe(anchor: anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        let synthWords: [(UInt64, [UInt32])] = [
            (2_412_002_500, [0x4190_3C03, 0xC925_1E00]), (2_418_000_000, [0x4160_3C00, 0x8040_0000]),
            (2_424_000_000, [0x41B0_4A00, 0x9A3C_5E71]), (2_430_000_000, [0x4190_4000, 0x0100_0000]),
            (2_436_000_000, [0x4180_3C00, 0x0000_0000]), (2_442_000_000, [0x4180_4000, 0x0000_0000])]
        for (host, words) in synthWords {
            try capture(&log, synth, words, host: host, endpoint: .midi2, port: .midi2, microsPerQuarter: 500_000)
        }
        try capture(&log, legacy, [0x2190_3C64], host: 2_448_000_000, endpoint: .midi2, port: .midi1,
                    microsPerQuarter: 500_000)
        try capture(&log, unknown, [0x4190_3C00, 0xC924_0000], host: 2_454_000_000, endpoint: .unknown, port: .midi2,
                    microsPerQuarter: 500_000)
        try capture(&log, synth, [0x0020_1F40], host: 2_460_000_000, endpoint: .midi2, port: .midi2,
                    microsPerQuarter: 500_000)
        return log
    }
}

#if os(macOS)
@Suite("MIDI capture export", .productionAccessAudit)
#else
@Suite("MIDI capture export")
#endif
struct MIDICaptureExportTests {
    typealias Fixture = MIDICaptureFixture

    @Test func example09RecordsKeepWordsStampsAndDeliveryOrder() throws {
        let log = try Fixture.example09Captures()
        #expect(log.records.map(\.stream) == [Fixture.keysA, Fixture.keysA, Fixture.keysB, Fixture.keysB,
                                              Fixture.keysB])
        #expect(log.records.map(\.packet.words) == [[0x2090_3C64], [0x2080_3C00], [0x4090_3C00, 0xC924_0000],
                                                    [0x40B0_0700, 0x8000_0000], [0x4080_3C00, 0x0000_0000]])
        #expect(log.records.map(\.sample.frame) == [24_000, 48_000, 72_000, 84_000, 144_000])
        #expect(log.records.allSatisfy { $0.sample.clock == Fixture.clock && $0.sample.generation == .initial })
        #expect(log.records.map(\.musicalTicks) == [2_560, 5_120, 7_680, 8_960, 15_360])
        #expect(log.records.map(\.host.ticks) == [2_412_000_000, 2_424_000_000, 2_436_000_000, 2_442_000_000,
                                                  2_472_000_000])
        #expect(log.records.map(\.protocolStamp.translatedByOS) == [false, false, true, true, true])
        #expect(log.records.allSatisfy { $0.protocolStamp.effective == .midi1 && $0.protocolStamp.verified })
        #expect(log.unsupported.isEmpty && log.taints.isEmpty)
    }

    @Test func example09NativeExportIsUnchangedByTheRestart() throws {
        var log = try Fixture.example09Captures()
        let origin = try Fixture.origin(1, frame: 0)
        let before = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA, Fixture.keysB],
                                              origin: origin)
        try Fixture.restartExample09(&log)
        let after = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA, Fixture.keysB],
                                             origin: origin)
        #expect(after == before)
        #expect(after.offsetsNs == Fixture.example09Offsets)
        #expect(after.packets == log.records.map(\.packet))
        #expect(after.packets.map(\.words) == log.records.map(\.packet.words))
        #expect(after.lossless)
        #expect(after.id == Fixture.umpExport && after.origin == origin)
        #expect(after.streams == [Fixture.keysA, Fixture.keysB])
    }

    @Test func exportFollowsCaptureOrderNotHostOrder() throws {
        var log = try Fixture.log([Fixture.keysA, Fixture.keysB])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        try Fixture.capture(&log, Fixture.keysB, [0x2090_3C64], host: 2_436_000_000)
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3D64], host: 2_412_000_000)
        try Fixture.capture(&log, Fixture.keysB, [0x2080_3C00], host: 2_424_000_000)
        try Fixture.capture(&log, Fixture.keysA, [0x2080_3D00], host: 2_472_000_000)
        let both = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysB, Fixture.keysA],
                                            origin: Fixture.origin(1, frame: 0))
        #expect(both.offsetsNs == [1_500_000_000, 500_000_000, 1_000_000_000, 3_000_000_000])
        #expect(both.packets.map(\.words) == [[0x2090_3C64], [0x2090_3D64], [0x2080_3C00], [0x2080_3D00]])
        let onlyA = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA],
                                             origin: Fixture.origin(1, frame: 0))
        #expect(onlyA.offsetsNs == [500_000_000, 3_000_000_000])
        #expect(onlyA.packets.map(\.words) == [[0x2090_3D64], [0x2080_3D00]])
    }

    @Test func originBindsToTheGenerationsFirstAnchor() throws {
        var log = try Fixture.example09Captures()
        // A later generation-1 anchor, 1 frame off the nominal prediction: it becomes current, never the origin's.
        try log.observe(anchor: Fixture.anchor(1, frame: 120_001, host: 2_460_000_000, transport: 1, ticks: 12_800))
        #expect(log.currentAnchor?.sample.frame == 120_001)
        #expect(log.firstAnchors[.initial]?.sample.frame == 0)
        let export = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA, Fixture.keysB],
                                              origin: Fixture.origin(1, frame: 0))
        #expect(export.offsetsNs == Fixture.example09Offsets)
    }

    @Test func originInGenerationTwoUsesThatGenerationsAnchor() throws {
        var log = try Fixture.example09Captures()
        try Fixture.restartExample09(&log)
        let export = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA, Fixture.keysB],
                                              origin: Fixture.origin(2, frame: 0))
        #expect(export.offsetsNs == [-3_250_000_000, -2_750_000_000, -2_250_000_000, -2_000_000_000, -750_000_000])
    }

    @Test func originFrameIsMeasuredFromItsAnchorsFrame() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 96_000, host: 2_400_000_000))
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_412_000_000)
        #expect(log.records.map(\.sample.frame) == [120_000])
        let atAnchor = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA],
                                                origin: Fixture.origin(1, frame: 96_000))
        let atCapture = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA],
                                                 origin: Fixture.origin(1, frame: 120_000))
        #expect(atAnchor.offsetsNs == [500_000_000] && atCapture.offsetsNs == [0])
    }

    @Test func exportRefusalsNameTheirCause() throws {
        var log = try Fixture.log([Fixture.keysA, Fixture.keysB, Fixture.idle])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_412_000_000)
        let origin = try Fixture.origin(1, frame: 0)
        func make(_ streams: [StreamID], _ origin: SampleStamp) -> MIDICaptureRefusal? {
            Fixture.refusal {
                try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: streams, origin: origin)
            }
        }
        #expect(make([], origin) == .exportStreamsEmpty)
        #expect(make([Fixture.keysA, Fixture.keysA], origin) == .exportStreamsDuplicate(Fixture.keysA))
        #expect(make([Fixture.keysA, Fixture.synth], origin) == .undeclaredStream(Fixture.synth))
        #expect(make([Fixture.idle], origin) == .exportHasNoCaptures)
        #expect(make([Fixture.keysB, Fixture.idle], origin) == .exportHasNoCaptures)
        let unknown = try Fixture.origin(2, frame: 0)
        #expect(make([Fixture.keysA], unknown) == .originAnchorUnknown(clock: Fixture.clock,
                                                                       generation: unknown.generation))
        let foreign = SampleStamp(clock: ClockID(validated: "smp.other"), generation: .initial, frame: 0)
        #expect(make([Fixture.keysA], foreign) == .originAnchorUnknown(clock: foreign.clock, generation: .initial))
        #expect(make([Fixture.keysA, Fixture.idle], origin) == nil)
    }

    // MARK: - NativeUMPExportV1Record (#112 NXR1)

    typealias RecordRefusal = NativeUMPExportV1RecordRefusal

    /// Example 09's `exp.ump` record (seq 12), keys sorted, compact.
    static let example09NativeJSON = #"{"exportId":"exp.ump","format":"nativeUmp","kind":"export","losses":{},"#
        + #""lossless":true,"offsetsNs":[500000000,1000000000,1500000000,1750000000,3000000000],"#
        + #""origin":{"frame":0,"generation":1,"sampleClock":"smp.main"},"seq":12,"#
        + #""streams":["str.keys-a","str.keys-b"]}"#

    static func json(_ record: NativeUMPExportV1Record) throws -> String {
        try #require(String(data: record.encodedJSON(), encoding: .utf8))
    }

    private func recordRefusal(_ export: NativeUMPExport, seq: Int = 1, note: String? = nil) -> RecordRefusal? {
        do {
            _ = try NativeUMPExportV1Record.make(export, seq: seq, note: note)
            return nil
        } catch {
            return error
        }
    }

    /// A one-capture export with the given IDs, which `ContractID` admits but v1 may not. The capture is at frame
    /// 24 000, so its offset is 500 ms from the default origin and negative from an origin after it.
    private func idExport(id: String = "exp.ump", streams: [String] = ["str.keys-a"], clock: String = "smp.main",
                          originFrame: Int64 = 0) throws -> NativeUMPExport {
        let streamIDs = try streams.map { try StreamID($0) }
        let start = SampleStamp(clock: try ClockID(clock), generation: .initial, frame: 0)
        var log = try MIDICaptureLog(streams: streamIDs, clock: start.clock, timebase: Fixture.timebase,
                                     nominalRate: 48_000)
        try log.observe(anchor: ClockAnchor(sample: start, host: HostStamp(ticks: 2_400_000_000), musical: nil))
        let first = try #require(streamIDs.first)
        try Fixture.capture(&log, first, [0x2090_3C64], host: 2_412_000_000)
        let origin = SampleStamp(clock: start.clock, generation: .initial, frame: originFrame)
        return try NativeUMPExport.make(from: log, id: ExportID(id), streams: streamIDs, origin: origin)
    }

    @Test func nativeUMPExportV1RecordEncodesExample09Exactly() throws {
        var log = try Fixture.example09Captures()
        try Fixture.restartExample09(&log)
        let export = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA, Fixture.keysB],
                                              origin: Fixture.origin(1, frame: 0))
        let record = try NativeUMPExportV1Record.make(export, seq: 12)
        #expect(record.offsetsNs == Fixture.example09Offsets)
        #expect(record.lossless && record.losses.isEmpty && record.note == nil)
        let text = try Self.json(record)
        #expect(text == Self.example09NativeJSON)
        #expect(!text.contains(#""division""#) && !text.contains(#""smfFormat""#) && !text.contains(#""note""#))

        let again = try NativeUMPExportV1Record.make(export, seq: 12)
        #expect(again == record)
        #expect(try again.encodedJSON() == record.encodedJSON())
    }

    @Test func nativeUMPExportV1RecordIsLosslessExactlyWhenItHasNoLosses() throws {
        let record = try NativeUMPExportV1Record.make(idExport(), seq: 1, note: "Take start.")
        #expect(record.lossless == record.losses.isEmpty)
        #expect(record.lossless)
        let text = try Self.json(record)
        #expect(text.contains(#""losses":{},"lossless":true,"#))
        #expect(text.contains(#""note":"Take start.","#))
    }

    @Test func nativeUMPExportV1RecordReportsTheFirstRefusalInFixedOrder() throws {
        let allBad = try idExport(id: "EXP.ump", streams: ["str.ok", "str_a", "STR.b"], clock: "smp:main")
        #expect(recordRefusal(allBad, seq: 0, note: "") == RecordRefusal.invalidSeq(0))
        #expect(recordRefusal(allBad, seq: Int.min) == RecordRefusal.invalidSeq(Int.min))
        #expect(recordRefusal(allBad, note: "") == RecordRefusal.invalidExportID(try ExportID("EXP.ump")))
        let badStreams = try idExport(streams: ["str.ok", "str_a", "STR.b"], clock: "smp:main")
        #expect(recordRefusal(badStreams, note: "") == RecordRefusal.invalidStream(try StreamID("str_a")))
        let badClock = try idExport(clock: "smp:main")
        #expect(recordRefusal(badClock, note: "") == RecordRefusal.invalidOriginClock(try ClockID("smp:main")))
        let badClockNegative = try idExport(clock: "smp:main", originFrame: 48_000)
        #expect(badClockNegative.offsetsNs == [-500_000_000])
        #expect(recordRefusal(badClockNegative, note: "")
            == RecordRefusal.invalidOriginClock(try ClockID("smp:main")))
        let negative = try idExport(originFrame: 48_000)
        #expect(recordRefusal(negative, note: "") == RecordRefusal.negativeOffset(index: 0, offsetNs: -500_000_000))

        var restarted = try Fixture.example09Captures()
        try Fixture.restartExample09(&restarted)
        let later = try NativeUMPExport.make(from: restarted, id: Fixture.umpExport, streams: [Fixture.keysA],
                                             origin: Fixture.origin(2, frame: 0))
        #expect(recordRefusal(later, note: "") == RecordRefusal.negativeOffset(index: 0, offsetNs: -3_250_000_000))

        let good = try idExport()
        #expect(recordRefusal(good, note: "") == RecordRefusal.invalidNote(bytes: 0))
        #expect(recordRefusal(good, note: " \n\t") == RecordRefusal.invalidNote(bytes: 3))
        let limit = NativeUMPExportV1Record.maximumNoteBytes
        #expect(limit == 256)
        #expect(recordRefusal(good, note: String(repeating: "a", count: limit + 1))
            == RecordRefusal.invalidNote(bytes: 257))
        #expect(recordRefusal(good, note: String(repeating: "é", count: 129))
            == RecordRefusal.invalidNote(bytes: 258))
        #expect(recordRefusal(good, note: String(repeating: "a", count: limit)) == nil)
        #expect(recordRefusal(good, seq: 1, note: nil) == nil)
    }

    @Test func nativeUMPExportV1RecordNamesTheFirstNegativeOffsetInCaptureOrder() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        for host: UInt64 in [2_436_000_000, 2_412_000_000, 2_424_000_000, 2_400_000_000] {
            try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: host)
        }
        let export = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA],
                                              origin: Fixture.origin(1, frame: 48_000))
        #expect(export.offsetsNs == [500_000_000, -500_000_000, 0, -1_000_000_000])
        #expect(recordRefusal(export) == RecordRefusal.negativeOffset(index: 1, offsetNs: -500_000_000))
        let atZero = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA],
                                              origin: Fixture.origin(1, frame: 0))
        let record = try NativeUMPExportV1Record.make(atZero, seq: 3)
        #expect(record.offsetsNs == [1_500_000_000, 500_000_000, 1_000_000_000, 0])
    }
}
