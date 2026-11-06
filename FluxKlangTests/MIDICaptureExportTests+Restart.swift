import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI capture restart and bounds")
struct MIDICaptureRestartTests {
    typealias Fixture = MIDICaptureFixture

    static func export(_ log: MIDICaptureLog, _ streams: [StreamID], generation: Int = 1,
                       frame: Int64 = 0) throws -> NativeUMPExport {
        try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: streams,
                                 origin: Fixture.origin(generation, frame: frame))
    }

    @Test func example10OffsetsFromOriginFrame24000() throws {
        let log = try Fixture.example10()
        let export = try Self.export(log, [Fixture.synth], frame: 24_000)
        #expect(export.offsetsNs == [104_167, 250_000_000, 500_000_000, 750_000_000, 1_000_000_000, 1_250_000_000,
                                     2_000_000_000])
        #expect(export.packets.map(\.words) == log.records.filter { $0.stream == Fixture.synth }.map(\.packet.words))
        #expect(export.packets.last?.words == [0x0020_1F40])
        let all = try Self.export(log, [Fixture.synth, Fixture.legacy, Fixture.unknown], frame: 24_000)
        #expect(all.offsetsNs.count == 9 && all.offsetsNs[6...] == [1_500_000_000, 1_750_000_000, 2_000_000_000])
    }

    @Test func captureStampedOneTickBeforeTheRestartIsUnsupported() throws {
        var log = try Fixture.example09Captures()
        try Fixture.restartExample09(&log)
        let records = log.records
        let outcome = try Fixture.capture(&log, Fixture.keysA, [0x2090_3E64], host: 2_489_999_999)
        let restart = HostStamp(ticks: 2_490_000_000)
        #expect(outcome == .unsupported(.predatesClockRestart(restart: restart)))
        #expect(log.records == records)
        let entry = try #require(log.unsupported.first)
        #expect(log.unsupported.count == 1)
        #expect(entry.stream == Fixture.keysA && entry.packet.words == [0x2090_3E64])
        #expect(entry.host.ticks == 2_489_999_999 && entry.reason == .predatesClockRestart(restart: restart))
        #expect(log.taints == [Fixture.keysA: .unsupportedCapture])
        #expect(Fixture.refusal { try Self.export(log, [Fixture.keysA, Fixture.keysB]) }
            == .containsUnsupportedCapture(stream: Fixture.keysA))
        #expect(Fixture.refusal { try Self.export(log, [Fixture.keysB, Fixture.keysA], generation: 2) }
            == .containsUnsupportedCapture(stream: Fixture.keysA))
        #expect(try Self.export(log, [Fixture.keysB]).offsetsNs == [1_500_000_000, 1_750_000_000, 3_000_000_000])
    }

    @Test func captureAtTheRestartsHostTicksIsAccepted() throws {
        var log = try Fixture.example09Captures()
        try Fixture.restartExample09(&log)
        let outcome = try Fixture.capture(&log, Fixture.keysA, [0x2090_3E64], host: 2_490_000_000)
        let record = try #require(log.records.last)
        #expect(outcome == .recorded(record))
        let two = try Generation(2)
        #expect(record.sample == SampleStamp(clock: Fixture.clock, generation: two, frame: 0))
        #expect(record.musicalTicks == 16_000)
        #expect(log.unsupported.isEmpty && log.taints.isEmpty)
        #expect(try Self.export(log, [Fixture.keysA]).offsetsNs == [500_000_000, 1_000_000_000, 3_750_000_000])
    }

    @Test func restartWithoutANewAnchorStillReportsOldStamps() throws {
        var log = try Fixture.example09Captures()
        let anchor = try #require(log.currentAnchor)
        try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
        let two = try Generation(2)
        #expect(log.currentAnchor == nil && log.currentGeneration == two && log.transport == nil)
        func capture(_ host: UInt64, current: Generation) throws -> MIDICaptureOutcome {
            try log.capture([0x2090_3E64], stream: Fixture.keysA, host: HostStamp(ticks: host), endpoint: .midi1,
                            port: .midi1, musicalMap: nil, current: current)
        }
        let before = log
        #expect(Fixture.refusal { try capture(2_490_000_000, current: two) } == .noCurrentAnchor)
        // The ended generation is stale, on the recorded and the unsupported path alike.
        #expect(Fixture.refusal { try capture(2_490_000_000, current: .initial) } == .staleGeneration)
        #expect(Fixture.refusal { try capture(2_480_000_000, current: .initial) } == .staleGeneration)
        #expect(log == before)
        #expect(try capture(2_480_000_000, current: two) == .unsupported(.predatesClockRestart(
            restart: HostStamp(ticks: 2_490_000_000))))
        // An anchor of the ended generation is stale now; one of the new generation re-anchors.
        #expect(Fixture.refusal { try log.observe(anchor: anchor) } == .staleGeneration)
        try log.observe(anchor: Fixture.anchor(2, frame: 0, host: 2_490_000_000))
        let outcome = try capture(2_490_000_000, current: two)
        let record = try #require(log.records.last)
        #expect(outcome == .recorded(record))
    }

    @Test func captureStampedBeforeALocateIsUnsupported() throws {
        var log = try Fixture.example09Captures()
        try log.observe(Fixture.discontinuity(.locate, host: 2_480_000_000), stream: nil)
        #expect(log.transport == nil)
        let outcome = try Fixture.capture(&log, Fixture.keysB, [0x4090_3C00, 0xC924_0000], host: 2_479_999_999,
                                          port: .midi2)
        #expect(outcome == .unsupported(.predatesLocate(locate: HostStamp(ticks: 2_480_000_000))))
        #expect(log.taints == [Fixture.keysB: .unsupportedCapture])
        #expect(Fixture.refusal { try Self.export(log, [Fixture.keysB]) } == .containsUnsupportedCapture(
            stream: Fixture.keysB))
        // Until the transport re-anchors, captures at or after the locate carry no musical ticks.
        let anchor = try #require(log.currentAnchor)
        let map = try Fixture.musicalMap(anchor, microsPerQuarter: 3_000_000)
        func capture(_ map: MusicalClockMap?) throws -> MIDICaptureOutcome {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 2_480_000_000),
                            endpoint: .midi1, port: .midi1, musicalMap: map, current: .initial)
        }
        let before = log
        #expect(Fixture.refusal { try capture(map) } == .musicalMapMismatch)
        #expect(log == before)
        _ = try capture(nil)
        #expect(log.records.last?.musicalTicks == nil && log.records.last?.sample.frame == 160_000)
        // A transport anchor of the new transport generation brings musical ticks back.
        try log.observe(anchor: Fixture.anchor(1, frame: 160_000, host: 2_480_000_000, transport: 2, ticks: 0))
        try Fixture.capture(&log, Fixture.keysA, [0x2080_3C00], host: 2_484_000_000)
        #expect(log.records.last?.musicalTicks == 853)
        #expect(Fixture.refusal { try capture(map) } == .musicalMapMismatch)
    }

    @Test func musicalTicksExactlyWhenATransportIsAnchored() throws {
        var log = try Fixture.log([Fixture.keysA])
        let plain = try Fixture.anchor(1, frame: 0, host: 2_400_000_000)
        let musical = try Fixture.anchor(1, frame: 48_000, host: 2_424_000_000, transport: 1)
        let map = try Fixture.musicalMap(musical, microsPerQuarter: 3_000_000)
        func capture(_ map: MusicalClockMap?, host: UInt64 = 2_436_000_000) throws -> MIDICaptureOutcome {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: host),
                            endpoint: .midi1, port: .midi1, musicalMap: map, current: .initial)
        }
        try log.observe(anchor: plain)
        #expect(Fixture.refusal { try capture(map) } == .musicalMapMismatch)
        _ = try capture(nil)
        #expect(log.records.last?.musicalTicks == nil)
        try log.observe(anchor: musical)
        let before = log
        #expect(Fixture.refusal { try capture(nil) } == .musicalMapMismatch)
        let otherTransport = try Fixture.musicalMap(Fixture.anchor(1, frame: 48_000, host: 2_424_000_000, transport: 2),
                                                    microsPerQuarter: 3_000_000)
        #expect(Fixture.refusal { try capture(otherTransport) } == .musicalMapMismatch)
        let otherClock = ClockAnchor(sample: SampleStamp(clock: ClockID(validated: "smp.other"), generation: .initial,
                                                         frame: 0), host: musical.host, musical: musical.musical)
        #expect(Fixture.refusal { try capture(Fixture.musicalMap(otherClock, microsPerQuarter: 3_000_000)) }
            == .musicalMapMismatch)
        #expect(log == before)
        _ = try capture(map)
        #expect(log.records.last?.musicalTicks == 2_560)
        // An anchor without a musical stamp keeps the transport anchored.
        try log.observe(anchor: Fixture.anchor(1, frame: 96_000, host: 2_448_000_000))
        _ = try capture(map, host: 2_460_000_000)
        #expect(log.records.map(\.musicalTicks) == [nil, 2_560, 7_680])
    }

    @Test func delayedCaptureBeforeMusicalAnchorRefusesNegativeTicks() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 48_000, host: 24_000_000, transport: 1))
        let before = log

        #expect(Fixture.refusal {
            try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 0)
        } == .negativeMusicalTicks)
        #expect(log == before)
        #expect(log.records.isEmpty)
    }

    @Test func delayedDeliveryWithinAGenerationDerivesThroughTheCurrentAnchor() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_436_000_000)
        try log.observe(anchor: Fixture.anchor(1, frame: 120_002, host: 2_460_000_000))
        let outcome = try Fixture.capture(&log, Fixture.keysA, [0x2080_3C00], host: 2_412_000_000)
        let record = try #require(log.records.last)
        #expect(outcome == .recorded(record))
        #expect(log.records.map(\.sample.frame) == [72_000, 24_002])
        #expect(try Self.export(log, [Fixture.keysA]).offsetsNs == [1_500_000_000, 500_000_000])
    }

    @Test func offsetsRoundHalfUpIncludingNegativeHalves() throws {
        // 1/2 ns per tick: odd tick distances land exactly on .5 ns.
        var log = try Fixture.log([Fixture.keysA], timebase: HostTimebase(numer: 1, denom: 2))
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 1_000))
        for host: UInt64 in [1_001, 999, 997, 1_003] {
            try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: host)
        }
        #expect(try Self.export(log, [Fixture.keysA]).offsetsNs == [1, 0, -1, 2])
        // 1/5 ns per tick: -0.6 ns rounds to -1 and 0.4 ns to 0.
        var fifths = try Fixture.log([Fixture.keysA], timebase: HostTimebase(numer: 1, denom: 5))
        try fifths.observe(anchor: Fixture.anchor(1, frame: 0, host: 1_000))
        for host: UInt64 in [997, 1_002, 1_008] {
            try Fixture.capture(&fifths, Fixture.keysA, [0x2090_3C64], host: host)
        }
        #expect(try Self.export(fifths, [Fixture.keysA]).offsetsNs == [-1, 0, 2])
    }

    @Test func overflowIsRefused() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: .max - 10, host: 0))
        let before = log
        #expect(Fixture.refusal { try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 1_000_000_000) }
            == .overflow)
        #expect(log == before)
        // Musical ticks: 4.8e18 frames at 60,000 µs per quarter is 2.56e19 ticks.
        var fast = try Fixture.log([Fixture.keysA], timebase: HostTimebase(numer: 1_000_000, denom: 1))
        try fast.observe(anchor: Fixture.anchor(1, frame: 0, host: 0, transport: 1))
        #expect(Fixture.refusal {
            try Fixture.capture(&fast, Fixture.keysA, [0x2090_3C64], host: 100_000_000_000_000_000,
                                microsPerQuarter: 60_000)
        } == .overflow)
        #expect(fast.records.isEmpty)
        // Offsets: 2⁶³ + 1000 ns does not fit in Int64, though its frame does.
        var wide = try Fixture.log([Fixture.keysA], timebase: HostTimebase(numer: 1, denom: 1))
        try wide.observe(anchor: Fixture.anchor(1, frame: 0, host: 0))
        try Fixture.capture(&wide, Fixture.keysA, [0x2090_3C64], host: (1 << 63) + 1_000)
        #expect(Fixture.refusal { try Self.export(wide, [Fixture.keysA]) } == .overflow)
        #expect(try Self.export(wide, [Fixture.keysA], frame: 48_000).offsetsNs == [Int64.max - 999_998_999])
        // The widest numerator (frame span 2⁶⁴ at the largest denominator) rounds without trapping.
        var extreme = try Fixture.log([Fixture.keysA], timebase: HostTimebase(numer: 1, denom: .max))
        try extreme.observe(anchor: Fixture.anchor(1, frame: .max, host: 0))
        try Fixture.capture(&extreme, Fixture.keysA, [0x2090_3C64], host: 0)
        #expect(Fixture.refusal { try Self.export(extreme, [Fixture.keysA], frame: .min) } == .overflow)
    }

    @Test func recordCapacityRefusesAndTaints() throws {
        var log = try Fixture.log([Fixture.keysA, Fixture.keysB])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 0))
        for index in 0..<MIDICaptureLog.maximumCaptures {
            try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: UInt64(index))
        }
        #expect(log.records.count == 65_536 && log.taints.isEmpty)
        #expect(try Self.export(log, [Fixture.keysA]).offsetsNs.count == 65_536)
        let records = log.records
        #expect(Fixture.refusal { try Fixture.capture(&log, Fixture.keysB, [0x2090_3C64], host: 70_000) }
            == .capacity(limit: 65_536))
        #expect(log.records == records)
        #expect(log.taints == [Fixture.keysB: .refusedAtCapacity])
        #expect(Fixture.refusal { try Self.export(log, [Fixture.keysA, Fixture.keysB]) }
            == .captureRefusedAtCapacity(stream: Fixture.keysB))
        #expect(try Self.export(log, [Fixture.keysA]).offsetsNs.count == 65_536)
    }

    @Test func unsupportedCapacityRefusesAndKeepsTheFirstTaint() throws {
        var log = try Fixture.log([Fixture.keysA, Fixture.keysB])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 0))
        try log.observe(Fixture.restart(2, host: 1_000_000), stream: nil, nominalRate: 48_000)
        func capture(_ host: UInt64, on stream: StreamID = Fixture.keysA) throws -> MIDICaptureOutcome {
            try log.capture([0x2090_3C64], stream: stream, host: HostStamp(ticks: host), endpoint: .midi1,
                            port: .midi1, musicalMap: nil, current: try Generation(2))
        }
        for index in 0..<MIDICaptureLog.maximumUnsupported {
            _ = try capture(UInt64(index))
        }
        #expect(log.unsupported.count == 4_096)
        let before = log
        #expect(Fixture.refusal { try capture(5_000) } == .capacity(limit: 4_096))
        #expect(log == before)
        #expect(log.taints == [Fixture.keysA: .unsupportedCapture])
        // A clean stream refused at capacity is tainted, so no export can claim it lossless.
        #expect(Fixture.refusal { try capture(5_001, on: Fixture.keysB) } == .capacity(limit: 4_096))
        #expect(log.unsupported.count == 4_096)
        #expect(log.taints == [Fixture.keysA: .unsupportedCapture, Fixture.keysB: .refusedAtCapacity])
    }

    @Test func anchorBookIsBounded() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 0))
        for generation in 2...MIDICaptureLog.maximumGenerations {
            try log.observe(Fixture.restart(UInt64(generation), host: UInt64(generation)), stream: nil,
                            nominalRate: 48_000)
            try log.observe(anchor: Fixture.anchor(generation, frame: 0, host: UInt64(generation)))
        }
        #expect(log.firstAnchors.count == 4_096)
        try log.observe(Fixture.restart(4_097, host: 5_000), stream: nil, nominalRate: 48_000)
        let before = log
        #expect(Fixture.refusal { try log.observe(anchor: Fixture.anchor(4_097, frame: 0, host: 5_000)) }
            == .capacity(limit: 4_096))
        #expect(log == before)
    }

    @Test func clockObservationsAreChecked() throws {
        var log = try Fixture.example09Captures()
        let before = log
        let foreign = ClockAnchor(sample: SampleStamp(clock: ClockID(validated: "smp.other"), generation: .initial,
                                                      frame: 0), host: HostStamp(ticks: 0), musical: nil)
        #expect(Fixture.refusal { try log.observe(anchor: foreign) } == .foreignClock(foreign.sample.clock))
        #expect(Fixture.refusal { try log.observe(anchor: Fixture.anchor(2, frame: 0, host: 2_490_000_000)) }
            == .staleGeneration)
        #expect(Fixture.refusal { try log.observe(Fixture.restart(1, host: 2_490_000_000), stream: nil) }
            == .staleGeneration)
        #expect(Fixture.refusal { try log.observe(Fixture.restart(0, host: 2_490_000_000), stream: nil) }
            == .staleGeneration)
        #expect(Fixture.refusal { try log.observe(Fixture.restart(2, host: nil), stream: nil) }
            == .discontinuityNeedsHost)
        #expect(Fixture.refusal { try log.observe(Fixture.discontinuity(.locate, host: nil), stream: nil) }
            == .discontinuityNeedsHost)
        #expect(Fixture.refusal {
            try log.observe(Fixture.discontinuity(.locate, generation: 2, host: 2_490_000_000), stream: nil)
        } == .staleGeneration)
        #expect(Fixture.refusal { try log.observe(Fixture.restart(2, host: 1), stream: Fixture.synth) }
            == .undeclaredStream(Fixture.synth))
        #expect(Fixture.refusal {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 2_480_000_000),
                            endpoint: .midi1, port: .midi1, musicalMap: nil, current: try Generation(2))
        } == .staleGeneration)
        #expect(log == before)
        // A restart may not return to a generation the log has anchored already, nor repeat the current one.
        try Fixture.restartExample09(&log)
        try log.observe(Fixture.restart(3, host: 2_500_000_000), stream: nil, nominalRate: 48_000)
        #expect(Fixture.refusal { try log.observe(Fixture.restart(3, host: 2_505_000_000), stream: nil) }
            == .staleGeneration)
        // A musical map anchored in the ended sample generation is refused, even on the current transport.
        try log.observe(anchor: Fixture.anchor(3, frame: 0, host: 2_500_000_000, transport: 3))
        let oldSample = try Fixture.musicalMap(Fixture.anchor(2, frame: 0, host: 2_490_000_000, transport: 3),
                                               microsPerQuarter: 3_000_000)
        #expect(Fixture.refusal {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 2_500_000_000),
                            endpoint: .midi1, port: .midi1, musicalMap: oldSample, current: try Generation(3))
        } == .musicalMapMismatch)
        #expect(Fixture.refusal { try log.observe(Fixture.restart(1, host: 2_510_000_000), stream: nil) }
            == .staleGeneration)
        // Discontinuities that do not affect MIDI capture are accepted and change nothing.
        let settled = log
        try log.observe(Fixture.discontinuity(.underrun, generation: 3, host: nil), stream: Fixture.keysA)
        #expect(log == settled)
    }
}
