//
//  SpatialMixerRefusal.swift
//  FluxKlang
//
//  Typed refusals, the process result and the validated limits of the offline
//  spatial block mixer (#115 SM2).
//

/// Why the mixer refused to be built, to change plan or to process a block.
/// Every refusal leaves the mixer's plan, ramp and delay lines unchanged.
enum SpatialMixerRefusal: Error, Equatable, Sendable {
    /// The limits are outside the accepted ranges.
    case invalidLimits
    /// The plan has more rows or speakers than the limits allow.
    case planTooLarge
    /// The plan's array sizes disagree or a delay is negative. Plans built by
    /// `SpatialRenderer` can never trigger this; it is a defence only.
    case invalidPlan
    /// A speaker's delay exceeds the delay capacity of the limits' sample rate.
    case delayTooLong(Int)
    /// The ramp length is outside `0...48,000`.
    case invalidRampFrames(Int)
    /// A ramp is running and a new ramp of more than 0 frames was requested.
    case transitionInProgress
    /// The block length is outside `0...maxFrames`.
    case invalidFrames(Int)
    /// A buffer's element count differs from the current planar geometry.
    case geometryMismatch
    /// The input and output buffers share memory.
    case overlappingBuffers
}

/// The outcome of one `process` call.
enum SpatialMixerResult: Equatable, Sendable {
    /// Every output frame was written. `sanitizedSamples` counts the samples
    /// replaced by 0: non-finite input samples and non-finite computed samples.
    case processed(sanitizedSamples: Int)
    /// Nothing was advanced. Buffer geometry refusals touch no memory; an
    /// invalid frame count silences the whole output buffer.
    case refused(SpatialMixerRefusal)
}

/// The fixed sizes a mixer is built for. Only `make` constructs one.
struct SpatialMixerLimits: Equatable, Sendable {
    static let frameRange = 1...8_192
    static let speakerRange = 1...64
    static let rowRange = 1...128
    /// The longest accepted ramp, the same bound as `SpatialGainRamp`.
    static let rampRange = 0...48_000
    /// The longest delay is 50 ms (`SpeakerCalibration.delayRange`), so capacity is `rate / 20`.
    static let delayDivisor = 20.0

    let maxFrames: Int
    let sampleRate: Double
    let maxRows: Int
    let maxSpeakers: Int

    private init(maxFrames: Int, sampleRate: Double, maxRows: Int, maxSpeakers: Int) {
        self.maxFrames = maxFrames
        self.sampleRate = sampleRate
        self.maxRows = maxRows
        self.maxSpeakers = maxSpeakers
    }

    /// The largest accepted delay in frames: `ceil(sampleRate / 20)`, 19,200 at 384 kHz.
    var delayCapacity: Int { Int((sampleRate / Self.delayDivisor).rounded(.up)) }

    static func make(
        maxFrames: Int, sampleRate: Double, maxRows: Int, maxSpeakers: Int
    ) throws(SpatialMixerRefusal) -> Self {
        guard frameRange.contains(maxFrames), SpatialSampleRate.range.contains(sampleRate),
              rowRange.contains(maxRows), speakerRange.contains(maxSpeakers) else {
            throw .invalidLimits
        }
        return Self(maxFrames: maxFrames, sampleRate: sampleRate, maxRows: maxRows, maxSpeakers: maxSpeakers)
    }

    /// Checks a plan against these limits at the point of use. Order: size, shape, delay.
    func validate(_ plan: SpatialRenderPlan) throws(SpatialMixerRefusal) {
        guard plan.rowCount <= maxRows, plan.speakerCount <= maxSpeakers else { throw .planTooLarge }
        let (cells, overflow) = plan.rowCount.multipliedReportingOverflow(by: plan.speakerCount)
        guard !overflow, plan.gains.count == cells, plan.delayFrames.count == plan.speakerCount,
              !plan.delayFrames.contains(where: { $0 < 0 }) else {
            throw .invalidPlan
        }
        let capacity = delayCapacity
        if let delay = plan.delayFrames.first(where: { $0 > capacity }) { throw .delayTooLong(delay) }
    }
}
