import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - MIDICaptureV1Record (#112 MXR1)

extension MIDICaptureExportTests {
    typealias CaptureRefusal = MIDICaptureV1RecordRefusal
    typealias CaptureGolden = [(seq: Int, json: String)]

    /// Example 03's `midiCapture` records (seq 9, 10, 22), keys sorted, compact.
    static let example03V1Captures: CaptureGolden = [
        (9, #"{"effective":"midi1","endpointProtocol":"midi1","frame":191000,"hostTicks":2495500000,"#
            + #""kind":"midiCapture","musicalTicks":122240,"#
            + #""note":"Event before the wrap, delivered after it: it resolves through iteration 0's"#
            + #" anchor.","portProtocol":"midi1","seq":9,"stream":"str.keys-in","translatedBy":"none","#
            + #""ump":["0x20903C64"]}"#),
        (10, #"{"effective":"midi1","endpointProtocol":"midi1","frame":193000,"hostTicks":2496500000,"#
            + #""kind":"midiCapture","musicalTicks":640,"portProtocol":"midi1","seq":10,"#
            + #""stream":"str.keys-in","translatedBy":"none","ump":["0x20803C00"]}"#),
        (22, #"{"effective":"midi1","endpointProtocol":"midi1","frame":211000,"hostTicks":2505500000,"#
            + #""kind":"midiCapture","musicalTicks":62080,"portProtocol":"midi1","seq":22,"#
            + #""stream":"str.keys-in","translatedBy":"none","ump":["0x20903E64"]}"#)
    ]

    /// Example 04's `midiCapture` record (seq 12).
    static let example04V1Captures: CaptureGolden = [
        (12, #"{"effective":"midi1","endpointProtocol":"midi1","frame":168000,"hostTicks":2484000000,"#
            + #""kind":"midiCapture","musicalTicks":107520,"#
            + #""note":"Delivered after the seq 6 anchor: frame 168000 maps back across the 120 BPM segment"#
            + #" to tick 107520; SMF export inverts it through that same anchor.","portProtocol":"midi1","#
            + #""seq":12,"stream":"str.pads-in","translatedBy":"none","ump":["0x20903C64"]}"#)
    ]

    /// Example 09's `midiCapture` records (seq 2–6).
    static let example09V1Captures: CaptureGolden = [
        (2, #"{"effective":"midi1","endpointProtocol":"midi1","frame":24000,"hostTicks":2412000000,"#
            + #""kind":"midiCapture","musicalTicks":2560,"portProtocol":"midi1","seq":2,"#
            + #""stream":"str.keys-a","translatedBy":"none","ump":["0x20903C64"]}"#),
        (3, #"{"effective":"midi1","endpointProtocol":"midi1","frame":48000,"hostTicks":2424000000,"#
            + #""kind":"midiCapture","musicalTicks":5120,"portProtocol":"midi1","seq":3,"#
            + #""stream":"str.keys-a","translatedBy":"none","ump":["0x20803C00"]}"#),
        (4, #"{"effective":"midi1","endpointProtocol":"midi1","frame":72000,"hostTicks":2436000000,"#
            + #""kind":"midiCapture","musicalTicks":7680,"portProtocol":"midi2","seq":4,"#
            + #""stream":"str.keys-b","translatedBy":"os","ump":["0x40903C00","0xC9240000"]}"#),
        (5, #"{"effective":"midi1","endpointProtocol":"midi1","frame":84000,"hostTicks":2442000000,"#
            + #""kind":"midiCapture","musicalTicks":8960,"portProtocol":"midi2","seq":5,"#
            + #""stream":"str.keys-b","translatedBy":"os","ump":["0x40B00700","0x80000000"]}"#),
        (6, #"{"effective":"midi1","endpointProtocol":"midi1","frame":144000,"hostTicks":2472000000,"#
            + #""kind":"midiCapture","musicalTicks":15360,"portProtocol":"midi2","seq":6,"#
            + #""stream":"str.keys-b","translatedBy":"os","ump":["0x40803C00","0x00000000"]}"#)
    ]

    /// Example 10's `midiCapture` records (seq 2–10).
    static let example10V1Captures: CaptureGolden = [
        (2, #"{"effective":"midi2","endpointProtocol":"midi2","frame":24005,"hostTicks":2412002500,"#
            + #""kind":"midiCapture","musicalTicks":15363,"portProtocol":"midi2","seq":2,"#
            + #""stream":"str.synth","translatedBy":"none","ump":["0x41903C03","0xC9251E00"]}"#),
        (3, #"{"effective":"midi2","endpointProtocol":"midi2","frame":36000,"hostTicks":2418000000,"#
            + #""kind":"midiCapture","musicalTicks":23040,"portProtocol":"midi2","seq":3,"#
            + #""stream":"str.synth","translatedBy":"none","ump":["0x41603C00","0x80400000"]}"#),
        (4, #"{"effective":"midi2","endpointProtocol":"midi2","frame":48000,"hostTicks":2424000000,"#
            + #""kind":"midiCapture","musicalTicks":30720,"portProtocol":"midi2","seq":4,"#
            + #""stream":"str.synth","translatedBy":"none","ump":["0x41B04A00","0x9A3C5E71"]}"#),
        (5, #"{"effective":"midi2","endpointProtocol":"midi2","frame":60000,"hostTicks":2430000000,"#
            + #""kind":"midiCapture","musicalTicks":38400,"portProtocol":"midi2","seq":5,"#
            + #""stream":"str.synth","translatedBy":"none","ump":["0x41904000","0x01000000"]}"#),
        (6, #"{"effective":"midi2","endpointProtocol":"midi2","frame":72000,"hostTicks":2436000000,"#
            + #""kind":"midiCapture","musicalTicks":46080,"portProtocol":"midi2","seq":6,"#
            + #""stream":"str.synth","translatedBy":"none","ump":["0x41803C00","0x00000000"]}"#),
        (7, #"{"effective":"midi2","endpointProtocol":"midi2","frame":84000,"hostTicks":2442000000,"#
            + #""kind":"midiCapture","musicalTicks":53760,"portProtocol":"midi2","seq":7,"#
            + #""stream":"str.synth","translatedBy":"none","ump":["0x41804000","0x00000000"]}"#),
        (8, #"{"effective":"midi1","endpointProtocol":"midi2","frame":96000,"hostTicks":2448000000,"#
            + #""kind":"midiCapture","musicalTicks":61440,"portProtocol":"midi1","seq":8,"#
            + #""stream":"str.synth-legacy","translatedBy":"os","ump":["0x21903C64"]}"#),
        (9, #"{"effective":"midi1","endpointProtocol":"unknown","frame":108000,"hostTicks":2454000000,"#
            + #""kind":"midiCapture","musicalTicks":69120,"#
            + #""note":"No endpoint protocol reported: treated as MIDI 1, unverified.","#
            + #""portProtocol":"midi2","seq":9,"stream":"str.synth-unknown","translatedBy":"os","#
            + #""ump":["0x41903C00","0xC9240000"],"verified":false}"#),
        (10, #"{"effective":"midi2","endpointProtocol":"midi2","frame":120000,"hostTicks":2460000000,"#
            + #""kind":"midiCapture","musicalTicks":76800,"#
            + #""note":"MT 0x0 JR Timestamp: no Group field, so it never makes groups look merged.","#
            + #""portProtocol":"midi2","seq":10,"stream":"str.synth","translatedBy":"none","#
            + #""ump":["0x00201F40"]}"#)
    ]

    static func json(_ record: MIDICaptureV1Record) throws -> String {
        try #require(String(data: record.encodedJSON(), encoding: .utf8))
    }

    /// Builds each of `log`'s records, in log order, at its golden's seq with `notes[seq]`, and compares the bytes.
    private func expectV1Captures(_ log: MIDICaptureLog, _ golden: CaptureGolden,
                                  notes: [Int: String] = [:]) throws {
        try #require(log.records.count == golden.count)
        for (capture, expected) in zip(log.records, golden) {
            let record = try MIDICaptureV1Record.make(capture, seq: expected.seq, note: notes[expected.seq])
            #expect(try Self.json(record) == expected.json)
            let again = try MIDICaptureV1Record.make(capture, seq: expected.seq, note: notes[expected.seq])
            #expect(again == record)
            #expect(try again.encodedJSON() == record.encodedJSON())
        }
    }

    private func captureRefusal(_ capture: MIDICaptureRecord, seq: Int = 1, note: String? = nil) -> CaptureRefusal? {
        do {
            _ = try MIDICaptureV1Record.make(capture, seq: seq, note: note)
            return nil
        } catch {
            return error
        }
    }

    /// One capture on `stream` at frame 24 000, without a transport (so without musical ticks).
    private func untimedCapture(stream: String = "str.keys-a") throws -> MIDICaptureRecord {
        let streamID = try StreamID(stream)
        var log = try Fixture.log([streamID])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        try Fixture.capture(&log, streamID, [0x2090_3C64], host: 2_412_000_000)
        return try #require(log.records.first)
    }

    @Test func midiCaptureV1RecordsEncodeExample09Exactly() throws {
        try expectV1Captures(Fixture.example09Captures(), Self.example09V1Captures)
    }

    @Test func midiCaptureV1RecordsEncodeExample10Exactly() throws {
        let log = try Fixture.example10()
        try #require(log.records.count == 9)
        let record = try MIDICaptureV1Record.make(log.records[7], seq: 9)
        #expect(!record.verified && record.endpointProtocol == .unknown && record.translatedBy == "os")
        try expectV1Captures(log, Self.example10V1Captures, notes: [
            9: "No endpoint protocol reported: treated as MIDI 1, unverified.",
            10: "MT 0x0 JR Timestamp: no Group field, so it never makes groups look merged."
        ])
    }

    /// Example 03 through seq 22: a capture before the loop wrap delivered after it, one after it, and one after the
    /// locate on transport 2.
    @Test func midiCaptureV1RecordsEncodeExample03Exactly() throws {
        try expectV1Captures(Fixture.example03(), Self.example03V1Captures, notes: [
            9: "Event before the wrap, delivered after it: it resolves through iteration 0's anchor."
        ])
    }

    /// Example 04 seq 12: delivered after the tempo edit's anchor, mapped through the first anchor and revision 2.
    @Test func midiCaptureV1RecordsEncodeExample04Exactly() throws {
        let padsIn = StreamID(validated: "str.pads-in")
        var log = try Fixture.log([padsIn])
        let first = try Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1)
        try log.observe(anchor: first)
        let revision = try Generation(2)
        try log.observe(anchor: ClockAnchor(
            sample: SampleStamp(clock: Fixture.clock, generation: .initial, frame: 192_000),
            host: HostStamp(ticks: 2_496_000_000),
            musical: MusicalStamp(transport: .initial, musicalMap: revision, ticks: 122_880, loopIteration: 0)))
        let edited = try MusicalMap(clock: Fixture.musicalClock, revision: revision,
                                    segments: [TempoSegment(atTicks: 0, microsPerQuarter: 500_000),
                                               TempoSegment(atTicks: 122_880, microsPerQuarter: 400_000)])
        let map = try MusicalClockMap(anchor: first, map: edited, nominalRate: 48_000, currentSample: .initial,
                                      currentTransport: .initial)
        _ = try log.capture([0x2090_3C64], stream: padsIn, host: HostStamp(ticks: 2_484_000_000), endpoint: .midi1,
                            port: .midi1, musicalMap: map, current: .initial)
        try expectV1Captures(log, Self.example04V1Captures, notes: [
            12: "Delivered after the seq 6 anchor: frame 168000 maps back across the 120 BPM segment to tick 107520; "
                + "SMF export inverts it through that same anchor."
        ])
    }

    @Test func midiCaptureV1RecordOmitsAbsentTicksAndTrueVerified() throws {
        let record = try MIDICaptureV1Record.make(untimedCapture(), seq: 1)
        #expect(record.musicalTicks == nil && record.verified && record.note == nil)
        #expect(try Self.json(record)
            == #"{"effective":"midi1","endpointProtocol":"midi1","frame":24000,"hostTicks":2412000000,"#
            + #""kind":"midiCapture","portProtocol":"midi1","seq":1,"stream":"str.keys-a","translatedBy":"none","#
            + #""ump":["0x20903C64"]}"#)
    }

    @Test func midiCaptureV1RecordReportsTheFirstRefusalInFixedOrder() throws {
        let badStream = try untimedCapture(stream: "str_a")
        #expect(captureRefusal(badStream, seq: 0, note: "") == CaptureRefusal.invalidSeq(0))
        #expect(captureRefusal(badStream, seq: Int.min) == CaptureRefusal.invalidSeq(Int.min))
        #expect(captureRefusal(badStream, note: "") == CaptureRefusal.invalidStream(try StreamID("str_a")))
        #expect(captureRefusal(try untimedCapture(stream: "STR.keys")) == .invalidStream(try StreamID("STR.keys")))

        let good = try untimedCapture()
        #expect(captureRefusal(good, note: "") == CaptureRefusal.invalidNote(bytes: 0))
        #expect(captureRefusal(good, note: " \n\t") == CaptureRefusal.invalidNote(bytes: 3))
        let limit = MIDICaptureV1Record.maximumNoteBytes
        #expect(limit == 256)
        #expect(captureRefusal(good, note: String(repeating: "a", count: limit + 1))
            == CaptureRefusal.invalidNote(bytes: 257))
        #expect(captureRefusal(good, note: String(repeating: "é", count: 129))
            == CaptureRefusal.invalidNote(bytes: 258))
        #expect(captureRefusal(good, note: String(repeating: "a", count: limit)) == nil)
        #expect(captureRefusal(good, seq: Int.max, note: nil) == nil)
    }

    @Test func midiCaptureV1RecordNeverNormalizesNoteText() throws {
        let capture = try untimedCapture()
        let precomposed = try MIDICaptureV1Record.make(capture, seq: 1, note: "\u{00E9}")
        let decomposed = try MIDICaptureV1Record.make(capture, seq: 1, note: "e\u{0301}")
        #expect(precomposed == decomposed)
        #expect(try precomposed.encodedJSON() != decomposed.encodedJSON())
        #expect(try Self.json(decomposed).contains("\"note\":\"e\u{0301}\""))
    }

    /// A 4-word MT 0xF packet delivered late (negative frame) and a capture at `UInt64.max` host ticks, both
    /// through an anchor at `UInt64.max` with 1 ns per tick.
    @Test func midiCaptureV1RecordEncodesFourWordsAndExtremeStampsExactly() throws {
        var log = try Fixture.log([Fixture.keysA], timebase: HostTimebase(numer: 1, denom: 1))
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: UInt64.max))
        try Fixture.capture(&log, Fixture.keysA, [0xF000_0101, 0x0000_00AB, 0x0000_0000, 0xFFFF_FFFF],
                            host: UInt64.max - 500_000_000)
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: UInt64.max)
        try #require(log.records.count == 2)
        let late = try MIDICaptureV1Record.make(log.records[0], seq: 1)
        #expect(late.ump.count == 4 && late.frame == -24_000)
        #expect(try Self.json(late)
            == #"{"effective":"midi1","endpointProtocol":"midi1","frame":-24000,"hostTicks":18446744073209551615,"#
            + #""kind":"midiCapture","portProtocol":"midi1","seq":1,"stream":"str.keys-a","translatedBy":"none","#
            + #""ump":["0xF0000101","0x000000AB","0x00000000","0xFFFFFFFF"]}"#)
        #expect(try Self.json(MIDICaptureV1Record.make(log.records[1], seq: 2))
            == #"{"effective":"midi1","endpointProtocol":"midi1","frame":0,"hostTicks":18446744073709551615,"#
            + #""kind":"midiCapture","portProtocol":"midi1","seq":2,"stream":"str.keys-a","translatedBy":"none","#
            + #""ump":["0x20903C64"]}"#)
    }
}
