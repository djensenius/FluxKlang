//
//  TunerSmoother.swift
//  FluxKlang
//
//  Deterministic, bounded display smoothing for the advisory tuner (#111 TU1):
//    • voiced readings are averaged in the log-frequency domain over the last
//      `window` readings (a fixed ring allocated at init);
//    • a reading at least `jump` cents from that mean is a new note: the ring
//      restarts from it, so the display follows it at once;
//    • the displayed pitch moves only when the mean leaves a ±`deadband`-cent
//      band around it (hysteresis), so jitter does not flicker the display;
//    • up to `hold` consecutive no-pitch readings keep the last display, marked
//      held; the next one clears the ring and shows the typed no-pitch reason.
//  Guarantees: if every reading lies within ±J cents of a centre, the mean and
//  so the display do too, and a deadband of at least 2J freezes the display
//  once the ring is full. A step of more than `deadband` (and less than `jump`)
//  is shown within `deadband` cents after `window` readings; a step of at least
//  `jump` is shown exactly after one. A change of A4 reference also restarts.
//

import Foundation

/// A validated smoothing policy. Built only through `make`.
struct TunerSmoothingPolicy: Hashable, Sendable {
    static let windowRange = 1...16
    static let deadbandRange: ClosedRange<Double> = 0...10
    static let jumpRange: ClosedRange<Double> = 10...1200
    static let holdRange = 0...16
    /// Eight readings, a 1-cent deadband, a 50-cent jump and a 4-reading hold.
    static let standard = TunerSmoothingPolicy(window: 8, deadband: 1, jump: 50, hold: 4)

    /// Readings averaged.
    let window: Int
    /// Cents the mean must move past the display before the display changes.
    let deadband: Double
    /// Cents from the mean at which a reading restarts the average.
    let jump: Double
    /// No-pitch readings that keep the last display before it clears.
    let hold: Int

    private init(window: Int, deadband: Double, jump: Double, hold: Int) {
        self.window = window
        self.deadband = deadband
        self.jump = jump
        self.hold = hold
    }

    static func make(window: Int, deadband: Double, jump: Double,
                     hold: Int) throws(TunerRefusal) -> TunerSmoothingPolicy {
        guard windowRange.contains(window) else { throw .smoothingWindowOutOfRange(window) }
        guard deadband.isFinite, deadbandRange.contains(deadband) else { throw .deadbandOutOfRange(deadband) }
        guard jump.isFinite, jumpRange.contains(jump), jump > deadband else { throw .jumpOutOfRange(jump) }
        guard holdRange.contains(hold) else { throw .holdOutOfRange(hold) }
        return TunerSmoothingPolicy(window: window, deadband: deadband, jump: jump, hold: hold)
    }
}

/// What the tuner shows.
enum TunerDisplay: Hashable, Sendable {
    /// The smoothed pitch; `held` while it is kept through no-pitch readings.
    case pitch(TunerPitch, held: Bool)
    case noPitch(TunerNoPitch)

    var pitch: TunerPitch? {
        if case .pitch(let pitch, _) = self { pitch } else { nil }
    }
}

/// Smooths a `TunerReading` stream for display. Advisory only.
struct TunerSmoother {
    let policy: TunerSmoothingPolicy
    /// Positions in absolute cents (`1200·log2(Hz)`) and confidences, as rings of `policy.window`.
    private var positions: [Double]
    private var confidences: [Double]
    private var count = 0
    private var next = 0
    private var reference: TunerReference?
    private var displayedPosition: Double?
    private var displayed: TunerPitch?
    private var missed = 0

    init(policy: TunerSmoothingPolicy = .standard) {
        self.policy = policy
        positions = [Double](repeating: 0, count: policy.window)
        confidences = [Double](repeating: 0, count: policy.window)
    }

    /// The rings' combined capacity; it never changes after init.
    var storageCapacity: Int { positions.capacity + confidences.capacity }

    mutating func smooth(_ reading: TunerReading) -> TunerDisplay {
        switch reading {
        case .pitch(let pitch):
            return .pitch(accept(pitch), held: false)
        case .noPitch(let reason):
            if let displayed, missed < policy.hold {
                missed += 1
                return .pitch(displayed, held: true)
            }
            reset()
            return .noPitch(reason)
        }
    }

    /// Forgets every reading and the display.
    mutating func reset() {
        count = 0
        next = 0
        reference = nil
        displayedPosition = nil
        displayed = nil
        missed = 0
    }

    private func mean(_ ring: [Double]) -> Double {
        var sum = 0.0
        for index in 0..<count { sum += ring[index] }
        return sum / Double(count)
    }

    private mutating func accept(_ pitch: TunerPitch) -> TunerPitch {
        let position = 1200 * log2(pitch.frequency)
        if reference != pitch.reference || (count > 0 && abs(position - mean(positions)) >= policy.jump) {
            reset()
        }
        missed = 0
        reference = pitch.reference
        positions[next] = position
        confidences[next] = pitch.confidence
        next = (next + 1) % policy.window
        count = min(count + 1, policy.window)
        let average = mean(positions)
        let shown: Double
        if let current = displayedPosition, abs(average - current) <= policy.deadband {
            shown = current
        } else {
            shown = average
        }
        displayedPosition = shown
        // The mean of in-range frequencies is in range; should rounding at the range edge refuse it,
        // the unsmoothed pitch is shown instead.
        let smoothed = (try? TunerPitch.make(frequency: exp2(shown / 1200), confidence: mean(confidences),
                                             reference: pitch.reference)) ?? pitch
        displayed = smoothed
        return smoothed
    }
}
