//
//  RunRecord.swift
//  FluxKlang
//
//  One validated measured run: its controlled variables and integer measurements.
//

/// Structural validity bounds. They are not performance claims and say nothing about a usable buffer size.
enum RunLimits {
    static let bufferFrames = 1...65_536
    static let sampleRates = 1...768_000
    static let maximumSamples = 100_000
    static let maximumRecoveries = 1_024
    static let maximumRuns = 256
}

enum RunLoadProfileTag: ContractIDTag {}
enum RunBackendTag: ContractIDTag {}
enum RunWorkloadTag: ContractIDTag {}
enum RunExperimentTag: ContractIDTag {}

/// Opaque identifiers; nothing in the model interprets or names a backend, language or platform.
typealias RunLoadProfileID = ContractID<RunLoadProfileTag>
typealias RunBackendID = ContractID<RunBackendTag>
typealias RunWorkloadID = ContractID<RunWorkloadTag>
typealias RunExperimentID = ContractID<RunExperimentTag>

/// The controlled variables that two runs must share before they are pooled or compared.
struct RunVariables: Hashable, Sendable {
    let bufferFrames: Int
    let sampleRateHz: Int
    let loadProfile: RunLoadProfileID
    let backend: RunBackendID
    let workload: RunWorkloadID

    private init(bufferFrames: Int, sampleRateHz: Int, loadProfile: RunLoadProfileID,
                 backend: RunBackendID, workload: RunWorkloadID) {
        self.bufferFrames = bufferFrames
        self.sampleRateHz = sampleRateHz
        self.loadProfile = loadProfile
        self.backend = backend
        self.workload = workload
    }

    /// Validates in the order buffer frames, sample rate, load profile, backend, workload.
    static func make(bufferFrames: Int, sampleRateHz: Int, loadProfile: String, backend: String,
                     workload: String) throws(RunRefusal) -> Self {
        guard RunLimits.bufferFrames.contains(bufferFrames) else { throw .bufferFramesOutOfRange(bufferFrames) }
        guard RunLimits.sampleRates.contains(sampleRateHz) else { throw .sampleRateOutOfRange(sampleRateHz) }
        return Self(bufferFrames: bufferFrames, sampleRateHz: sampleRateHz,
                    loadProfile: try runID(loadProfile, .loadProfile),
                    backend: try runID(backend, .backend),
                    workload: try runID(workload, .workload))
    }

    /// The variables that differ from `other`, in `RunVariable` declaration order.
    func differing(from other: RunVariables) -> [RunVariable] {
        RunVariable.allCases.filter { variable in
            switch variable {
            case .bufferFrames: bufferFrames != other.bufferFrames
            case .sampleRate: sampleRateHz != other.sampleRateHz
            case .loadProfile: loadProfile != other.loadProfile
            case .backend: backend != other.backend
            case .workload: workload != other.workload
            }
        }
    }
}

/// Validates an opaque identifier; the refusal reports the UTF-8 byte count, never the rejected text.
private func runID<Tag: ContractIDTag>(_ raw: String, _ field: RunIDField) throws(RunRefusal) -> ContractID<Tag> {
    do {
        return try ContractID<Tag>(raw)
    } catch {
        throw .invalidID(field, bytes: raw.utf8.count)
    }
}

/// Unvalidated measurement input for `RunRecord.make`.
struct RunMeasurements: Hashable, Sendable {
    /// Per-callback render durations in nanoseconds, in capture order.
    var renderNanoseconds: [Int64]
    /// The callback deadline in nanoseconds.
    var deadlineNanoseconds: Int64
    var dropouts: Int
    /// Recovery durations in nanoseconds, one per recovered dropout episode.
    var recoveryNanoseconds: [Int64]
}

/// One measured run. It is deliberately neither `Comparable` nor scored: runs have no quality ordering.
struct RunRecord: Hashable, Sendable {
    let variables: RunVariables
    let experiment: RunExperimentID?
    let renderNanoseconds: [Int64]
    let deadlineNanoseconds: Int64
    let dropouts: Int
    let recoveryNanoseconds: [Int64]

    private init(variables: RunVariables, experiment: RunExperimentID?, measurements: RunMeasurements) {
        self.variables = variables
        self.experiment = experiment
        renderNanoseconds = measurements.renderNanoseconds
        deadlineNanoseconds = measurements.deadlineNanoseconds
        dropouts = measurements.dropouts
        recoveryNanoseconds = measurements.recoveryNanoseconds
    }

    /// Validates in the order experiment id, sample count, first non-positive render duration, deadline, dropouts,
    /// recovery count, first non-positive recovery. Durations must be at least one nanosecond.
    static func make(variables: RunVariables, experiment: String?,
                     measurements: RunMeasurements) throws(RunRefusal) -> Self {
        let reference: RunExperimentID? = try experiment.map { raw throws(RunRefusal) in try runID(raw, .experiment) }
        let renders = measurements.renderNanoseconds
        guard !renders.isEmpty else { throw .noSamples }
        guard renders.count <= RunLimits.maximumSamples else { throw .tooManySamples(count: renders.count) }
        if let index = renders.firstIndex(where: { $0 < 1 }) {
            throw .nonPositiveRenderDuration(index: index, nanoseconds: renders[index])
        }
        guard measurements.deadlineNanoseconds >= 1 else {
            throw .nonPositiveDeadline(measurements.deadlineNanoseconds)
        }
        guard measurements.dropouts >= 0 else { throw .negativeDropouts(measurements.dropouts) }
        let recoveries = measurements.recoveryNanoseconds
        guard recoveries.count <= RunLimits.maximumRecoveries else {
            throw .tooManyRecoveries(count: recoveries.count)
        }
        if let index = recoveries.firstIndex(where: { $0 < 1 }) {
            throw .nonPositiveRecovery(index: index, nanoseconds: recoveries[index])
        }
        return Self(variables: variables, experiment: reference, measurements: measurements)
    }
}
