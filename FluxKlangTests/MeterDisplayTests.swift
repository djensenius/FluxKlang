import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Truthful meter display (#102 M1)")
struct MeterDisplayTests {
    static let millisecond: UInt64 = 1_000_000
    static let second: UInt64 = 1_000_000_000
    static let halfSecondWindow: Int64 = 500_000_000
    static let longestWindow: Int64 = 60_000_000_000
    /// The fixtures' frame-age rule: 500 ms at 48 kHz.
    static let frameAge: Int64 = 24_000

    /// Publishes successive samples for one channel the way `TelemetrySlots.latest` returns them, classified at
    /// their own frame and at host time `at` (0 unless a test says otherwise): never published until the first
    /// publish, then the same classified read until the next one; sequences start at 1.
    struct Feed {
        private(set) var latest: MeterClassifiedRead
        private var sequence: UInt64 = 0

        init() throws(MeterDisplayRefusal) {
            latest = try MeterDisplayTests.missing(.neverPublished)
        }

        @discardableResult
        mutating func publish(_ dbfs: Double, frame: Int64 = 0,
                              at classifiedAt: MeterInstant = MeterInstant(nanoseconds: 0))
            throws(MeterDisplayRefusal) -> MeterClassifiedRead {
            sequence += 1
            latest = try MeterDisplayTests.read(dbfs, sequence: sequence, frame: frame, at: classifiedAt)
            return latest
        }
    }

    static func window(_ nanoseconds: Int64 = halfSecondWindow) throws(MeterDisplayRefusal) -> MeterStalenessWindow {
        try MeterStalenessWindow.make(nanoseconds: nanoseconds)
    }

    /// 1 s hold, 20 dB/s decay, −60 dBFS floor and 0 dBFS clip unless a test says otherwise.
    static func ballistics(hold: Int64 = 1_000_000_000, decay: Double = 20, floor: Double = -60,
                           clip: Double = 0) throws(MeterDisplayRefusal) -> MeterBallistics {
        try MeterBallistics.make(peakHoldNanoseconds: hold, decayDecibelsPerSecond: decay, floorDBFS: floor,
                                 clipThresholdDBFS: clip)
    }

    static func model(_ source: MeterSource, window: Int64 = halfSecondWindow,
                      ballistics: MeterBallistics? = nil) throws(MeterDisplayRefusal) -> MeterDisplayModel {
        let chosen: MeterBallistics
        if let ballistics { chosen = ballistics } else { chosen = try Self.ballistics() }
        return try MeterDisplayModel(source: source, staleness: Self.window(window), ballistics: chosen)
    }

    static func tap(_ channels: Int = 1, window: Int64 = halfSecondWindow,
                    ballistics: MeterBallistics? = nil) throws(MeterDisplayRefusal) -> MeterDisplayModel {
        try model(MeterSource.tap(channels: channels), window: window, ballistics: ballistics)
    }

    static func ms(_ milliseconds: UInt64, plus nanoseconds: UInt64 = 0) -> MeterInstant {
        MeterInstant(nanoseconds: milliseconds * millisecond + nanoseconds)
    }

    static func raw(_ dbfs: Double, sequence: UInt64, generation: UInt64 = 1,
                    frame: Int64 = 0) -> TelemetryRead<MeterTapValue> {
        .measured(TelemetrySample(value: MeterTapValue(peakDBFS: dbfs),
                                  stamp: TelemetryStamp(clockGeneration: generation, frame: frame), sequence: sequence))
    }

    /// A sample classified in its own clock generation at its own frame, so the kernel rule passes it, at host time
    /// `at` (0 unless a test says otherwise).
    static func read(_ dbfs: Double, sequence: UInt64, generation: UInt64 = 1, frame: Int64 = 0,
                     at classifiedAt: MeterInstant = MeterInstant(nanoseconds: 0)) throws(MeterDisplayRefusal)
        -> MeterClassifiedRead {
        try MeterClassifiedRead.classify(raw(dbfs, sequence: sequence, generation: generation, frame: frame),
                                         generation: generation, frame: frame, maximumAgeFrames: frameAge,
                                         at: classifiedAt)
    }

    /// One hour of render frames at 48 kHz.
    static let hourOfFrames: Int64 = 3_600 * 48_000

    static func telemetrySlots(_ count: Int) throws -> TelemetrySlots<MeterTapValue> {
        let policy = HandoffPolicy(purpose: .telemetry, producer: .render,
                                   producers: ProducerCardinality(maximum: 1, evidence: .appOwned), consumer: .ui,
                                   consumers: 1, capacity: count, ordering: .latestOnly, deadline: .none,
                                   overflow: .overwriteLatest, lifetime: .session)
        return try TelemetrySlots<MeterTapValue>(policy: policy, slotCount: count)
    }

    /// Classifies a raw read at render `frame` of clock `generation` and host time `at` (0 unless a test says
    /// otherwise), with the fixtures' frame-age rule.
    static func classified(_ read: TelemetryRead<MeterTapValue>, generation: UInt64 = 3, frame: Int64,
                           at classifiedAt: MeterInstant = MeterInstant(nanoseconds: 0)) throws(MeterDisplayRefusal)
        -> MeterClassifiedRead {
        try MeterClassifiedRead.classify(read, generation: generation, frame: frame, maximumAgeFrames: frameAge,
                                         at: classifiedAt)
    }

    /// A telemetry-unavailable read, classified at host time `at` (0 unless a test says otherwise); it passes
    /// through unchanged.
    static func missing(_ reason: TelemetryUnavailable,
                        at classifiedAt: MeterInstant = MeterInstant(nanoseconds: 0)) throws(MeterDisplayRefusal)
        -> MeterClassifiedRead {
        try MeterClassifiedRead.classify(.unavailable(reason), generation: 1, frame: 0, maximumAgeFrames: frameAge,
                                         at: classifiedAt)
    }

    /// Returns the refusal `body` throws, or nil when it succeeds. Any other error is recorded as an issue.
    static func refusal<T>(_ body: () throws -> T) -> MeterDisplayRefusal? {
        do {
            _ = try body()
            return nil
        } catch let refusal as MeterDisplayRefusal {
            return refusal
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    static func signals(_ display: MeterDisplay) -> [MeterChannelSignal] {
        guard case .channels(let channels) = display else { return [] }
        return channels.map(\.signal)
    }

    static func clips(_ display: MeterDisplay) -> [Bool] {
        guard case .channels(let channels) = display else { return [] }
        return channels.map(\.clipLatched)
    }

    /// Updates a one-channel tap and returns its single signal.
    static func signal(_ model: inout MeterDisplayModel, _ read: MeterClassifiedRead,
                       at now: MeterInstant) throws -> MeterChannelSignal {
        try #require(signals(model.update([read], at: now)).first)
    }

    // MARK: - Parameter validation

    @Test
    func stalenessWindowIsRequiredAndBoundedToOneMillisecondThroughSixtySeconds() throws {
        #expect(try Self.window(1_000_000).nanoseconds == 1_000_000)
        #expect(try Self.window(60_000_000_000).nanoseconds == 60_000_000_000)
        for refused: Int64 in [999_999, 60_000_000_001, 0, -1, -1_000_000, .min, .max] {
            #expect(Self.refusal { try MeterStalenessWindow.make(nanoseconds: refused) }
                    == .stalenessWindowOutOfRange(nanoseconds: refused))
        }
    }

    @Test
    func peakHoldIsBoundedToZeroThroughThirtySeconds() throws {
        #expect(try Self.ballistics(hold: 0).peakHoldNanoseconds == 0)
        #expect(try Self.ballistics(hold: 30_000_000_000).peakHoldNanoseconds == 30_000_000_000)
        for refused: Int64 in [-1, 30_000_000_001, .min, .max] {
            #expect(Self.refusal { try Self.ballistics(hold: refused) } == .peakHoldOutOfRange(nanoseconds: refused))
        }
    }

    @Test
    func decayRateIsFiniteAndBoundedToOneThroughOneThousandDecibelsPerSecond() throws {
        #expect(try Self.ballistics(decay: 1).decayDecibelsPerSecond == 1)
        #expect(try Self.ballistics(decay: 1_000).decayDecibelsPerSecond == 1_000)
        for refused in [(1.0).nextDown, (1_000.0).nextUp, 0, -0.0, -20] {
            #expect(Self.refusal { try Self.ballistics(decay: refused) } == .decayRateOutOfRange(refused))
        }
        for notFinite in [Double.nan, .infinity, -.infinity] {
            #expect(Self.refusal { try Self.ballistics(decay: notFinite) } == .parameterNotFinite(.decayRate))
        }
    }

    @Test
    func floorIsFiniteAndBoundedToMinusTwoHundredThroughMinusTwentyDBFS() throws {
        #expect(try Self.ballistics(floor: -200).floorDBFS == -200)
        #expect(try Self.ballistics(floor: -20).floorDBFS == -20)
        for refused in [(-200.0).nextDown, (-20.0).nextUp, 0] {
            #expect(Self.refusal { try Self.ballistics(floor: refused) } == .floorOutOfRange(refused))
        }
        for notFinite in [Double.nan, .infinity, -.infinity] {
            #expect(Self.refusal { try Self.ballistics(floor: notFinite) } == .parameterNotFinite(.floor))
        }
    }

    @Test
    func clipThresholdIsAboveTheFloorAndAtMostPlusTwentyFourDBFS() throws {
        #expect(try Self.ballistics(clip: (-60.0).nextUp).clipThresholdDBFS == (-60.0).nextUp)
        #expect(try Self.ballistics(clip: 24).clipThresholdDBFS == 24)
        for refused in [-60.0, -90, (24.0).nextUp] {
            #expect(Self.refusal { try Self.ballistics(clip: refused) }
                    == .clipThresholdOutOfRange(refused, floorDBFS: -60))
        }
        for notFinite in [Double.nan, .infinity, -.infinity] {
            #expect(Self.refusal { try Self.ballistics(clip: notFinite) } == .parameterNotFinite(.clipThreshold))
        }
    }

    @Test
    func ballisticsReportTheFirstFailureInDeclaredOrder() {
        #expect(Self.refusal { try Self.ballistics(hold: -1, decay: .nan, floor: 0, clip: .nan) }
                == .peakHoldOutOfRange(nanoseconds: -1))
        #expect(Self.refusal { try Self.ballistics(decay: .nan, floor: 0, clip: .nan) }
                == .parameterNotFinite(.decayRate))
        #expect(Self.refusal { try Self.ballistics(decay: 0, floor: .nan) } == .decayRateOutOfRange(0))
        #expect(Self.refusal { try Self.ballistics(floor: 0, clip: .nan) } == .floorOutOfRange(0))
        #expect(Self.refusal { try Self.ballistics(floor: .nan, clip: .nan) } == .parameterNotFinite(.floor))
    }

    @Test
    func tapChannelsAreBoundedToOneThroughSixtyFour() throws {
        #expect(try MeterSource.tap(channels: 1).channelCount == 1)
        #expect(try MeterSource.tap(channels: 64).channelCount == MeterSource.maximumChannels)
        for refused in [0, -1, 65, .min, .max] {
            #expect(Self.refusal { try MeterSource.tap(channels: refused) } == .channelCountOutOfRange(refused))
        }
        #expect(MeterSource.faderTravelOnly.channelCount == 0)
        #expect(MeterSource.gated(.deviceMissing).channelCount == 0)
    }

    // MARK: - Unavailable reasons

    @Test
    func everyGateShowsUnavailableWithItsOwnReason() throws {
        for gate in MeterSourceGate.allCases {
            var model = try Self.model(.gated(gate))
            #expect(try model.update([], at: Self.ms(0)) == .unavailable(.gated(gate)))
            #expect(try model.update([], at: Self.ms(90_000)) == .unavailable(.gated(gate)))
        }
    }

    @Test
    func everyTelemetryReasonMapsToItsOwnDisplayReason() throws {
        let mapping: [(TelemetryUnavailable, MeterUnavailableReason)] = [
            (.neverPublished, .neverPublished), (.invalidSlot, .invalidSlot),
            (.staleGeneration, .staleGeneration), (.tooOld, .tooOld)
        ]
        for (telemetry, expected) in mapping {
            #expect(MeterUnavailableReason(telemetry) == expected)
            var model = try Self.tap()
            #expect(try Self.signal(&model, Self.missing(telemetry), at: Self.ms(5)) == .unavailable(expected))
        }
    }

    @Test
    func silenceIsAMeasuredFloorAndDistinctFromUnavailable() throws {
        var model = try Self.tap()
        #expect(try Self.signal(&model, Self.missing(.neverPublished), at: Self.ms(0)) == .unavailable(.neverPublished))
        var feed = try Feed()
        #expect(try Self.signal(&model, feed.publish(-.infinity), at: Self.ms(10))
                == .measured(levelDBFS: -60, peakHoldDBFS: -60))
        #expect(try Self.signal(&model, feed.publish(-200), at: Self.ms(20))
                == .measured(levelDBFS: -60, peakHoldDBFS: -60))
    }

    @Test
    func realTelemetrySlotsFeedTheMeterThroughClassify() throws {
        let slots = try Self.telemetrySlots(2)
        var model = try Self.tap(2)
        let never = try model.update([Self.classified(slots.latest(slot: 0), frame: 0),
                                      Self.classified(slots.latest(slot: 7), frame: 0)], at: Self.ms(0))
        #expect(Self.signals(never) == [.unavailable(.neverPublished), .unavailable(.invalidSlot)])

        #expect(slots.publish(slot: 0, value: MeterTapValue(peakDBFS: -12),
                              stamp: TelemetryStamp(clockGeneration: 3, frame: 4_800)) == .ok)
        #expect(slots.publish(slot: 1, value: MeterTapValue(peakDBFS: -24),
                              stamp: TelemetryStamp(clockGeneration: 3, frame: 4_800)) == .ok)
        let later = Self.ms(10)
        let fresh = try model.update([Self.classified(slots.latest(slot: 0), frame: 28_800, at: later),
                                      Self.classified(slots.latest(slot: 1), frame: 28_800, at: later)], at: later)
        #expect(Self.signals(fresh) == [.measured(levelDBFS: -12, peakHoldDBFS: -12),
                                        .measured(levelDBFS: -24, peakHoldDBFS: -24)])
        let last = Self.ms(20)
        let classified = try model.update([
            Self.classified(slots.latest(slot: 0), generation: 4, frame: 28_800, at: last),
            Self.classified(slots.latest(slot: 1), frame: 28_801, at: last)
        ], at: last)
        #expect(Self.signals(classified) == [.unavailable(.staleGeneration), .unavailable(.tooOld)])
    }

    // MARK: - Classified reads (render-stamp staleness)

    @Test
    func frameAgeRuleIsBoundedToOneFrameThroughTwoToTheTwentyFour() throws {
        let sample = Self.raw(-6, sequence: 1)
        for accepted: Int64 in [1, 1 << 24] {
            let read = try MeterClassifiedRead.classify(sample, generation: 1, frame: 0, maximumAgeFrames: accepted,
                                                        at: Self.ms(0))
            #expect(read.read == sample)
        }
        for refused: Int64 in [0, -1, (1 << 24) + 1, .min, .max] {
            #expect(Self.refusal {
                try MeterClassifiedRead.classify(.unavailable(.neverPublished), generation: 1, frame: 0,
                                                 maximumAgeFrames: refused, at: Self.ms(0))
            } == .maximumAgeFramesOutOfRange(refused))
        }
    }

    @Test
    func classificationMapsTheKernelRuleExactly() throws {
        let sample = Self.raw(-6, sequence: 1, generation: 3, frame: 1_000)
        #expect(try Self.classified(sample, frame: 25_000).read == sample)
        #expect(try Self.classified(sample, frame: 25_001).read == .unavailable(.tooOld))
        #expect(try Self.classified(sample, frame: .min).read == .unavailable(.tooOld))
        #expect(try Self.classified(sample, generation: 2, frame: 1_000).read == .unavailable(.staleGeneration))
        for reason in [TelemetryUnavailable.neverPublished, .invalidSlot, .staleGeneration, .tooOld] {
            #expect(try Self.classified(.unavailable(reason), frame: 0).read == .unavailable(reason))
        }
    }

    @Test
    func longDeadSampleIsNeverShownAsLiveOnFirstSight() throws {
        // The review's repro: a fresh model first sees sequence 999 an hour after it was published.
        let dead = Self.raw(-6, sequence: 999, generation: 3, frame: 0)
        let hour = Self.ms(3_600_000)
        var model = try Self.tap()
        #expect(try Self.signal(&model, Self.classified(dead, frame: Self.hourOfFrames, at: hour), at: hour)
                == .unavailable(.tooOld))
        var restarted = try Self.tap()
        #expect(try Self.signal(&restarted, Self.classified(dead, generation: 4, frame: 0, at: hour), at: hour)
                == .unavailable(.staleGeneration))
    }

    @Test
    func rawOldSampleFirstSeenAfterRebindIsNotMeasured() throws {
        let slots = try Self.telemetrySlots(1)
        #expect(slots.publish(slot: 0, value: MeterTapValue(peakDBFS: -6),
                              stamp: TelemetryStamp(clockGeneration: 3, frame: 0)) == .ok)
        var model = try Self.tap()
        #expect(try Self.signal(&model, Self.classified(slots.latest(slot: 0), frame: 0), at: Self.ms(0))
                == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        let hour = Self.ms(3_600_000)
        for source in [model.source, .faderTravelOnly] {
            model.rebind(to: source)
            model.rebind(to: try MeterSource.tap(channels: 1))
            #expect(try Self.signal(&model, Self.classified(slots.latest(slot: 0), frame: Self.hourOfFrames, at: hour),
                                    at: hour) == .unavailable(.tooOld))
        }
        #expect(slots.publish(slot: 0, value: MeterTapValue(peakDBFS: -9),
                              stamp: TelemetryStamp(clockGeneration: 3, frame: Self.hourOfFrames)) == .ok)
        let later = Self.ms(3_600_010)
        #expect(try Self.signal(&model, Self.classified(slots.latest(slot: 0), frame: Self.hourOfFrames + 480,
                                                        at: later), at: later)
                == .measured(levelDBFS: -9, peakHoldDBFS: -9))
    }

    // MARK: - Fader travel is never signal

    @Test
    func faderTravelOnlyStripNeverShowsALevelWhileTheFaderMoves() throws {
        var model = try Self.model(.faderTravelOnly)
        // The fader sweeps down and back up. Its position is a control value with no way into the meter.
        let sweep = (0...40).map { Double(abs(20 - $0)) / 20 }
        var displays: [MeterDisplay] = []
        for step in sweep.indices {
            displays.append(try model.update([], at: Self.ms(UInt64(step) * 50)))
        }
        #expect(displays == Array(repeating: .unavailable(.faderTravelOnly), count: sweep.count))
    }

    @Test
    func faderTravelPresentedAsAReadingIsRefusedAndChangesNothing() throws {
        for source in [MeterSource.faderTravelOnly, .gated(.noRoute)] {
            var model = try Self.model(source)
            _ = try model.update([], at: Self.ms(100))
            let before = model
            let reason = try #require(source.unavailableReason)
            for position in [0.0, 0.5, 1.0] {
                let smuggled = try Self.read(position, sequence: 1)
                #expect(Self.refusal { try model.update([smuggled], at: Self.ms(200)) }
                        == .readsForUnmeasuredSource(reason, count: 1))
                #expect(model == before)
            }
            #expect(try model.update([], at: Self.ms(300)) == .unavailable(reason))
        }
    }

    @Test
    func movingTheFaderWithoutTelemetryKeepsATapUnavailable() throws {
        var model = try Self.tap(2)
        for step in UInt64(0)...30 {
            let display = try model.update([Self.missing(.neverPublished), Self.missing(.neverPublished)],
                                           at: Self.ms(step * 33))
            #expect(Self.signals(display) == [.unavailable(.neverPublished), .unavailable(.neverPublished)])
            #expect(Self.clips(display) == [false, false])
        }
    }

    @Test
    func rebindingFromFaderTravelToATapWaitsForTelemetry() throws {
        var model = try Self.model(.faderTravelOnly)
        #expect(try model.update([], at: Self.ms(0)) == .unavailable(.faderTravelOnly))
        model.rebind(to: try MeterSource.tap(channels: 1))
        #expect(model.source == (try MeterSource.tap(channels: 1)))
        #expect(Self.refusal { try model.update([], at: Self.ms(1)) }
                == .channelCountMismatch(expected: 1, received: 0))
        #expect(try Self.signal(&model, Self.missing(.neverPublished), at: Self.ms(2)) == .unavailable(.neverPublished))
        #expect(try Self.signal(&model, Self.read(-9, sequence: 1), at: Self.ms(3))
                == .measured(levelDBFS: -9, peakHoldDBFS: -9))
        model.rebind(to: .faderTravelOnly)
        #expect(try model.update([], at: Self.ms(4)) == .unavailable(.faderTravelOnly))
    }
}
