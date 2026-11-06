import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Deterministic SplitMix64 for the meter invariant sweep; private to this file.
private struct MeterBallisticsSplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func below(_ bound: UInt64) -> UInt64 {
        next() % bound
    }
}

extension MeterDisplayTests {
    /// A one-channel tap whose samples stay fresh for 60 s, so only the ballistics change with time.
    static func longTap(hold: Int64 = 1_000_000_000, clip: Double = 0) throws -> MeterDisplayModel {
        try tap(window: longestWindow, ballistics: ballistics(hold: hold, clip: clip))
    }

    static func levels(_ signal: MeterChannelSignal) -> (level: Double, peak: Double)? {
        guard case .measured(let level, let peak) = signal else { return nil }
        return (level, peak)
    }

    // MARK: - Level

    @Test
    func firstReadingShowsExactlyTheReading() throws {
        var model = try Self.longTap()
        #expect(try Self.signal(&model, Self.read(-6, sequence: 1), at: Self.ms(40))
                == .measured(levelDBFS: -6, peakHoldDBFS: -6))
    }

    @Test
    func levelFallsAtTheDecayRateFromInjectedTime() throws {
        var model = try Self.longTap()
        let sample = try Self.read(-6, sequence: 1)
        _ = try Self.signal(&model, sample, at: Self.ms(0))
        let expected: [(UInt64, Double)] = [(0, -6), (250, -11), (500, -16), (750, -21), (1_000, -26), (2_500, -56)]
        for (time, level) in expected {
            #expect(try Self.levels(Self.signal(&model, sample, at: Self.ms(time)))?.level == level)
        }
        let justAfter = try #require(Self.levels(Self.signal(&model, sample, at: Self.ms(2_500, plus: 1)))?.level)
        #expect(justAfter < -56 && justAfter > -56.000_001)
    }

    @Test
    func levelNeverRisesWithoutANewReading() throws {
        var model = try Self.longTap()
        var feed = try Feed()
        try feed.publish(-3)
        var previous = Double.infinity
        for step in UInt64(0)...40 {
            let level = try #require(Self.levels(Self.signal(&model, feed.latest, at: Self.ms(step * 75)))?.level)
            #expect(level <= previous)
            previous = level
        }
        #expect(previous == -60)
    }

    @Test
    func higherReadingRaisesTheLevelAtOnceAndLowerReadingKeepsTheFall() throws {
        var model = try Self.longTap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-30), at: Self.ms(0))
        #expect(try Self.signal(&model, feed.publish(-10), at: Self.ms(100))
                == .measured(levelDBFS: -10, peakHoldDBFS: -10))
        #expect(try Self.signal(&model, feed.publish(-40), at: Self.ms(600))
                == .measured(levelDBFS: -20, peakHoldDBFS: -10))
        #expect(try Self.signal(&model, feed.publish(-25), at: Self.ms(850))
                == .measured(levelDBFS: -25, peakHoldDBFS: -10))
    }

    @Test
    func levelAndPeakStopAtTheFloor() throws {
        var model = try Self.longTap()
        let sample = try Self.read(-6, sequence: 1)
        _ = try Self.signal(&model, sample, at: Self.ms(0))
        #expect(try Self.signal(&model, sample, at: Self.ms(3_000)) == .measured(levelDBFS: -60, peakHoldDBFS: -46))
        #expect(try Self.signal(&model, sample, at: Self.ms(4_000)) == .measured(levelDBFS: -60, peakHoldDBFS: -60))
        #expect(try Self.signal(&model, sample, at: Self.ms(59_000)) == .measured(levelDBFS: -60, peakHoldDBFS: -60))
    }

    // MARK: - Peak hold

    @Test
    func peakHoldsForExactlyTheHoldDurationThenFallsAtTheDecayRate() throws {
        var model = try Self.longTap()
        let sample = try Self.read(-6, sequence: 1)
        _ = try Self.signal(&model, sample, at: Self.ms(0))
        #expect(try Self.levels(Self.signal(&model, sample, at: Self.ms(999)))?.peak == -6)
        #expect(try Self.signal(&model, sample, at: Self.ms(1_000)) == .measured(levelDBFS: -26, peakHoldDBFS: -6))
        let justAfter = try #require(Self.levels(Self.signal(&model, sample, at: Self.ms(1_000, plus: 1))))
        #expect(justAfter.peak == -6 - 20.0 / 1_000_000_000)
        #expect(try Self.signal(&model, sample, at: Self.ms(1_250)) == .measured(levelDBFS: -31, peakHoldDBFS: -11))
        #expect(try Self.signal(&model, sample, at: Self.ms(1_500)) == .measured(levelDBFS: -36, peakHoldDBFS: -16))
    }

    @Test
    func readingThatReachesThePeakRestartsItsHold() throws {
        var model = try Self.longTap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-6), at: Self.ms(0))
        _ = try Self.signal(&model, feed.publish(-6), at: Self.ms(900))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(1_500)) == .measured(levelDBFS: -18, peakHoldDBFS: -6))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(1_900)) == .measured(levelDBFS: -26, peakHoldDBFS: -6))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(2_150))
                == .measured(levelDBFS: -31, peakHoldDBFS: -11))
    }

    @Test
    func lowerReadingDoesNotRestartThePeakHold() throws {
        var model = try Self.longTap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-6), at: Self.ms(0))
        #expect(try Self.signal(&model, feed.publish(-7), at: Self.ms(900))
                == .measured(levelDBFS: -7, peakHoldDBFS: -6))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(1_500))
                == .measured(levelDBFS: -19, peakHoldDBFS: -16))
    }

    @Test
    func readingAboveAFallingPeakStartsANewHold() throws {
        var model = try Self.longTap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-6), at: Self.ms(0))
        #expect(try Self.signal(&model, feed.publish(-12), at: Self.ms(1_500))
                == .measured(levelDBFS: -12, peakHoldDBFS: -12))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(2_500))
                == .measured(levelDBFS: -32, peakHoldDBFS: -12))
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(2_750))
                == .measured(levelDBFS: -37, peakHoldDBFS: -17))
    }

    @Test
    func zeroHoldFallsWithTheLevel() throws {
        var model = try Self.longTap(hold: 0)
        let sample = try Self.read(-6, sequence: 1)
        _ = try Self.signal(&model, sample, at: Self.ms(0))
        #expect(try Self.signal(&model, sample, at: Self.ms(0)) == .measured(levelDBFS: -6, peakHoldDBFS: -6))
        #expect(try Self.signal(&model, sample, at: Self.ms(500)) == .measured(levelDBFS: -16, peakHoldDBFS: -16))
    }

    // MARK: - Clip latch

    @Test
    func clipLatchesAtTheThresholdAndNotJustBelowIt() throws {
        var below = try Self.longTap(clip: -1)
        #expect(Self.clips(try below.update([Self.read((-1.0).nextDown, sequence: 1)], at: Self.ms(0))) == [false])
        var atThreshold = try Self.longTap(clip: -1)
        #expect(Self.clips(try atThreshold.update([Self.read(-1, sequence: 1)], at: Self.ms(0))) == [true])
    }

    @Test
    func clipStaysLatchedThroughQuietAndUnavailableReadsUntilReset() throws {
        var model = try Self.tap()
        var feed = try Feed()
        #expect(Self.clips(try model.update([feed.publish(0.5)], at: Self.ms(0))) == [true])
        #expect(Self.clips(try model.update([feed.publish(-40, at: Self.ms(100))], at: Self.ms(100))) == [true])
        let stale = try model.update([feed.latest], at: Self.ms(700))
        #expect(Self.signals(stale) == [.unavailable(.stale(ageNanoseconds: 600 * Self.millisecond))])
        #expect(Self.clips(stale) == [true])
        #expect(Self.clips(try model.update([Self.missing(.tooOld)], at: Self.ms(800))) == [true])
        let beforeReset = try model.update([feed.publish(-30, at: Self.ms(900))], at: Self.ms(900))
        model.resetClip()
        let afterReset = try model.update([feed.latest], at: Self.ms(900))
        #expect(Self.clips(afterReset) == [false])
        #expect(Self.signals(afterReset) == Self.signals(beforeReset))
        #expect(Self.clips(try model.update([feed.publish(0, at: Self.ms(1_000))], at: Self.ms(1_000))) == [true])
    }

    @Test
    func rebindClearsTheClipLatchAndBallisticsEvenForAnEqualSource() throws {
        var model = try Self.longTap()
        _ = try model.update([Self.read(3, sequence: 1)], at: Self.ms(0))
        model.rebind(to: model.source)
        let display = try model.update([Self.read(3, sequence: 1)], at: Self.ms(500))
        #expect(Self.clips(display) == [true])
        #expect(Self.signals(display) == [.measured(levelDBFS: 3, peakHoldDBFS: 3)])
        model.rebind(to: model.source)
        let quiet = try model.update([Self.read(-30, sequence: 2)], at: Self.ms(600))
        #expect(Self.clips(quiet) == [false])
        #expect(Self.signals(quiet) == [.measured(levelDBFS: -30, peakHoldDBFS: -30)])
    }

    // MARK: - Invalid readings

    @Test
    func notANumberChangesNothingNotEvenTheClip() throws {
        var model = try Self.longTap()
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-10), at: Self.ms(0))
        let nan = try model.update([feed.publish(.nan)], at: Self.ms(100))
        #expect(Self.signals(nan) == [.unavailable(.invalidReading(.notANumber))])
        #expect(Self.clips(nan) == [false])
        #expect(try Self.signal(&model, feed.latest, at: Self.ms(200)) == .unavailable(.invalidReading(.notANumber)))
        #expect(try Self.signal(&model, feed.publish(-50), at: Self.ms(500))
                == .measured(levelDBFS: -20, peakHoldDBFS: -10))
    }

    @Test
    func positiveInfinityLatchesTheClipButNeverFeedsLevelOrPeak() throws {
        var model = try Self.longTap(clip: 24)
        var feed = try Feed()
        _ = try Self.signal(&model, feed.publish(-10), at: Self.ms(0))
        let infinite = try model.update([feed.publish(.infinity)], at: Self.ms(250))
        #expect(Self.signals(infinite) == [.unavailable(.invalidReading(.positiveInfinity))])
        #expect(Self.clips(infinite) == [true])
        let after = try model.update([feed.publish(-50)], at: Self.ms(500))
        #expect(Self.signals(after) == [.measured(levelDBFS: -20, peakHoldDBFS: -10)])
        #expect(Self.clips(after) == [true])
        model.resetClip()
        #expect(Self.clips(try model.update([feed.latest], at: Self.ms(500))) == [false])
    }

    // MARK: - Ceiling

    @Test
    func hugeFiniteReadingShowsTheCeilingWithTheClipLatched() throws {
        var model = try Self.longTap(clip: 24)
        let sample = try Self.read(1e308, sequence: 1)
        let display = try model.update([sample], at: Self.ms(0))
        #expect(Self.signals(display) == [.measured(levelDBFS: 24, peakHoldDBFS: 24)])
        #expect(Self.clips(display) == [true])
        #expect(try Self.signal(&model, sample, at: Self.ms(1_250)) == .measured(levelDBFS: -1, peakHoldDBFS: 19))
    }

    @Test
    func readingsAreShownUpToTheCeilingAndCappedJustAboveIt() throws {
        let cases: [(reading: Double, shown: Double)] = [
            ((24.0).nextDown, (24.0).nextDown), (24, 24), ((24.0).nextUp, 24), (25, 24), (.greatestFiniteMagnitude, 24)
        ]
        for (reading, shown) in cases {
            var model = try Self.longTap()
            let display = try model.update([Self.read(reading, sequence: 1)], at: Self.ms(0))
            #expect(Self.signals(display) == [.measured(levelDBFS: shown, peakHoldDBFS: shown)])
            #expect(Self.clips(display) == [true])
        }
    }

    // MARK: - Invariants

    @Test(arguments: [UInt64(1), 0xC0FFEE, 0x1020_3040_5060_7080])
    func seededSweepsKeepFloorLevelAndPeakOrderedAndNeverRiseWithoutAReading(seed: UInt64) throws {
        var random = MeterBallisticsSplitMix(seed: seed)
        var model = try Self.longTap(hold: 400_000_000)
        var feed = try Feed()
        var now: UInt64 = 0
        var previous: (level: Double, peak: Double)?
        var clipped = false
        for _ in 0..<400 {
            now += random.below(300) * Self.millisecond
            let published = random.below(2) == 0
            if published {
                let choice = random.below(20)
                let special: [Double] = [-.infinity, .nan, .infinity, 1e300]
                let reading = choice < 4 ? special[Int(choice)] : Double(random.below(97)) - 90
                try feed.publish(reading, at: MeterInstant(nanoseconds: now))
                clipped = clipped || reading >= 0
            }
            let display = try model.update([feed.latest], at: MeterInstant(nanoseconds: now))
            #expect(Self.clips(display) == [clipped])
            guard let signal = Self.signals(display).first, let current = Self.levels(signal) else {
                previous = nil
                continue
            }
            #expect(-60 <= current.level && current.level <= current.peak && current.peak <= 24)
            if !published, let previous {
                #expect(current.level <= previous.level && current.peak <= previous.peak)
            }
            previous = current
        }
    }
}
