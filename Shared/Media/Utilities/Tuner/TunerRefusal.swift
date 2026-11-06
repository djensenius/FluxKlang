//
//  TunerRefusal.swift
//  FluxKlang
//
//  Typed refusals of the advisory tuner (#111 TU1). A refused configuration is
//  never clamped into range, and a refused frame leaves the estimator unchanged.
//

/// Why a tuner configuration, pitch, smoothing policy or analysis frame is refused.
enum TunerRefusal: Error, Equatable, Sendable {
    /// The sample rate is not a media nominal rate (`MediaNominalRate.isValid`).
    case invalidSampleRate(Int)
    /// The A4 reference must be finite and lie in `TunerReference.hertzRange` (415…466 Hz).
    case referenceOutOfRange(Double)
    /// Both bounds must be finite, lie in `TunerConfiguration.frequencyRange`, and span at least an octave.
    case frequencyRangeInvalid(minimum: Double, maximum: Double)
    /// The analysis window must lie in `TunerConfiguration.windowSizeRange` (2048…32768 samples).
    case windowSizeOutOfRange(Int)
    /// The window must hold two periods of the lowest frequency (`required` samples) at this sample rate.
    case windowTooShort(windowSize: Int, required: Int)
    /// The YIN threshold must be finite and lie in `TunerConfiguration.thresholdRange`.
    case thresholdOutOfRange(Double)
    /// The level floor must be finite and lie in `TunerConfiguration.levelFloorRange` (dBFS).
    case levelFloorOutOfRange(Double)
    /// A frame must hold exactly the configured window of samples.
    case frameLengthMismatch(expected: Int, actual: Int)
    /// The frame holds a NaN or infinite sample at `index`; nothing is analysed.
    case nonFiniteSample(index: Int)
    /// A pitch frequency must be finite and lie in `TunerPitch.frequencyRange`.
    case frequencyOutOfRange(Double)
    /// A confidence must be finite and lie in `0...1`.
    case confidenceOutOfRange(Double)
    /// The smoothing window must lie in `TunerSmoothingPolicy.windowRange`.
    case smoothingWindowOutOfRange(Int)
    /// The display deadband must be finite and lie in `TunerSmoothingPolicy.deadbandRange` (cents).
    case deadbandOutOfRange(Double)
    /// The jump size must be finite, lie in `TunerSmoothingPolicy.jumpRange` and exceed the deadband.
    case jumpOutOfRange(Double)
    /// The hold count must lie in `TunerSmoothingPolicy.holdRange`.
    case holdOutOfRange(Int)
}
