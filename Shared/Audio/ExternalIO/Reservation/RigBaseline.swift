//
//  RigBaseline.swift
//  FluxKlang
//
//  The rig configuration baseline recorded before an experiment and compared again at restoration.
//

/// The clock part of a baseline: a source label, a sample rate and a buffer size.
struct RigClockBaseline: Hashable, Sendable {
    private(set) var source: RigToken
    private(set) var sampleRateHertz: Int
    private(set) var bufferFrames: Int

    /// Refusals, in order: sample rate outside 8_000...768_000, then buffer outside 1...16_384.
    init(source: RigToken, sampleRateHertz: Int, bufferFrames: Int) throws(RigReservationRefusal) {
        let rates = RigReservationLimits.minimumSampleRateHertz...RigReservationLimits.maximumSampleRateHertz
        guard rates.contains(sampleRateHertz) else {
            throw .invalidSampleRate(sampleRateHertz)
        }
        let buffers = RigReservationLimits.minimumBufferFrames...RigReservationLimits.maximumBufferFrames
        guard buffers.contains(bufferFrames) else {
            throw .invalidBufferFrames(bufferFrames)
        }
        self.source = source
        self.sampleRateHertz = sampleRateHertz
        self.bufferFrames = bufferFrames
    }
}

/// The full configuration baseline of a rig. Tokens are opaque digests or labels chosen by the caller; the ledger
/// never interprets them, it only compares them for equality.
struct RigBaseline: Hashable, Sendable {
    let clock: RigClockBaseline
    let ioConfiguration: RigToken
    let mixerConfiguration: RigToken
    let signalPath: RigToken
    let fallbackPath: RigToken

    /// How many of the seven fields differ, 0...7: clock source, sample rate, buffer frames, I/O configuration,
    /// mixer configuration, signal path, fallback path. Zero exactly when the baselines are equal.
    func differingFieldCount(from other: RigBaseline) -> Int {
        let differences = [
            clock.source != other.clock.source,
            clock.sampleRateHertz != other.clock.sampleRateHertz,
            clock.bufferFrames != other.clock.bufferFrames,
            ioConfiguration != other.ioConfiguration,
            mixerConfiguration != other.mixerConfiguration,
            signalPath != other.signalPath,
            fallbackPath != other.fallbackPath
        ]
        return differences.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}
