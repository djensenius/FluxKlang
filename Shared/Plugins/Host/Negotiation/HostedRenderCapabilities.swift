/// What a hosted plugin REPORTS it can render: maximum block size, sample rate range and supported formats.
///
/// A value exists only if the throwing `init` accepted it. Checks, first failure wins: frames in
/// `1...RenderNegotiationLimits.maximumFrames`, minimum rate, maximum rate (each in the accepted rate range), minimum
/// not above maximum (reported as `.invalidSampleRate(minimumSampleRateHz)`), formats non-empty and without
/// duplicates (`.noSupportedFormat`). `formats` is stored in `RenderSampleFormat.allCases` order so equal sets compare
/// equal whatever order they were supplied in.
struct HostedRenderCapabilities: Hashable, Sendable {
    let maximumFramesToRender: Int
    let minimumSampleRateHz: Int
    let maximumSampleRateHz: Int
    let formats: [RenderSampleFormat]

    init(
        maximumFramesToRender: Int, minimumSampleRateHz: Int, maximumSampleRateHz: Int,
        formats: [RenderSampleFormat]
    ) throws(RenderSpecFault) {
        guard (1...RenderNegotiationLimits.maximumFrames).contains(maximumFramesToRender) else {
            throw .invalidMaximumFrames(maximumFramesToRender)
        }
        let rates = RenderNegotiationLimits.minimumSampleRateHz...RenderNegotiationLimits.maximumSampleRateHz
        guard rates.contains(minimumSampleRateHz) else { throw .invalidSampleRate(minimumSampleRateHz) }
        guard rates.contains(maximumSampleRateHz) else { throw .invalidSampleRate(maximumSampleRateHz) }
        guard minimumSampleRateHz <= maximumSampleRateHz else { throw .invalidSampleRate(minimumSampleRateHz) }
        let ordered = RenderSampleFormat.allCases.filter { formats.contains($0) }
        guard !formats.isEmpty, ordered.count == formats.count else { throw .noSupportedFormat }
        self.maximumFramesToRender = maximumFramesToRender
        self.minimumSampleRateHz = minimumSampleRateHz
        self.maximumSampleRateHz = maximumSampleRateHz
        self.formats = ordered
    }
}
