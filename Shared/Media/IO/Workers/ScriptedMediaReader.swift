//
//  ScriptedMediaReader.swift
//  FluxKlang
//
//  A scripted reader worker (#109 IO2). It plays a `MediaReadScript` back one
//  step per call: slow, failing, short, interrupted and end-of-source reads
//  without a file, thread, clock or sleep. It is the only reader this slice
//  ships; real adapters are a later lane.
//

/// A reader fake driven by a closed script.
///
/// Each `read` consumes exactly ONE step in order and returns or throws what it says, with NO clamping and NO
/// validation of the scripted frames against the request (the fill pump refuses a lying reader). A call with no
/// step left throws `.unavailable` and adds one to `scriptViolations`. A throwing call changes only `callCount`,
/// `requests` and, for exhaustion, `scriptViolations`; a scripted `fail` still consumes its step.
struct ScriptedMediaReader: MediaReaderWorker, Equatable {
    /// Every `read` call so far, saturating at `UInt64.max`.
    private(set) var callCount: UInt64
    /// Calls the script could not answer, saturating at `UInt64.max`.
    private(set) var scriptViolations: UInt64
    /// The first `MediaIOLimits.maximumRecordedRequests` requests in call order; later calls are only counted.
    private(set) var requests: [MediaReadRequest]

    private let steps: [MediaReadStep]
    private var cursor: Int

    /// Steps not yet consumed.
    var remainingSteps: Int { steps.count - cursor }

    init(script: MediaReadScript) {
        steps = script.steps
        cursor = 0
        callCount = 0
        scriptViolations = 0
        requests = []
    }

    mutating func read(_ request: MediaReadRequest) throws(MediaReadFault) -> MediaReadPoll {
        callCount = PrefetchFillCounters.saturatingSum(callCount, 1)
        if requests.count < MediaIOLimits.maximumRecordedRequests {
            requests.append(request)
        }
        guard cursor < steps.count else {
            scriptViolations = PrefetchFillCounters.saturatingSum(scriptViolations, 1)
            throw .unavailable
        }
        let step = steps[cursor]
        cursor += 1
        switch step {
        case .pending: return .pending
        case .ready(let frames): return .ready(MediaReadResult(frames: frames, reachedEnd: false))
        case .readyAtEnd(let frames): return .ready(MediaReadResult(frames: frames, reachedEnd: true))
        case .fail(let fault): throw fault
        }
    }
}
