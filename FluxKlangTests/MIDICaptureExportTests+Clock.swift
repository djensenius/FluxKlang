import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI capture clock observations")
struct MIDICaptureClockTests {
    typealias Fixture = MIDICaptureFixture

    static func export(_ log: MIDICaptureLog, _ streams: [StreamID], generation: Int,
                       frame: Int64) throws -> [Int64] {
        try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: streams,
                                 origin: Fixture.origin(generation, frame: frame)).offsetsNs
    }

    static func discontinuity(_ kind: RuntimeDiscontinuityKind, clock: UInt32 = 0, stream: UInt32?,
                              host: UInt64? = nil) -> RuntimeDiscontinuity {
        RuntimeDiscontinuity(kind: kind, sample: RuntimeSampleStamp(clock: clock, generation: 1, frame: 0), frames: nil,
                             stream: stream, host: host.map { HostStamp(ticks: $0) })
    }

    /// Example 01's 48 → 96 kHz restart with two MIDI streams: keys-a in both generations, keys-b only in the second.
    static func example01() throws -> MIDICaptureLog {
        var log = try Fixture.log([Fixture.keysA, Fixture.keysB])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_412_000_000, microsPerQuarter: 500_000)
        try Fixture.capture(&log, Fixture.keysA, [0x2080_3C00], host: 2_460_000_000, microsPerQuarter: 500_000)
        try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil, nominalRate: 96_000)
        try log.observe(anchor: Fixture.anchor(2, frame: 0, host: 2_490_000_000, transport: 2, ticks: 92_160))
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3E64], host: 2_496_000_000, microsPerQuarter: 500_000)
        try Fixture.capture(&log, Fixture.keysB, [0x2080_3E00], host: 2_514_000_000, microsPerQuarter: 500_000)
        return log
    }

    /// The numbers match the unmodified checker on example 01 extended with these captures and exports (EP
    /// `checker-ex01-midi.py`); negative offsets are outside the schema and so pinned here only.
    @Test func example01RateChangeDerivesAndExportsAtEachGenerationsRate() throws {
        let log = try Self.example01()
        let one = Generation.initial, two = try Generation(2)
        #expect(log.rates == [one: 48_000, two: 96_000] && log.nominalRate == 96_000)
        #expect(log.records.map(\.sample) == [SampleStamp(clock: Fixture.clock, generation: one, frame: 24_000),
                                              SampleStamp(clock: Fixture.clock, generation: one, frame: 120_000),
                                              SampleStamp(clock: Fixture.clock, generation: two, frame: 24_000),
                                              SampleStamp(clock: Fixture.clock, generation: two, frame: 96_000)])
        #expect(log.records.map(\.musicalTicks) == [15_360, 76_800, 99_840, 122_880])
        let keysA = [Fixture.keysA], keysB = [Fixture.keysB], both = [Fixture.keysA, Fixture.keysB]
        #expect(try Self.export(log, keysA, generation: 1, frame: 0) == [500_000_000, 2_500_000_000, 4_000_000_000])
        #expect(try Self.export(log, keysB, generation: 1, frame: 0) == [4_750_000_000])
        #expect(try Self.export(log, keysA, generation: 1, frame: 24_000) == [0, 2_000_000_000, 3_500_000_000])
        #expect(try Self.export(log, keysB, generation: 1, frame: 24_000) == [4_250_000_000])
        #expect(try Self.export(log, keysB, generation: 2, frame: 0) == [1_000_000_000])
        #expect(try Self.export(log, keysB, generation: 2, frame: 24_000) == [750_000_000])
        #expect(try Self.export(log, both, generation: 2, frame: 24_000)
            == [-3_500_000_000, -1_500_000_000, 0, 750_000_000])
    }

    @Test func restartsCarryTheirGenerationsRateAndNothingElseDoes() throws {
        var log = try Fixture.example09Captures()
        let before = log
        #expect(Fixture.refusal { try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil) }
            == .restartNeedsRate)
        #expect(Fixture.refusal {
            try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil, nominalRate: 47_999)
        } == .invalidRate(47_999))
        #expect(Fixture.refusal {
            try log.observe(Fixture.discontinuity(.locate, host: 2_480_000_000), stream: nil, nominalRate: 48_000)
        } == .nominalRateWithoutRestart)
        #expect(log == before)
        // A restart before the log's first anchor sets the rate that anchor's generation keeps.
        var fresh = try Fixture.log([Fixture.keysA])
        try fresh.observe(Fixture.restart(5, host: 1_000), stream: nil, nominalRate: 96_000)
        try fresh.observe(anchor: Fixture.anchor(5, frame: 0, host: 1_000))
        let five = try Generation(5)
        #expect(fresh.rates == [five: 96_000])
    }

    @Test func musicalMapAtAnotherRateIsRefused() throws {
        var log = try Fixture.log([Fixture.keysA])
        let anchor = try Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1)
        try log.observe(anchor: anchor)
        let before = log
        let fast = try Fixture.musicalMap(anchor, microsPerQuarter: 500_000, nominalRate: 96_000)
        #expect(Fixture.refusal {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 2_412_000_000),
                            endpoint: .midi1, port: .midi1, musicalMap: fast, current: .initial)
        } == .musicalMapMismatch)
        #expect(log == before)
        // After the 96 kHz restart a 48 kHz map is the stale one.
        var example01 = try Self.example01()
        let current = try #require(example01.currentAnchor)
        let slow = try Fixture.musicalMap(current, microsPerQuarter: 500_000)
        let snapshot = example01
        #expect(Fixture.refusal {
            try example01.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 2_520_000_000),
                                  endpoint: .midi1, port: .midi1, musicalMap: slow, current: try Generation(2))
        } == .musicalMapMismatch)
        #expect(example01 == snapshot)
    }

    @Test func restartsAndLocatesMayNotGoBackwards() throws {
        // P1: after example 09's restart at 2.49e9, a restart to generation 3 at 2.0e9 is refused.
        var log = try Fixture.example09Captures()
        try Fixture.restartExample09(&log)
        let restarted = log
        let cutoff = HostStamp(ticks: 2_490_000_000)
        #expect(Fixture.refusal {
            try log.observe(Fixture.restart(3, host: 2_000_000_000), stream: nil, nominalRate: 48_000)
        } == .discontinuityPredatesCutoff(host: HostStamp(ticks: 2_000_000_000), cutoff: cutoff))
        #expect(log == restarted)
        #expect(try Fixture.capture(&log, Fixture.keysA, [0x2090_3E64], host: 2_100_000_000)
            == .unsupported(.predatesClockRestart(restart: cutoff)))
        // A restart or locate before the current anchor is refused too; at the cutoff it is accepted.
        var anchored = try Fixture.example09Captures()
        try anchored.observe(anchor: Fixture.anchor(1, frame: 120_000, host: 2_460_000_000))
        let current = anchored
        let anchorHost = HostStamp(ticks: 2_460_000_000)
        #expect(Fixture.refusal {
            try anchored.observe(Fixture.restart(2, host: 2_459_999_999), stream: nil, nominalRate: 48_000)
        } == .discontinuityPredatesCutoff(host: HostStamp(ticks: 2_459_999_999), cutoff: anchorHost))
        #expect(Fixture.refusal {
            try anchored.observe(Fixture.discontinuity(.locate, host: 2_459_999_999), stream: nil)
        } == .discontinuityPredatesCutoff(host: HostStamp(ticks: 2_459_999_999), cutoff: anchorHost))
        #expect(anchored == current)
        try anchored.observe(Fixture.discontinuity(.locate, host: 2_460_000_000), stream: nil)
        try anchored.observe(Fixture.restart(2, host: 2_460_000_000), stream: nil, nominalRate: 48_000)
        #expect(anchored.latestLocate == anchorHost && anchored.latestRestart == anchorHost)
    }

    @Test func aLaterLocateMayNotPrecedeTheLatestOne() throws {
        // P2: two locates, the second before the first.
        var log = try Fixture.example09Captures()
        try log.observe(Fixture.discontinuity(.locate, host: 2_480_000_000), stream: nil)
        let located = log
        let locate = HostStamp(ticks: 2_480_000_000)
        #expect(Fixture.refusal { try log.observe(Fixture.discontinuity(.locate, host: 2_450_000_000), stream: nil) }
            == .discontinuityPredatesCutoff(host: HostStamp(ticks: 2_450_000_000), cutoff: locate))
        #expect(Fixture.refusal {
            try log.observe(Fixture.restart(2, host: 2_450_000_000), stream: nil, nominalRate: 48_000)
        } == .discontinuityPredatesCutoff(host: HostStamp(ticks: 2_450_000_000), cutoff: locate))
        #expect(log == located)
        #expect(try Fixture.capture(&log, Fixture.keysA, [0x2090_3E64], host: 2_460_000_000)
            == .unsupported(.predatesLocate(locate: locate)))
    }

    @Test func laterAnchorsMustAgreeWithTheGenerationsFirst() throws {
        var log = try Fixture.example09Captures()
        let before = log
        // P3: 100M host ticks before the latest anchor and 9M frames off the nominal rate.
        #expect(Fixture.refusal { try log.observe(anchor: Fixture.anchor(1, frame: 9_000_000, host: 2_360_000_000)) }
            == .anchorDisagrees)
        // At 2.46e9 the prediction is frame 120,000 and the tolerance (48,000 + 120,000) / 1,000 = 168 frames.
        #expect(Fixture.refusal { try log.observe(anchor: Fixture.anchor(1, frame: 120_169, host: 2_460_000_000)) }
            == .anchorDisagrees)
        #expect(Fixture.refusal { try log.observe(anchor: Fixture.anchor(1, frame: 119_831, host: 2_460_000_000)) }
            == .anchorDisagrees)
        #expect(log == before)
        try log.observe(anchor: Fixture.anchor(1, frame: 120_168, host: 2_460_000_000))
        // Measured against the first anchor, not the latest: 200 frames slow is within 288 of the first's prediction.
        try log.observe(anchor: Fixture.anchor(1, frame: 239_800, host: 2_520_000_000))
        #expect(log.currentAnchor?.sample.frame == 239_800 && log.firstAnchors[.initial]?.sample.frame == 0)
    }

    @Test func anchorsMustAdvanceFromTheCurrentObservation() throws {
        var log = try Fixture.log([Fixture.keysA])
        let first = try Fixture.anchor(1, frame: 0, host: 2_400_000_000)
        let later = try Fixture.anchor(1, frame: 120_000, host: 2_460_000_000)
        try log.observe(anchor: first)
        try log.observe(anchor: later)
        let before = log

        #expect(Fixture.refusal { try log.observe(anchor: later) } == .anchorDisagrees)
        #expect(log == before)
        let earlier = try Fixture.anchor(1, frame: 119_999, host: 2_459_999_999)
        #expect(Fixture.refusal { try log.observe(anchor: earlier) } == .anchorDisagrees)
        #expect(log == before)
    }

    @Test func restartedGenerationAnchorsStayWithinTheRestartDriftBound() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        try log.observe(Fixture.restart(2, host: 2_490_000_000, frame: 100), stream: nil, nominalRate: 96_000)

        // At +1 second this is 150 frames off the restart's prediction; the allowance is 192 frames.
        let first = try Fixture.anchor(2, frame: 96_250, host: 2_514_000_000)
        try log.observe(anchor: first)
        #expect(log.currentAnchor == first)

        // At +2 seconds this is 300 frames off the restart's prediction; the allowance is 288.
        // It is only 150 frames off the first anchor's prediction, so checking against that anchor would accept it.
        let before = log
        let later = try Fixture.anchor(2, frame: 192_400, host: 2_538_000_000)
        #expect(Fixture.refusal { try log.observe(anchor: later) } == .anchorDisagrees)
        #expect(log == before)
    }

    @Test func anchorsMayNotPrecedeTheLatestRestart() throws {
        // P6: a generation-2 anchor before the restart would derive negative frames.
        var log = try Fixture.example09Captures()
        try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
        let before = log
        let restart = HostStamp(ticks: 2_490_000_000)
        #expect(Fixture.refusal { try log.observe(anchor: Fixture.anchor(2, frame: 0, host: 2_489_999_999)) }
            == .anchorPredatesRestart(restart: restart))
        #expect(log == before)
        try log.observe(anchor: Fixture.anchor(2, frame: 0, host: 2_490_000_000))
        let two = try Generation(2)
        #expect(log.firstAnchors[two]?.host == restart)
    }

    @Test func musicalAnchorsMayNotPrecedeTheLatestLocate() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 0, transport: 1))
        try log.observe(Fixture.discontinuity(.locate, host: 48_000_000), stream: nil)
        let located = log

        #expect(Fixture.refusal {
            try log.observe(anchor: Fixture.anchor(1, frame: 48_000, host: 24_000_000, transport: 1))
        } == .anchorPredatesLocate(locate: HostStamp(ticks: 48_000_000)))
        #expect(log == located)
    }

    @Test func restartsStepToTheNextGeneration() throws {
        var log = try Fixture.example09Captures()
        let before = log
        // P5 and friends: generations are never ordered (M2), so a restart must start exactly the next one.
        for generation: UInt64 in [5, 4, 3, 1] {
            #expect(Fixture.refusal {
                try log.observe(Fixture.restart(generation, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
            } == .staleGeneration)
        }
        #expect(log == before)
        try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
        #expect(Fixture.refusal {
            try log.observe(Fixture.restart(2, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
        } == .staleGeneration)
        try log.observe(Fixture.restart(3, host: 2_490_000_000), stream: nil, nominalRate: 48_000)
        let three = try Generation(3)
        #expect(log.currentGeneration == three)
    }

    @Test func unsupportedCapturesAreCheckedLikeRecordedOnes() throws {
        var log = try Fixture.example09Captures()
        try Fixture.restartExample09(&log)
        let before = log
        func capture(_ stream: StreamID, endpoint: MIDIEndpointProtocol = .midi1,
                     current: Generation) throws -> MIDICaptureOutcome {
            try log.capture([0x2090_3E64], stream: stream, host: HostStamp(ticks: 2_480_000_000), endpoint: endpoint,
                            port: .midi1, musicalMap: nil, current: current)
        }
        // P8: a generation the log never saw.
        #expect(Fixture.refusal { try capture(Fixture.keysA, current: try Generation(77)) } == .staleGeneration)
        // The stream's pinned protocols hold on the unsupported path as well.
        #expect(Fixture.refusal { try capture(Fixture.keysA, endpoint: .midi2, current: try Generation(2)) }
            == .protocolChangedWithoutFormatChange(stream: Fixture.keysA))
        #expect(log == before)
        // An unsupported first capture pins its stream too.
        var fresh = try Fixture.log([Fixture.keysA])
        try fresh.observe(anchor: Fixture.anchor(1, frame: 0, host: 0))
        try fresh.observe(Fixture.discontinuity(.locate, host: 1_000), stream: nil)
        let early = try fresh.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 999),
                                      endpoint: .unknown, port: .midi1, musicalMap: nil, current: .initial)
        #expect(early == .unsupported(.predatesLocate(locate: HostStamp(ticks: 1_000))))
        #expect(Fixture.refusal { try Fixture.capture(&fresh, Fixture.keysA, [0x2090_3C64], host: 1_000) }
            == .protocolChangedWithoutFormatChange(stream: Fixture.keysA))
        // Without any anchor or restart there is no current generation.
        var empty = try Fixture.log([Fixture.keysA])
        #expect(Fixture.refusal {
            try empty.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 0), endpoint: .midi1,
                              port: .midi1, musicalMap: nil, current: .initial)
        } == .noCurrentAnchor)
    }

    @Test func musicalMapsComeFromARememberedAnchorOfTheTransport() throws {
        var log = try Fixture.log([Fixture.keysA])
        let first = try Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1)
        try log.observe(anchor: first)
        let firstMap = try Fixture.musicalMap(first, microsPerQuarter: 3_000_000)
        func capture(_ map: MusicalClockMap, host: UInt64 = 2_400_000_000) throws -> MIDICaptureOutcome {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: host), endpoint: .midi1,
                            port: .midi1, musicalMap: map, current: .initial)
        }
        // P4: a map through a musical anchor the log never saw, on the same transport generation.
        let unseenAnchor = try Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1, ticks: 7_680)
        let unseen = try Fixture.musicalMap(unseenAnchor, microsPerQuarter: 3_000_000)
        let before = log
        #expect(Fixture.refusal { try capture(unseen) } == .musicalMapMismatch)
        let revised = try MusicalClockMap(
            anchor: first, map: MusicalMap(clock: Fixture.musicalClock, revision: Generation(2),
                                           segments: [TempoSegment(atTicks: 0, microsPerQuarter: 3_000_000)]),
            nominalRate: 48_000, currentSample: .initial, currentTransport: .initial)
        #expect(Fixture.refusal { try capture(revised) } == .musicalMapMismatch)
        #expect(log == before)
        // Loop wraps add anchors on the same transport; maps must match the latest anchor at/before the frame.
        // The log remembers the latest 64: `first` and 63 wraps keep it, the 64th wrap forgets it.
        for wrap in 1..<MIDICaptureLog.maximumMusicalAnchors {
            try log.observe(anchor: Self.wrap(wrap))
        }
        #expect(log.musicalAnchors.count == 64 && log.musicalAnchors.first == first)
        #expect(Fixture.refusal { try capture(firstMap, host: 2_412_000_000) } == .musicalMapMismatch)
        let frame24kAnchor = try Self.wrap(50)
        let frame24kMap = try Fixture.musicalMap(frame24kAnchor, microsPerQuarter: 3_000_000)
        let atFrame24k = try capture(frame24kMap, host: 2_412_000_000)
        #expect(atFrame24k == .recorded(try #require(log.records.last)))
        #expect(log.records.last?.musicalTicks == 0)
        try log.observe(anchor: Self.wrap(MIDICaptureLog.maximumMusicalAnchors))
        let oldest = try Self.wrap(1)
        #expect(log.musicalAnchors.count == 64 && log.musicalAnchors.first == oldest)
        let forgetting = log
        #expect(Fixture.refusal { try capture(firstMap, host: 2_412_000_000) } == .musicalMapMismatch)
        #expect(log == forgetting)
        _ = try capture(Fixture.musicalMap(oldest, microsPerQuarter: 3_000_000), host: 2_400_240_000)
        // A new transport generation forgets every anchor of the old one.
        let transport2 = try Fixture.anchor(1, frame: 48_000, host: 2_424_000_000, transport: 2)
        try log.observe(anchor: transport2)
        #expect(log.musicalAnchors == [transport2])
        // A locate or restart forgets them too.
        try log.observe(Fixture.discontinuity(.locate, host: 2_424_000_000), stream: nil)
        #expect(log.musicalAnchors.isEmpty)
        let afterLocate = try Fixture.anchor(1, frame: 96_000, host: 2_448_000_000, transport: 2)
        try log.observe(anchor: afterLocate)
        try log.observe(Fixture.restart(2, host: 2_448_000_000), stream: nil, nominalRate: 48_000)
        #expect(log.musicalAnchors.isEmpty)
    }

    @Test func captureFailsClosedWhenItsLatestMusicalAnchorWasEvicted() throws {
        var log = try Fixture.log([Fixture.keysA])
        let first = try Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1)
        try log.observe(anchor: first)
        let firstMap = try Fixture.musicalMap(first, microsPerQuarter: 3_000_000)
        for wrap in 1...(MIDICaptureLog.maximumMusicalAnchors + 1) {
            try log.observe(anchor: Self.wrap(wrap))
        }
        // Wrap 1 is evicted; frame 480 lies after the genuine first anchor but before retained history.
        let before = log
        #expect(Fixture.refusal {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 2_400_240_000),
                            endpoint: .midi1, port: .midi1, musicalMap: firstMap, current: .initial)
        } == .musicalMapMismatch)
        #expect(log == before)
    }

    @Test func loopWrapUsesTheLatestMusicalAnchorAtOrBeforeTheCaptureFrame() throws {
        var log = try Fixture.log([Fixture.keysA])
        let first = try Fixture.anchor(1, frame: 0, host: 0, transport: 1)
        try log.observe(anchor: first)
        let firstMap = try Fixture.musicalMap(first, microsPerQuarter: 500_000)
        let wrapped = ClockAnchor(
            sample: SampleStamp(clock: Fixture.clock, generation: .initial, frame: 48_000),
            host: HostStamp(ticks: 24_000_000),
            musical: MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 1))
        try log.observe(anchor: wrapped)
        let wrapMap = try Fixture.musicalMap(wrapped, microsPerQuarter: 500_000)
        let before = log

        #expect(try firstMap.ticks(atFrame: 72_000) == 46_080)
        #expect(Fixture.refusal {
            try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 36_000_000),
                            endpoint: .midi1, port: .midi1, musicalMap: firstMap, current: .initial)
        } == .musicalMapMismatch)
        #expect(log == before)
        let outcome = try log.capture([0x2090_3C64], stream: Fixture.keysA, host: HostStamp(ticks: 36_000_000),
                                      endpoint: .midi1, port: .midi1, musicalMap: wrapMap, current: .initial)
        #expect(outcome == .recorded(try #require(log.records.last)))
        #expect(log.records.last?.sample.frame == 72_000 && log.records.last?.musicalTicks == 15_360)
    }

    /// Loop wrap `index`: 480 frames (240,000 host ticks) apart, back at tick 0 in pass `index`.
    private static func wrap(_ index: Int) throws -> ClockAnchor {
        let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: UInt32(index))
        return ClockAnchor(sample: SampleStamp(clock: Fixture.clock, generation: .initial, frame: Int64(index) * 480),
                           host: HostStamp(ticks: 2_400_000_000 + UInt64(index) * 240_000), musical: musical)
    }

    @Test func discontinuitySlotsAreCrossChecked() throws {
        var log = try Fixture.log([Fixture.keysA])
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 0))
        let before = log
        // Without a preparation a stream slot still needs a `stream:`.
        #expect(Fixture.refusal { try log.observe(Self.discontinuity(.formatChange, stream: 0), stream: nil) }
            == .discontinuitySlotMismatch)
        #expect(Fixture.refusal { try log.observe(Self.discontinuity(.underrun, stream: 0), stream: nil) }
            == .discontinuitySlotMismatch)
        #expect(log == before)
        try log.observe(Self.discontinuity(.formatChange, stream: 9), stream: Fixture.keysA)
        // With a preparation both slots must be the mapped ones.
        let preparation = try RuntimePreparation(primaryClock: Fixture.clock, musicalClock: nil, bindings: [
            (.sampleClock(Fixture.clock), 0), (.stream(Fixture.keysA, direction: .capture), 1),
            (.stream(Fixture.keysB, direction: .capture), 2)])
        var mapped = try MIDICaptureLog(streams: [Fixture.keysA, Fixture.keysB], clock: Fixture.clock,
                                        timebase: Fixture.timebase, nominalRate: 48_000, preparation: preparation)
        let fresh = mapped
        #expect(Fixture.refusal {
            try mapped.observe(Self.discontinuity(.formatChange, stream: 2), stream: Fixture.keysA)
        } == .discontinuitySlotMismatch)
        #expect(Fixture.refusal {
            try mapped.observe(Self.discontinuity(.formatChange, clock: 1, stream: 1), stream: Fixture.keysA)
        } == .discontinuitySlotMismatch)
        #expect(Fixture.refusal {
            try mapped.observe(Self.discontinuity(.locate, clock: 1, stream: nil, host: 0), stream: nil)
        } == .discontinuitySlotMismatch)
        #expect(mapped == fresh)
        try mapped.observe(Self.discontinuity(.formatChange, stream: 1), stream: Fixture.keysA)
        try mapped.observe(Self.discontinuity(.formatChange, stream: nil), stream: Fixture.keysB)
        #expect(Fixture.refusal {
            try MIDICaptureLog(streams: [Fixture.keysA, Fixture.idle], clock: Fixture.clock, timebase: Fixture.timebase,
                               nominalRate: 48_000, preparation: preparation)
        } == .runtimeSlotsUnmapped)
        #expect(Fixture.refusal {
            try MIDICaptureLog(streams: [Fixture.keysA], clock: ClockID(validated: "smp.other"),
                               timebase: Fixture.timebase, nominalRate: 48_000, preparation: preparation)
        } == .runtimeSlotsUnmapped)
    }
}
