//
//  RunRefusal.swift
//  FluxKlang
//
//  Typed refusals and field names for the harness-neutral run statistics model.
//

/// A controlled variable of a measured run. Declaration order is the documented reporting order.
enum RunVariable: Int, CaseIterable, Hashable, Sendable {
    case bufferFrames
    case sampleRate
    case loadProfile
    case backend
    case workload

    /// A stable human-readable name for reports; backend and workload values themselves stay opaque.
    var name: String {
        switch self {
        case .bufferFrames: "bufferFrames"
        case .sampleRate: "sampleRate"
        case .loadProfile: "loadProfile"
        case .backend: "backend"
        case .workload: "workload"
        }
    }
}

/// Which opaque identifier of a run failed validation.
enum RunIDField: Hashable, Sendable {
    case loadProfile
    case backend
    case workload
    case experiment
}

/// Which caller-supplied stability criterion is invalid.
enum RunCriterion: Hashable, Sendable {
    case maximumDropouts
    case maximumDeadlineMisses
    case minimumSamples
}

/// Why a run, a set of runs, stability criteria or a comparison is refused. A refusal changes nothing.
enum RunRefusal: Error, Hashable, Sendable {
    case bufferFramesOutOfRange(Int)
    case sampleRateOutOfRange(Int)
    case invalidID(RunIDField, bytes: Int)
    case noSamples
    case tooManySamples(count: Int)
    case nonPositiveRenderDuration(index: Int, nanoseconds: Int64)
    case nonPositiveDeadline(Int64)
    case negativeDropouts(Int)
    case tooManyRecoveries(count: Int)
    case nonPositiveRecovery(index: Int, nanoseconds: Int64)
    case invalidCriteria(RunCriterion, value: Int)
    case noRuns
    case tooManyRuns(count: Int)
    /// The runs differ in these controlled variables, in `RunVariable` declaration order.
    case variablesDiffer([RunVariable])
    /// Compared or pooled runs measured against different deadlines (nanoseconds). A comparison reports the first
    /// run's deadline then the second's; the finding reports the smallest then the largest deadline at one size.
    case deadlineMismatch(Int64, Int64)
    case arithmeticOverflow
}
