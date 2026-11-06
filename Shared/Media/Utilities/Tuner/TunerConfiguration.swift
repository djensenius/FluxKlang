//
//  TunerConfiguration.swift
//  FluxKlang
//
//  The validated policy values of the advisory tuner (#111 TU1, ruling Q-TU1):
//  the A4 reference (415…466 Hz, default 440), the sample rate (a media
//  nominal rate), the frequency band, the analysis window (at least 2048
//  samples and two periods of the lowest frequency), the YIN threshold and
//  the level floor below which a frame is too quiet to analyse.
//

import Foundation

/// A validated concert-pitch reference for A4.
struct TunerReference: Hashable, Sendable {
    static let hertzRange: ClosedRange<Double> = 415...466
    /// A4 = 440 Hz.
    static let standard = TunerReference(validatedHertz: 440)

    let hertz: Double

    private init(validatedHertz: Double) {
        hertz = validatedHertz
    }

    static func make(hertz: Double) throws(TunerRefusal) -> TunerReference {
        guard hertz.isFinite, hertzRange.contains(hertz) else { throw .referenceOutOfRange(hertz) }
        return TunerReference(validatedHertz: hertz)
    }
}

/// A validated tuner analysis configuration. Built only through `make`.
struct TunerConfiguration: Hashable, Sendable {
    static let frequencyRange: ClosedRange<Double> = 20...5000
    static let windowSizeRange = 2048...32_768
    static let thresholdRange: ClosedRange<Double> = 0.05...0.5
    static let levelFloorRange: ClosedRange<Double> = -120 ... -20
    static let defaultMinimumFrequency = 30.0
    static let defaultMaximumFrequency = 2000.0
    static let defaultThreshold = 0.15
    static let defaultLevelFloor = -60.0

    let sampleRate: Int
    let reference: TunerReference
    /// The lowest frequency searched (Hz).
    let minimumFrequency: Double
    /// The highest frequency searched (Hz).
    let maximumFrequency: Double
    /// Samples per analysis frame.
    let windowSize: Int
    /// The YIN absolute threshold: a period is voiced only when its normalized difference falls below it.
    let threshold: Double
    /// The level floor in dBFS (RMS against a full-scale value of 1).
    let levelFloor: Double
    /// The longest lag computed: `ceil(sampleRate / minimumFrequency) + 1`, so the longest period has a right
    /// neighbour.
    let maximumLag: Int
    /// The mean square sample value at the level floor: `10^(levelFloor / 10)`.
    let levelFloorPower: Double

    /// The confidence a voiced reading exceeds: `1 - threshold`.
    var minimumConfidence: Double { 1 - threshold }

    private init(sampleRate: Int, reference: TunerReference, band: (Double, Double), windowSize: Int,
                 threshold: Double, levelFloor: Double, maximumLag: Int) {
        self.sampleRate = sampleRate
        self.reference = reference
        (minimumFrequency, maximumFrequency) = band
        self.windowSize = windowSize
        self.threshold = threshold
        self.levelFloor = levelFloor
        self.maximumLag = maximumLag
        levelFloorPower = pow(10, levelFloor / 10)
    }

    /// The longest lag the band needs at `sampleRate`.
    /// - Precondition: `minimumFrequency` is finite and > 0, and `sampleRate` is valid (`make` validates both
    ///   before calling); otherwise the result is meaningless or the conversion to `Int` traps.
    static func maximumLag(sampleRate: Int, minimumFrequency: Double) -> Int {
        Int((Double(sampleRate) / minimumFrequency).rounded(.up)) + 1
    }

    /// The shortest window that holds two of the longest lags: one to integrate over, one to shift by.
    /// - Precondition: as for `maximumLag(sampleRate:minimumFrequency:)`; `make` validates before calling.
    static func requiredWindowSize(sampleRate: Int, minimumFrequency: Double) -> Int {
        2 * maximumLag(sampleRate: sampleRate, minimumFrequency: minimumFrequency)
    }

    /// The default window: the smallest power of two that is at least 2048 and the required window.
    /// - Precondition: as for `maximumLag(sampleRate:minimumFrequency:)`; `make` validates before calling.
    static func defaultWindowSize(sampleRate: Int, minimumFrequency: Double) -> Int {
        let required = max(windowSizeRange.lowerBound,
                           requiredWindowSize(sampleRate: sampleRate, minimumFrequency: minimumFrequency))
        var size = windowSizeRange.lowerBound
        while size < required { size *= 2 }
        return size
    }

    /// Validates every value; nothing is clamped. `windowSize` nil picks `defaultWindowSize`
    /// (4096 at 44.1 or 48 kHz with the default 30 Hz floor).
    static func make(
        sampleRate: Int, reference: TunerReference = .standard,
        minimumFrequency: Double = defaultMinimumFrequency, maximumFrequency: Double = defaultMaximumFrequency,
        windowSize: Int? = nil, threshold: Double = defaultThreshold, levelFloor: Double = defaultLevelFloor
    ) throws(TunerRefusal) -> TunerConfiguration {
        guard MediaNominalRate.isValid(sampleRate) else { throw .invalidSampleRate(sampleRate) }
        guard minimumFrequency.isFinite, maximumFrequency.isFinite,
              frequencyRange.contains(minimumFrequency), frequencyRange.contains(maximumFrequency),
              maximumFrequency >= 2 * minimumFrequency else {
            throw .frequencyRangeInvalid(minimum: minimumFrequency, maximum: maximumFrequency)
        }
        let size = windowSize ?? defaultWindowSize(sampleRate: sampleRate, minimumFrequency: minimumFrequency)
        guard windowSizeRange.contains(size) else { throw .windowSizeOutOfRange(size) }
        let required = requiredWindowSize(sampleRate: sampleRate, minimumFrequency: minimumFrequency)
        guard size >= required else { throw .windowTooShort(windowSize: size, required: required) }
        guard threshold.isFinite, thresholdRange.contains(threshold) else { throw .thresholdOutOfRange(threshold) }
        guard levelFloor.isFinite, levelFloorRange.contains(levelFloor) else {
            throw .levelFloorOutOfRange(levelFloor)
        }
        return TunerConfiguration(
            sampleRate: sampleRate, reference: reference, band: (minimumFrequency, maximumFrequency),
            windowSize: size, threshold: threshold, levelFloor: levelFloor,
            maximumLag: maximumLag(sampleRate: sampleRate, minimumFrequency: minimumFrequency)
        )
    }
}
