/// Why a render spec, bus spec or capability report was refused. Values carry counts only, never text.
enum RenderSpecFault: Error, Hashable, Sendable {
    case invalidChannelCount(Int)
    case invalidSampleRate(Int)
    case invalidMaximumFrames(Int)
    case tooManyBuses(PluginBusDirection, count: Int)
    case noEnabledOutput
    case scratchTooLarge(requiredBytes: Int)
    case scratchOverflow
    case noSupportedFormat
}

/// A validated render resource request: rate, maximum block size, sample format and the bus arrays.
///
/// A value exists only if the throwing `init` accepted it; the stored properties are immutable. Checks run in this
/// order and the first failure wins: maximum frames, sample rate, input bus count, output bus count, at least one
/// enabled output bus, scratch size. `requiredScratchBytes` is the plugin-side render buffer size of ONE maximum block
/// (enabled channels x maximum frames x bytes per sample); the scratch requirement excludes alignment padding and
/// plugin-internal allocations, so it is a necessary, not a sufficient, bound.
struct RenderResourceSpec: Hashable, Sendable {
    let sampleRateHz: Int
    let maximumFrames: Int
    let format: RenderSampleFormat
    let inputs: [RenderBusSpec]
    let outputs: [RenderBusSpec]
    let requiredScratchBytes: Int

    var enabledInputCount: Int { Self.enabledCount(inputs) }
    var enabledOutputCount: Int { Self.enabledCount(outputs) }

    init(
        sampleRateHz: Int, maximumFrames: Int, format: RenderSampleFormat,
        inputs: [RenderBusSpec], outputs: [RenderBusSpec]
    ) throws(RenderSpecFault) {
        guard (1...RenderNegotiationLimits.maximumFrames).contains(maximumFrames) else {
            throw .invalidMaximumFrames(maximumFrames)
        }
        guard (RenderNegotiationLimits.minimumSampleRateHz...RenderNegotiationLimits.maximumSampleRateHz)
            .contains(sampleRateHz) else {
            throw .invalidSampleRate(sampleRateHz)
        }
        guard inputs.count <= RenderNegotiationLimits.busesPerDirection else {
            throw .tooManyBuses(.input, count: inputs.count)
        }
        guard outputs.count <= RenderNegotiationLimits.busesPerDirection else {
            throw .tooManyBuses(.output, count: outputs.count)
        }
        guard outputs.contains(where: \.isEnabled) else { throw .noEnabledOutput }
        let channels = try Self.enabledChannels(inputs).addingChecked(Self.enabledChannels(outputs))
        let samples = channels.multipliedReportingOverflow(by: maximumFrames)
        let bytes = samples.partialValue.multipliedReportingOverflow(by: format.bytesPerSample)
        guard !samples.overflow, !bytes.overflow else { throw .scratchOverflow }
        guard bytes.partialValue <= RenderNegotiationLimits.scratchBytes else {
            throw .scratchTooLarge(requiredBytes: bytes.partialValue)
        }
        self.sampleRateHz = sampleRateHz
        self.maximumFrames = maximumFrames
        self.format = format
        self.inputs = inputs
        self.outputs = outputs
        self.requiredScratchBytes = bytes.partialValue
    }

    private static func enabledCount(_ buses: [RenderBusSpec]) -> Int {
        buses.reduce(0) { $0 + ($1.isEnabled ? 1 : 0) }
    }

    private static func enabledChannels(_ buses: [RenderBusSpec]) throws(RenderSpecFault) -> Int {
        var total = 0
        for bus in buses where bus.isEnabled {
            let sum = total.addingReportingOverflow(bus.channels)
            guard !sum.overflow else { throw .scratchOverflow }
            total = sum.partialValue
        }
        return total
    }
}

private extension Int {
    func addingChecked(_ other: Int) throws(RenderSpecFault) -> Int {
        let sum = addingReportingOverflow(other)
        guard !sum.overflow else { throw .scratchOverflow }
        return sum.partialValue
    }
}
