import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Route latency model (#68, slice LAT1): measurement kinds, the callback budget, configuration-bound calibration
/// records, the impulse-offset estimator and parallel path delay compensation. This root file holds the shared
/// builders plus the kind, measurement, stream setup and callback budget tests; the other files extend the suite.
@Suite("Route latency", .productionAccessAudit)
struct RouteLatencyTests {
    private struct CallbackBudgetCase {
        let frames: Int
        let rate: Int
        let floor: Int64
        let ceiling: Int64
    }

    // MARK: Builders

    /// One route of a `Setup`; the defaults are an input pair on the first device.
    struct RouteSpec: Hashable {
        var id = "route.in"
        var device = "dev.a"
        var direction = RouteDirection.input
        var channels = [0, 1]

        func route() throws -> AudioRoute {
            AudioRoute(id: try RouteID(id), role: try RoleID("role.main"), device: try DeviceID(device),
                       direction: direction, channels: channels, binding: .confirmed)
        }
    }

    /// Everything a calibration configuration binds, as plain values a test can edit one field at a time.
    struct Setup: Hashable {
        var device = "dev.a"
        var uid = "uid.interface-a"
        var evidence: Set<IdentityEvidence> = [.deviceUID]
        var rate = 48_000
        var input = 128
        var output = 256
        var routes = [RouteSpec(), RouteSpec(id: "route.out", direction: .output, channels: [2, 3])]
        var deviceGeneration = 1
        var calibrationGeneration = 1

        func configuration() throws -> CalibrationConfiguration {
            try CalibrationConfiguration.make(
                deviceID: try DeviceID(device),
                identity: RouteLatencyTests.identity(uid: uid, evidence: evidence),
                routes: routes.map { try $0.route() },
                stream: StreamSetup.make(sampleRateHz: rate, inputBufferFrames: input, outputBufferFrames: output),
                generations: RouteLatencyTests.generations(device: deviceGeneration, calibration: calibrationGeneration)
            )
        }
    }

    static func identity(uid: String = "uid.interface-a",
                         evidence: Set<IdentityEvidence> = [.deviceUID]) throws -> DeviceIdentity {
        try DeviceIdentity(DeviceIdentityFields(uid: uid, evidence: evidence))
    }

    static func generations(device: Int = 1, calibration: Int = 1) throws -> CalibrationGenerations {
        CalibrationGenerations(device: DeviceGeneration(try Generation(device)),
                               calibration: CalibrationGeneration(try Generation(calibration)))
    }

    /// A valid measurement; measured kinds get `uncertainty` (default 0), `.reported` gets none.
    static func measurement(_ kind: LatencyKind = .analogRoundTrip, frames: Int64,
                            uncertainty: Int64 = 0) throws -> LatencyMeasurement {
        try LatencyMeasurement.make(kind: kind, frames: frames, uncertaintyFrames: kind.isMeasured ? uncertainty : nil)
    }

    static func record(_ configuration: CalibrationConfiguration, _ kind: LatencyKind = .analogRoundTrip,
                       frames: Int64, uncertainty: Int64 = 0,
                       producer: String = "producer.loopback-1") throws -> CalibrationRecord {
        try CalibrationRecord.make(measurement: measurement(kind, frames: frames, uncertainty: uncertainty),
                                   producer: producer, configuration: configuration)
    }

    /// A path whose record was measured under `setup` and whose current configuration is `current` (default `setup`).
    /// `frames == nil` makes the latency `.unknown`.
    static func path(_ id: String, frames: Int64?, _ kind: LatencyKind = .analogRoundTrip, uncertainty: Int64 = 0,
                     setup: Setup = Setup(), current: Setup? = nil) throws -> CompensationPath {
        let measured = try setup.configuration()
        let latency = try frames.map {
            PathLatency.recorded(
                try record(measured, kind, frames: $0, uncertainty: uncertainty)
            )
        }
        return CompensationPath(id: try LatencyPathID(id), current: try (current ?? setup).configuration(),
                                latency: latency ?? .unknown)
    }

    /// Fails the calling test unless `paths` align, and returns the plan.
    static func aligned(_ paths: [CompensationPath],
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> CompensationPlan {
        let outcome = PathDelayCompensation.align(paths)
        let plan: CompensationPlan? = if case .aligned(let value) = outcome { value } else { nil }
        return try #require(plan, "expected an aligned plan, got \(outcome)", sourceLocation: sourceLocation)
    }

    /// The reason `paths` cannot be aligned, or nil when they align.
    static func unalignable(_ paths: [CompensationPath]) -> UnalignableReason? {
        if case .unalignable(let reason) = PathDelayCompensation.align(paths) { reason } else { nil }
    }

    static func ids(_ names: String...) throws -> [LatencyPathID] {
        try names.map { try LatencyPathID($0) }
    }

    // MARK: Kinds

    @Test func kindsAreFourDistinctCasesWithStableRawValues() {
        #expect(LatencyKind.allCases == [.analogRoundTrip, .digitalCalibration, .softwareImpulseDelay, .reported])
        #expect(LatencyKind.allCases.map(\.rawValue)
            == ["analogRoundTrip", "digitalCalibration", "softwareImpulseDelay", "reported"])
        #expect(Set(LatencyKind.allCases).count == 4)
    }

    @Test func onlyReportedIsNotMeasured() {
        #expect(LatencyKind.allCases.filter { !$0.isMeasured } == [.reported])
        #expect(LatencyKind.allCases.filter(\.isMeasured).count == 3)
    }

    @Test func equalNumbersUnderDifferentKindsAreDifferentMeasurements() throws {
        let measured = try LatencyKind.allCases.filter(\.isMeasured).map {
            try LatencyMeasurement.make(kind: $0, frames: 480, uncertaintyFrames: 2)
        }
        #expect(Set(measured).count == 3)
        #expect(measured.map(\.kind) == [.analogRoundTrip, .digitalCalibration, .softwareImpulseDelay])
        #expect(measured.allSatisfy { $0.frames == 480 && $0.uncertaintyFrames == 2 })
        let reported = try LatencyMeasurement.make(kind: .reported, frames: 480, uncertaintyFrames: nil)
        #expect(reported.kind == .reported)
        #expect(reported.uncertaintyFrames == nil)
        #expect(!measured.contains(reported))
    }

    // MARK: Measurement

    @Test func framesAcceptZeroAndTheLargestValueAndRefuseNegatives() throws {
        for frames: Int64 in [0, 1, Int64.max] {
            let value = try LatencyMeasurement.make(kind: .digitalCalibration, frames: frames, uncertaintyFrames: 0)
            #expect(value.frames == frames)
        }
        #expect(throws: LatencyRefusal.negativeFrames(-1)) {
            try LatencyMeasurement.make(kind: .digitalCalibration, frames: -1, uncertaintyFrames: 0)
        }
        #expect(throws: LatencyRefusal.negativeFrames(Int64.min)) {
            try LatencyMeasurement.make(kind: .reported, frames: Int64.min, uncertaintyFrames: nil)
        }
    }

    @Test func measuredKindsRequireAnUncertainty() throws {
        for kind in LatencyKind.allCases.filter(\.isMeasured) {
            #expect(throws: LatencyRefusal.uncertaintyRequired(kind)) {
                try LatencyMeasurement.make(kind: kind, frames: 10, uncertaintyFrames: nil)
            }
            let value = try LatencyMeasurement.make(kind: kind, frames: 10, uncertaintyFrames: 0)
            #expect(value.uncertaintyFrames == 0)
        }
    }

    @Test func reportedLatencyCarriesNoUncertainty() throws {
        #expect(throws: LatencyRefusal.uncertaintyNotAllowed(.reported)) {
            try LatencyMeasurement.make(kind: .reported, frames: 10, uncertaintyFrames: 0)
        }
        #expect(throws: LatencyRefusal.uncertaintyNotAllowed(.reported)) {
            try LatencyMeasurement.make(kind: .reported, frames: 10, uncertaintyFrames: -1)
        }
        let value = try LatencyMeasurement.make(kind: .reported, frames: 10, uncertaintyFrames: nil)
        #expect(value.frames == 10)
    }

    @Test func uncertaintyAcceptsZeroAndTheLargestValueAndRefusesNegatives() throws {
        for uncertainty: Int64 in [0, 1, Int64.max] {
            let value = try LatencyMeasurement.make(kind: .analogRoundTrip, frames: 0, uncertaintyFrames: uncertainty)
            #expect(value.uncertaintyFrames == uncertainty)
        }
        #expect(throws: LatencyRefusal.negativeUncertainty(-1)) {
            try LatencyMeasurement.make(kind: .analogRoundTrip, frames: 0, uncertaintyFrames: -1)
        }
        #expect(throws: LatencyRefusal.negativeUncertainty(Int64.min)) {
            try LatencyMeasurement.make(kind: .softwareImpulseDelay, frames: 0, uncertaintyFrames: Int64.min)
        }
    }

    @Test func measurementRefusalsAreCheckedFramesFirstThenPresenceThenSign() {
        #expect(throws: LatencyRefusal.negativeFrames(-5)) {
            try LatencyMeasurement.make(kind: .analogRoundTrip, frames: -5, uncertaintyFrames: -5)
        }
        #expect(throws: LatencyRefusal.negativeFrames(-5)) {
            try LatencyMeasurement.make(kind: .reported, frames: -5, uncertaintyFrames: 3)
        }
        #expect(throws: LatencyRefusal.uncertaintyRequired(.digitalCalibration)) {
            try LatencyMeasurement.make(kind: .digitalCalibration, frames: 5, uncertaintyFrames: nil)
        }
    }

    // MARK: Stream setup

    @Test func sampleRateAcceptsOneAndTheDeviceMaximumAndRefusesOutside() throws {
        for rate in [1, 44_100, 48_000, 768_000] {
            #expect(try StreamSetup.make(sampleRateHz: rate, inputBufferFrames: 1, outputBufferFrames: 1)
                .sampleRateHz == rate)
        }
        for rate in [0, -48_000, 768_001] {
            #expect(throws: LatencyRefusal.sampleRateOutOfRange(rate)) {
                try StreamSetup.make(sampleRateHz: rate, inputBufferFrames: 1, outputBufferFrames: 1)
            }
        }
    }

    @Test func sampleRateBoundMatchesTheDeviceCapabilityBound() throws {
        #expect(StreamSetup.sampleRates == 1...768_000)
        _ = try ChannelLayout(inputs: 0, outputs: 0, sampleRate: 1)
        _ = try ChannelLayout(inputs: 0, outputs: 0, sampleRate: 768_000)
        #expect(throws: ChannelLayoutError.invalidSampleRate(0)) {
            try ChannelLayout(inputs: 0, outputs: 0, sampleRate: 0)
        }
        #expect(throws: ChannelLayoutError.invalidSampleRate(768_001)) {
            try ChannelLayout(inputs: 0, outputs: 0, sampleRate: 768_001)
        }
    }

    @Test func bufferFramesAcceptOneAndTheMaximumOnEachSideAndRefuseOutside() throws {
        #expect(StreamSetup.bufferFrames == 1...65_536)
        let edges = try StreamSetup.make(sampleRateHz: 48_000, inputBufferFrames: 1, outputBufferFrames: 65_536)
        #expect(edges.inputBufferFrames == 1)
        #expect(edges.outputBufferFrames == 65_536)
        for frames in [0, -1, 65_537] {
            #expect(throws: LatencyRefusal.inputBufferOutOfRange(frames)) {
                try StreamSetup.make(sampleRateHz: 48_000, inputBufferFrames: frames, outputBufferFrames: 64)
            }
            #expect(throws: LatencyRefusal.outputBufferOutOfRange(frames)) {
                try StreamSetup.make(sampleRateHz: 48_000, inputBufferFrames: 64, outputBufferFrames: frames)
            }
        }
    }

    @Test func streamSetupChecksRateThenInputThenOutput() {
        #expect(throws: LatencyRefusal.sampleRateOutOfRange(0)) {
            try StreamSetup.make(sampleRateHz: 0, inputBufferFrames: 0, outputBufferFrames: 0)
        }
        #expect(throws: LatencyRefusal.inputBufferOutOfRange(0)) {
            try StreamSetup.make(sampleRateHz: 48_000, inputBufferFrames: 0, outputBufferFrames: 0)
        }
    }

    // MARK: Callback budget (N/Fs)

    @Test func callbackBudgetIsAnExactDurationRoundedBothWays() throws {
        let cases = [
            CallbackBudgetCase(frames: 128, rate: 48_000, floor: 2_666_666, ceiling: 2_666_667),
            CallbackBudgetCase(frames: 96, rate: 48_000, floor: 2_000_000, ceiling: 2_000_000),
            CallbackBudgetCase(frames: 1, rate: 768_000, floor: 1_302, ceiling: 1_303),
            CallbackBudgetCase(frames: 1, rate: 44_100, floor: 22_675, ceiling: 22_676),
            CallbackBudgetCase(frames: 65_536, rate: 1,
                               floor: 65_536_000_000_000, ceiling: 65_536_000_000_000)
        ]
        for row in cases {
            let budget = try StreamSetup.make(sampleRateHz: row.rate, inputBufferFrames: row.frames,
                                              outputBufferFrames: 1).inputBudget
            #expect(budget.bufferFrames == row.frames)
            #expect(budget.sampleRateHz == row.rate)
            #expect(budget.floorNanoseconds == row.floor)
            #expect(budget.ceilingNanoseconds == row.ceiling)
        }
    }

    @Test func inputAndOutputBudgetsFollowTheirOwnBufferSize() throws {
        let stream = try StreamSetup.make(sampleRateHz: 48_000, inputBufferFrames: 96, outputBufferFrames: 480)
        #expect(stream.inputBudget.bufferFrames == 96)
        #expect(stream.outputBudget.bufferFrames == 480)
        #expect(stream.inputBudget.floorNanoseconds == 2_000_000)
        #expect(stream.outputBudget.floorNanoseconds == 10_000_000)
        #expect(stream.inputBudget != stream.outputBudget)
    }

    @Test func aMeasuredLatencyBelowTheBufferIsKeptExactly() throws {
        var setup = Setup()
        setup.input = 256
        setup.output = 65_536
        let configuration = try setup.configuration()
        for frames: Int64 in [0, 100, 255] {
            let record = try Self.record(configuration, frames: frames)
            #expect(record.measurement.frames == frames)
            let plan = try Self.aligned([Self.path("path.loop", frames: frames, setup: setup)])
            #expect(plan.targetFrames == frames)
            #expect(plan.entries.map(\.latencyFrames) == [frames])
            #expect(plan.entries.map(\.addedFrames) == [0])
        }
    }

    @Test func bufferSizesNeverEnterTheCompensationArithmetic() throws {
        var small = Setup()
        small.input = 1
        small.output = 1
        var large = Setup()
        large.input = 65_536
        large.output = 65_536
        let plan = try Self.aligned([Self.path("path.a", frames: 700, setup: small),
                                     Self.path("path.b", frames: 700, setup: large)])
        #expect(plan.targetFrames == 700)
        #expect(plan.entries.map(\.addedFrames) == [0, 0])
    }
}
