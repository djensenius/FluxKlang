import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("Tuner display smoother", .productionAccessAudit)
#else
@Suite("Tuner display smoother")
#endif
struct TunerSmootherTests {
    static let centre = 220.0

    static func policy(window: Int = 8, deadband: Double = 1, jump: Double = 50,
                       hold: Int = 4) throws -> TunerSmoothingPolicy {
        try TunerSmoothingPolicy.make(window: window, deadband: deadband, jump: jump, hold: hold)
    }

    static func reading(_ cents: Double, reference: TunerReference = .standard) throws -> TunerReading {
        try .pitch(TunerPitchTests.pitch(centre, cents: cents, reference: reference))
    }

    /// The displayed pitch in cents from the centre, or nil for no pitch.
    static func shown(_ display: TunerDisplay) -> Double? {
        display.pitch.map { TunerPitchTests.cents($0.frequency, from: centre) }
    }

    @Test
    func policiesAreValidatedAtEveryBound() throws {
        func refused(window: Int = 8, deadband: Double = 1, jump: Double = 50, hold: Int = 4) -> TunerRefusal? {
            TunerPitchTests.refusal { () throws(TunerRefusal) in
                try TunerSmoothingPolicy.make(window: window, deadband: deadband, jump: jump, hold: hold)
            }
        }
        #expect(refused(window: 1) == nil && refused(window: 16) == nil)
        #expect(refused(window: 0) == .smoothingWindowOutOfRange(0))
        #expect(refused(window: 17) == .smoothingWindowOutOfRange(17))
        #expect(refused(deadband: 0) == nil && refused(deadband: 10, jump: 10.001) == nil)
        #expect(refused(deadband: -0.001) == .deadbandOutOfRange(-0.001))
        #expect(refused(deadband: 10.001) == .deadbandOutOfRange(10.001))
        #expect(refused(deadband: .infinity) == .deadbandOutOfRange(.infinity))
        #expect(refused(jump: 10) == nil && refused(jump: 1200) == nil)
        #expect(refused(jump: 9.999) == .jumpOutOfRange(9.999))
        #expect(refused(jump: 1200.001) == .jumpOutOfRange(1200.001))
        #expect(refused(deadband: 10, jump: 10) == .jumpOutOfRange(10))
        #expect(refused(hold: 0) == nil && refused(hold: 16) == nil)
        #expect(refused(hold: -1) == .holdOutOfRange(-1))
        #expect(refused(hold: 17) == .holdOutOfRange(17))
        let standard = TunerSmoothingPolicy.standard
        #expect(standard == (try Self.policy()))
    }

