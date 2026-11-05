//
//  SpatialCalibrationPlan.swift
//  FluxKlang
//
//  The reviewed calibration plan and its authorization (#116 PL1): which
//  outputs get a test signal, at what maximum level and for how long. The
//  plan is data only; nothing here produces a tone or reads a clock.
//

enum SpatialCalibrationPlanTag: ContractIDTag {}
typealias SpatialCalibrationPlanID = ContractID<SpatialCalibrationPlanTag>

/// Names one calibration flow. The caller supplies it, and every review and
/// authorization carries it, so an authorization from another flow is refused
/// even when its plan and review generation match.
///
/// Each flow instance needs its own ID, including a flow rebuilt after
/// relaunch. A flow value must not be snapshotted and restored while it awaits
/// authorization: the restored copy would accept the same authorization
/// again. Single-use consumption of authorizations comes with the #62
/// hazardous-action tokens.
enum SpatialCalibrationFlowTag: ContractIDTag {}
typealias SpatialCalibrationFlowID = ContractID<SpatialCalibrationFlowTag>

/// Why calibration cannot be planned (the Calibrate button's disabled reason).
enum SpatialCalibrationUnavailableReason: Hashable, Sendable {
    case deviceMissing
    case routeUnconfirmed
}

/// Why a run stopped before completing.
enum SpatialCalibrationStop: Hashable, Sendable {
    case panic
    case safeMute
    case deviceLost(SpatialCalibrationUnavailableReason)
}

/// The only label calibration results carry: relative values with no SPL or
/// "room corrected" claim, since nothing here measures against a reference.
enum SpatialCalibrationLabel: Hashable, Sendable {
    case relativeUncalibrated

    var text: String { "relative, uncalibrated" }
}

/// A deterministic 64-bit FNV-1a digest of a plan's reviewed fields, for
/// display and logs. It is not cryptographic and does not resist an
/// adversary; the flow compares the whole reviewed plan instead.
struct SpatialCalibrationDigest: Hashable, Sendable {
    let value: UInt64

    fileprivate init(id: SpatialCalibrationPlanID, outputs: [SpeakerID], routes: [RouteID], level: Double,
                     seconds: Double) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        // Contract IDs never contain a NUL byte and there is one route per
        // output, so the NUL-terminated fields split one way only.
        mix("fluxklang.spatial-calibration-plan.v1".utf8)
        mix([0])
        mix(id.rawValue.utf8)
        mix([0])
        for output in outputs {
            mix(output.rawValue.utf8)
            mix([0])
        }
        for route in routes {
            mix(route.rawValue.utf8)
            mix([0])
        }
        for bits in [level.bitPattern, seconds.bitPattern] {
            mix((0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
        }
        value = hash
    }
}

/// What the authorization sheet reviews: the outputs (in test order), the
/// route each one plays through, the maximum test level and the duration per
/// output. Built only by the throwing initializer, which validates every field
/// against the layout and the routes present on this host and computes the
/// digest, so re-routing a speaker makes a different plan.
struct SpatialCalibrationPlan: Hashable, Sendable {
    static let maximumOutputs = SpatialLayout.maximumSpeakers
    /// Test-signal ceiling in dBFS. Policy: never above −6 dBFS.
    static let levelRange: ClosedRange<Double> = -60 ... -6
    /// Seconds of test signal per output.
    static let durationRange: ClosedRange<Double> = 0.25...10

    let id: SpatialCalibrationPlanID
    let outputs: [SpeakerID]
    /// The route of each output, in plan order, resolved when the plan was built.
    let routes: [RouteID]
    let maximumLevelDecibels: Double
    let secondsPerOutput: Double
    let digest: SpatialCalibrationDigest

    /// Refuses, in order: no outputs, more than `maximumOutputs`, then per
    /// output a duplicate, a speaker not in `layout`, or one whose route is
    /// missing or not in `availableRoutes`; then the level, then the duration.
    init(
        id: SpatialCalibrationPlanID,
        outputs: [SpeakerID],
        maximumLevelDecibels: Double,
        secondsPerOutput: Double,
        layout: SpatialLayout,
        availableRoutes: Set<RouteID>
    ) throws(SpatialCalibrationRefusal) {
        guard !outputs.isEmpty else { throw .noOutputs }
        guard outputs.count <= Self.maximumOutputs else { throw .tooManyOutputs(outputs.count) }
        var seen = Set<SpeakerID>()
        var routes: [RouteID] = []
        for output in outputs {
            guard seen.insert(output).inserted else { throw .duplicateOutput(output) }
            guard layout.speaker(output) != nil else { throw .unknownOutput(output) }
            guard let route = layout.route(for: output, available: availableRoutes) else {
                throw .unroutedOutput(output)
            }
            routes.append(route)
        }
        guard maximumLevelDecibels.isFinite, Self.levelRange.contains(maximumLevelDecibels) else {
            throw .invalidMaximumLevel
        }
        guard secondsPerOutput.isFinite, Self.durationRange.contains(secondsPerOutput) else {
            throw .invalidDuration
        }
        self.id = id
        self.outputs = outputs
        self.routes = routes
        self.maximumLevelDecibels = maximumLevelDecibels
        self.secondsPerOutput = secondsPerOutput
        digest = SpatialCalibrationDigest(id: id, outputs: outputs, routes: routes, level: maximumLevelDecibels,
                                          seconds: secondsPerOutput)
    }

    /// The whole run: `secondsPerOutput × outputs.count`.
    var totalSeconds: Double { secondsPerOutput * Double(outputs.count) }
}

/// Consent to run one reviewed plan. It can only be made from a review (the
/// sheet confirms exactly what it showed), and it binds that review's flow,
/// whole plan and generation; the flow refuses it for any other review.
struct SpatialCalibrationAuthorization: Hashable, Sendable {
    let flowID: SpatialCalibrationFlowID
    /// The reviewed plan, compared field by field, so the binding never rests
    /// on the 64-bit digest alone.
    let plan: SpatialCalibrationPlan
    let generation: UInt64

    var planID: SpatialCalibrationPlanID { plan.id }
    var digest: SpatialCalibrationDigest { plan.digest }

    init(authorizing review: SpatialCalibrationReview) {
        flowID = review.flowID
        plan = review.plan
        generation = review.generation
    }
}
