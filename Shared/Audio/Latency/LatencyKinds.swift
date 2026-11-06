//
//  LatencyKinds.swift
//  FluxKlang
//
//  Distinguishes latency evidence from the callback duration budget.
//

/// What a latency number describes. Different kinds have different reference semantics.
enum LatencyKind: String, CaseIterable, Hashable, Sendable {
    case analogRoundTrip
    case digitalCalibration
    case softwareImpulseDelay
    case reported

    /// Whether this value comes from measurement rather than an unmeasured report.
    var isMeasured: Bool { self != .reported }
}

/// Why a latency value, stream setup, calibration configuration, or producer ID is invalid.
enum LatencyRefusal: Error, Hashable, Sendable {
    case negativeFrames(Int64)
    case uncertaintyRequired(LatencyKind)
    case uncertaintyNotAllowed(LatencyKind)
    case negativeUncertainty(Int64)
    case sampleRateOutOfRange(Int)
    case inputBufferOutOfRange(Int)
    case outputBufferOutOfRange(Int)
    case noRoutes
    case tooManyRoutes(count: Int)
    case duplicateRoute(RouteID)
    case invalidRouteChannels(RouteID)
    case routeDeviceMismatch(RouteID, expected: DeviceID, found: DeviceID)
    case invalidProducerID(bytes: Int)
}

/// A non-negative frame latency with an explicit kind and uncertainty semantics.
struct LatencyMeasurement: Hashable, Sendable {
    let kind: LatencyKind
    let frames: Int64
    /// A plus/minus frame bound for measured kinds; nil only for an unmeasured report.
    let uncertaintyFrames: Int64?

    private init(kind: LatencyKind, frames: Int64, uncertaintyFrames: Int64?) {
        self.kind = kind
        self.frames = frames
        self.uncertaintyFrames = uncertaintyFrames
    }

    /// Validates the frame count and kind-specific uncertainty before creating a measurement.
    static func make(kind: LatencyKind, frames: Int64,
                     uncertaintyFrames: Int64?) throws(LatencyRefusal) -> Self {
        guard frames >= 0 else { throw .negativeFrames(frames) }
        if kind.isMeasured, uncertaintyFrames == nil { throw .uncertaintyRequired(kind) }
        if !kind.isMeasured, uncertaintyFrames != nil { throw .uncertaintyNotAllowed(kind) }
        if let uncertaintyFrames, uncertaintyFrames < 0 { throw .negativeUncertainty(uncertaintyFrames) }
        return Self(kind: kind, frames: frames, uncertaintyFrames: uncertaintyFrames)
    }

    /// Converts a fixture estimate into a one-way software impulse latency.
    static func softwareImpulseDelay(from estimate: ImpulseOffsetEstimate) throws(LatencyRefusal) -> Self {
        let frames = estimate.offsetFrames
        guard frames >= 0 else { throw .negativeFrames(frames) }
        return Self(kind: .softwareImpulseDelay, frames: frames, uncertaintyFrames: estimate.uncertaintyFrames)
    }
}

/// The selected nominal stream sizes and their exact callback-duration budgets.
struct StreamSetup: Hashable, Sendable {
    static let sampleRates = 1...768_000
    static let bufferFrames = 1...65_536

    let sampleRateHz: Int
    let inputBufferFrames: Int
    let outputBufferFrames: Int

    private init(sampleRateHz: Int, inputBufferFrames: Int, outputBufferFrames: Int) {
        self.sampleRateHz = sampleRateHz
        self.inputBufferFrames = inputBufferFrames
        self.outputBufferFrames = outputBufferFrames
    }

    /// Builds a bounded stream setup, checking sample rate, input size, then output size.
    static func make(sampleRateHz: Int, inputBufferFrames: Int,
                     outputBufferFrames: Int) throws(LatencyRefusal) -> Self {
        guard sampleRates.contains(sampleRateHz) else { throw .sampleRateOutOfRange(sampleRateHz) }
        guard bufferFrames.contains(inputBufferFrames) else { throw .inputBufferOutOfRange(inputBufferFrames) }
        guard bufferFrames.contains(outputBufferFrames) else { throw .outputBufferOutOfRange(outputBufferFrames) }
        return Self(sampleRateHz: sampleRateHz, inputBufferFrames: inputBufferFrames,
                    outputBufferFrames: outputBufferFrames)
    }

    /// Duration budget derived from the input callback size, not a latency measurement.
    var inputBudget: CallbackBudget { CallbackBudget(bufferFrames: inputBufferFrames, sampleRateHz: sampleRateHz) }

    /// Duration budget derived from the output callback size, not a latency measurement.
    var outputBudget: CallbackBudget { CallbackBudget(bufferFrames: outputBufferFrames, sampleRateHz: sampleRateHz) }
}

/// Exact floor and ceiling nanoseconds for one callback, with no conversion to latency evidence.
struct CallbackBudget: Hashable, Sendable {
    let bufferFrames: Int
    let sampleRateHz: Int

    fileprivate init(bufferFrames: Int, sampleRateHz: Int) {
        self.bufferFrames = bufferFrames
        self.sampleRateHz = sampleRateHz
    }

    /// Floor of `bufferFrames * 1e9 / sampleRateHz`.
    var floorNanoseconds: Int64 {
        numerator / Int64(sampleRateHz)
    }

    /// Ceiling of `bufferFrames * 1e9 / sampleRateHz`.
    var ceilingNanoseconds: Int64 {
        let divisor = Int64(sampleRateHz)
        let quotient = numerator / divisor
        return numerator % divisor == 0 ? quotient : quotient + 1
    }

    private var numerator: Int64 { Int64(bufferFrames) * 1_000_000_000 }
}
