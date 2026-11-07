//
//  ScriptedMediaWriter.swift
//  FluxKlang
//
//  A scripted writer worker (#109 IO2). It plays a `MediaWriteScript` back
//  one step per call: slow, short, interrupted and disk-full writes and a
//  durable or partial `finish`, without a file, thread, clock or sleep.
//

/// A writer fake driven by a closed script.
///
/// Each `write` consumes exactly ONE step in order; `finish` consumes the script's finish step once. No clamping
/// and no validation of the scripted frames against the request: an `accept(frames: a)` with `a` above the request
/// is returned as-is, but `acceptedFrames` counts only what was scripted. A call with no step left, or a second
/// `finish`, throws `.unavailable` and adds one to `scriptViolations`. A `durableShortBy(n)` with `n` above
/// `acceptedFrames`, or an accept that would overflow `Int64`, throws `.ioFailure` and adds one violation.
/// A throwing call changes only `callCount`, `requests`, `scriptViolations` and the consumed step.
/// `finish` is counted neither in `callCount` nor in `requests`; `finish` before any write is legal.
struct ScriptedMediaWriter: MediaWriterWorker, Equatable {
    /// Every `write` call so far, saturating at `UInt64.max`.
    private(set) var callCount: UInt64
    /// Calls the script could not answer or could not honour, saturating at `UInt64.max`.
    private(set) var scriptViolations: UInt64
    /// The first `MediaIOLimits.maximumRecordedRequests` requests in call order; later calls are only counted.
    private(set) var requests: [MediaWriteRequest]
    /// The sum of the scripted `accept` frames, overflow-checked.
    private(set) var acceptedFrames: Int64
    /// True once `finish` has returned a result.
    private(set) var isFinished: Bool

    private let steps: [MediaWriteStep]
    private let finishStep: MediaWriteFinishStep
    private var cursor: Int
    private var finishConsumed: Bool

    /// Steps not yet consumed.
    var remainingSteps: Int { steps.count - cursor }

    init(script: MediaWriteScript) {
        steps = script.steps
        finishStep = script.finish
        cursor = 0
        callCount = 0
        scriptViolations = 0
        requests = []
        acceptedFrames = 0
        isFinished = false
        finishConsumed = false
    }

    mutating func write(_ request: MediaWriteRequest) throws(MediaWriteFault) -> MediaWritePoll {
        callCount = PrefetchFillCounters.saturatingSum(callCount, 1)
        if requests.count < MediaIOLimits.maximumRecordedRequests {
            requests.append(request)
        }
        guard cursor < steps.count else { throw violation(.unavailable) }
        let step = steps[cursor]
        cursor += 1
        switch step {
        case .pending:
            return .pending
        case .accept(let frames):
            let (sum, overflow) = acceptedFrames.addingReportingOverflow(Int64(frames))
            guard !overflow else { throw violation(.ioFailure) }
            acceptedFrames = sum
            return .accepted(frames: frames)
        case .fail(let fault):
            throw fault
        }
    }

    mutating func finish() throws(MediaWriteFault) -> MediaWriteFinish {
        guard !finishConsumed else { throw violation(.unavailable) }
        finishConsumed = true
        switch finishStep {
        case .durable:
            return try sealed(durable: acceptedFrames)
        case .durableShortBy(let shortBy):
            guard shortBy <= acceptedFrames else { throw violation(.ioFailure) }
            return try sealed(durable: acceptedFrames - shortBy)
        case .fail(let fault):
            throw fault
        }
    }

    private mutating func sealed(durable: Int64) throws(MediaWriteFault) -> MediaWriteFinish {
        // Unreachable: the script and the sum are validated, so `durable` lies in `0...acceptedFrames`.
        guard let result = try? MediaWriteFinish.make(acceptedFrames: acceptedFrames, durableFrames: durable) else {
            throw violation(.ioFailure)
        }
        isFinished = true
        return result
    }

    private mutating func violation(_ fault: MediaWriteFault) -> MediaWriteFault {
        scriptViolations = PrefetchFillCounters.saturatingSum(scriptViolations, 1)
        return fault
    }
}