    @Test
    func alternatingJitterOfThreeCentsIsSuppressed() throws {
        var smoother = TunerSmoother()
        var shown: [Double] = []
        for index in 0..<64 {
            shown.append(try #require(Self.shown(smoother.smooth(Self.reading(index.isMultiple(of: 2) ? 3 : -3)))))
        }
        // Once the eight-reading ring is full, the display is the centre and never moves.
        for value in shown.dropFirst(8) {
            #expect(abs(value) < 1e-6, "\(value)")
            #expect(abs(value - shown[8]) < 1e-9)
        }
    }

    @Test
    func boundedJitterStaysWithinItsBoundAndADoubleDeadbandFreezesIt() throws {
        let jitter = TunerPitchTests.jitter(seed: 7, count: 200, bound: 3)
        var standard = TunerSmoother()
        var frozen = try TunerSmoother(policy: Self.policy(deadband: 6))
        var changes = 0
        var rawChanges = 0
        var previous: Double?
        var frozenShown: Double?
        for (index, offset) in jitter.enumerated() {
            let value = try #require(Self.shown(standard.smooth(Self.reading(offset))))
            let still = try #require(Self.shown(frozen.smooth(Self.reading(offset))))
            #expect(abs(value) <= 3 + 1e-9 && abs(still) <= 3 + 1e-9)
            if index >= 8 {
                if let previous, abs(value - previous) > 1e-9 { changes += 1 }
                if abs(offset - jitter[index - 1]) > 1e-9 { rawChanges += 1 }
                if let frozenShown { #expect(abs(still - frozenShown) < 1e-9, "reading \(index)") }
                frozenShown = still
            }
            previous = value
        }
        #expect(rawChanges == 192)
        #expect(changes * 4 < rawChanges, "\(changes) display changes")
    }

    @Test
    func smallStepsArriveWithinTheWindowAndJumpsAtOnce() throws {
        var smoother = TunerSmoother()
        for _ in 0..<8 { _ = smoother.smooth(try Self.reading(0)) }
        // A 20-cent step (below the 50-cent jump) is shown within the 1-cent deadband after eight readings.
        var shown: [Double] = []
        for _ in 0..<8 { shown.append(try #require(Self.shown(smoother.smooth(Self.reading(20))))) }
        #expect(shown[0] < 20 - 1, "the first reading is averaged, not jumped to: \(shown[0])")
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        #expect(abs(shown[7] - 20) <= 1 + 1e-9)
        #expect(abs(shown[6] - 20) > 1, "the ring needs all eight readings: \(shown[6])")
        // A 60-cent step (at least the jump) restarts the ring: shown exactly after one reading.
        let jumped = try #require(Self.shown(smoother.smooth(Self.reading(80))))
        #expect(abs(jumped - 80) < 1e-9)
        // A one-reading ring follows every reading exactly; a 16-reading ring needs 16.
        var single = try TunerSmoother(policy: Self.policy(window: 1, deadband: 0))
        for offset in [0.0, 5, -7, 12] {
            #expect(abs(try #require(Self.shown(single.smooth(Self.reading(offset)))) - offset) < 1e-9)
        }
        var long = try TunerSmoother(policy: Self.policy(window: 16))
        _ = long.smooth(try Self.reading(0))
        var last = 0.0
        for _ in 0..<16 { last = try #require(Self.shown(long.smooth(Self.reading(30)))) }
        #expect(abs(last - 30) <= 1 + 1e-9)
    }

    @Test
    func noPitchIsHeldThenShownAndTheRingRestarts() throws {
        var smoother = TunerSmoother()
        for _ in 0..<8 { _ = smoother.smooth(try Self.reading(10)) }
        let unvoiced = TunerReading.noPitch(.unvoiced(confidence: 0.3))
        for _ in 0..<4 {
            guard case .pitch(let pitch, held: true) = smoother.smooth(unvoiced) else {
                Issue.record("not held")
                return
            }
            #expect(abs(TunerPitchTests.cents(pitch.frequency, from: Self.centre) - 10) < 1e-9)
        }
        #expect(smoother.smooth(unvoiced) == .noPitch(.unvoiced(confidence: 0.3)))
        #expect(smoother.smooth(.noPitch(.insufficientSignal)) == .noPitch(.insufficientSignal))
        // After the hold the ring is empty: the next reading is shown as it is, not averaged with the old note.
        let fresh = try #require(Self.shown(smoother.smooth(Self.reading(-30))))
        #expect(abs(fresh + 30) < 1e-9)
        // A pitch within the hold resets the miss count and keeps the ring.
        for _ in 0..<3 { #expect(smoother.smooth(.noPitch(.outOfBand)).pitch != nil) }
        let resumed = try #require(Self.shown(smoother.smooth(Self.reading(-26))))
        #expect(abs(resumed + 28) < 1e-9, "averaged with the kept reading: \(resumed)")
        for _ in 0..<4 {
            guard case .pitch(_, held: true) = smoother.smooth(.noPitch(.outOfBand)) else {
                Issue.record("the miss count was not reset")
                return
            }
        }
        #expect(smoother.smooth(.noPitch(.outOfBand)) == .noPitch(.outOfBand))
    }

    @Test
    func theJumpAndDeadbandBoundsAreInclusive() throws {
        // The smoother measures in 1200·log2(Hz); with one reading in the ring the mean is that reading exactly,
        // so a step of exactly `step` cents meets each bound exactly.
        let low = try TunerPitchTests.pitch(Self.centre)
        let high = try TunerPitchTests.pitch(Self.centre, cents: 30)
        let step = abs(1200 * log2(high.frequency) - 1200 * log2(low.frequency))
        // A step equal to the jump restarts the ring: shown as it is, not averaged.
        var jumping = try TunerSmoother(policy: Self.policy(deadband: 0, jump: step))
        _ = jumping.smooth(.pitch(low))
        #expect(abs(try #require(Self.shown(jumping.smooth(.pitch(high)))) - 30) < 1e-9)
        // A mean exactly `deadband` from the display keeps the display.
        let quarter = try TunerPitchTests.pitch(Self.centre, cents: 7.5)
        let band = abs(1200 * log2(quarter.frequency) - 1200 * log2(low.frequency))
        var steady = try TunerSmoother(policy: Self.policy(window: 1, deadband: band, jump: 50))
        _ = steady.smooth(.pitch(low))
        #expect(abs(try #require(Self.shown(steady.smooth(.pitch(quarter))))) < 1e-9)
        var immediate = try TunerSmoother(policy: Self.policy(hold: 0))
        _ = immediate.smooth(try Self.reading(0))
        #expect(immediate.smooth(.noPitch(.outOfBand)) == .noPitch(.outOfBand))
    }

    @Test
    func aNewReferenceRestartsAndConfidenceIsAveraged() throws {
        var smoother = TunerSmoother()
        _ = smoother.smooth(try Self.reading(0))
        let reference = try TunerReference.make(hertz: 442)
        let display = smoother.smooth(try Self.reading(4, reference: reference))
        let pitch = try #require(display.pitch)
        #expect(pitch.reference == reference)
        #expect(abs(TunerPitchTests.cents(pitch.frequency, from: Self.centre) - 4) < 1e-9)
        var averaged = TunerSmoother()
        let low = try TunerPitch.make(frequency: Self.centre, confidence: 0.86, reference: .standard)
        let high = try TunerPitch.make(frequency: Self.centre, confidence: 0.96, reference: .standard)
        _ = averaged.smooth(.pitch(low))
        #expect(abs((averaged.smooth(.pitch(high)).pitch?.confidence ?? 0) - 0.91) < 1e-12)
        let capacity = averaged.storageCapacity
        #expect(capacity >= 16)
        for index in 0..<40 { _ = averaged.smooth(try Self.reading(Double(index % 5))) }
        #expect(averaged.storageCapacity == capacity)
        averaged.reset()
        #expect(averaged.smooth(.noPitch(.insufficientSignal)) == .noPitch(.insufficientSignal))
    }
}
