/// Why a parameter ramp was refused. Values carry numbers only.
enum BridgeRampRefusal: Error, Hashable, Sendable {
    /// The duration is outside `1...BridgeParameterRamp.maximumDurationFrames`.
    case invalidDuration(Int)
    /// The target is NaN or infinite.
    case nonFiniteTarget
}

/// A bounded parameter ramp: the parameter address, a finite target and a duration in frames.
///
/// A value exists only if `make` accepted it (storage is `let`, the initialiser is private), so a ramp that reached a
/// batch is always inside these bounds. The duration is in frames of the sample rate the ramp was planned at; a sample
/// rate change makes the ramp stale (`BridgeEventBatch` binds ramps to the `resources` and `sampleRate` generations),
/// it is never rescaled. The parameter address is opaque: any `UInt64` is legal here, the AU adapter owns its meaning.
struct BridgeParameterRamp: Equatable, Sendable {
    /// 2^31 - 1 frames, the largest duration an `Int32` frame count can express.
    static let maximumDurationFrames = 2_147_483_647

    let parameter: UInt64
    let target: Float
    let durationFrames: Int

    private init(parameter: UInt64, target: Float, durationFrames: Int) {
        self.parameter = parameter
        self.target = target
        self.durationFrames = durationFrames
    }

    /// Checks the duration first, then the target; the first failure wins.
    static func make(
        parameter: UInt64, target: Float, durationFrames: Int
    ) throws(BridgeRampRefusal) -> BridgeParameterRamp {
        guard (1...maximumDurationFrames).contains(durationFrames) else { throw .invalidDuration(durationFrames) }
        guard target.isFinite else { throw .nonFiniteTarget }
        return BridgeParameterRamp(parameter: parameter, target: target, durationFrames: durationFrames)
    }
}
