//
//  MediaIOScript.swift
//  FluxKlang
//
//  The closed script format of the scripted fakes (#109 IO2). A script is a
//  list of steps; each worker call consumes exactly one. Steps carry counts
//  only, never text. A script is validated once, when it is built.
//

/// One scripted reader call. A short read is simply `ready(frames:)` below the request; a slow read is `pending`.
enum MediaReadStep: Equatable, Sendable {
    case pending
    /// `.ready(MediaReadResult(frames:, reachedEnd: false))`.
    case ready(frames: Int)
    /// `.ready(MediaReadResult(frames:, reachedEnd: true))`.
    case readyAtEnd(frames: Int)
    case fail(MediaReadFault)
}

/// One scripted writer call.
enum MediaWriteStep: Equatable, Sendable {
    case pending
    case accept(frames: Int)
    case fail(MediaWriteFault)
}

/// The one scripted `finish` call.
enum MediaWriteFinishStep: Equatable, Sendable {
    /// `durableFrames == acceptedFrames`.
    case durable
    /// `durableFrames == acceptedFrames - frames`: a partial file.
    case durableShortBy(frames: Int64)
    case fail(MediaWriteFault)
}

/// Why a script is refused. Payloads are counts and indices only.
enum MediaIOScriptRefusal: Error, Equatable, Sendable {
    case tooManySteps(count: Int, maximum: Int)
    case negativeFrames(stepIndex: Int, frames: Int)
    case framesTooLarge(stepIndex: Int, frames: Int, maximum: Int)
    case negativeShortBy(Int64)
}

/// Checks the step counts in index order; `frames(of:)` yields a step's frame count, if it has one.
private func validateSteps<Step>(_ steps: [Step], frames: (Step) -> Int?) throws(MediaIOScriptRefusal) {
    guard steps.count <= MediaIOLimits.maximumScriptSteps else {
        throw .tooManySteps(count: steps.count, maximum: MediaIOLimits.maximumScriptSteps)
    }
    for (index, step) in steps.enumerated() {
        guard let count = frames(step) else { continue }
        guard count >= 0 else { throw .negativeFrames(stepIndex: index, frames: count) }
        guard count <= MediaIOLimits.maximumRequestFrames else {
            throw .framesTooLarge(stepIndex: index, frames: count, maximum: MediaIOLimits.maximumRequestFrames)
        }
    }
}

/// A validated list of at most `maximumScriptSteps` reader steps. The empty script is valid.
struct MediaReadScript: Equatable, Sendable {
    let steps: [MediaReadStep]

    /// Order, first failure wins: step count, then steps in index order (negative frames, then above 65_536).
    init(steps: [MediaReadStep]) throws(MediaIOScriptRefusal) {
        try validateSteps(steps) { step in
            switch step {
            case .ready(let frames), .readyAtEnd(let frames): frames
            case .pending, .fail: nil
            }
        }
        self.steps = steps
    }
}

/// A validated list of at most `maximumScriptSteps` writer steps and the one `finish` step.
struct MediaWriteScript: Equatable, Sendable {
    let steps: [MediaWriteStep]
    let finish: MediaWriteFinishStep

    /// Order, first failure wins: step count, steps in index order, then a negative `durableShortBy`.
    init(steps: [MediaWriteStep], finish: MediaWriteFinishStep) throws(MediaIOScriptRefusal) {
        try validateSteps(steps) { step in
            switch step {
            case .accept(let frames): frames
            case .pending, .fail: nil
            }
        }
        if case .durableShortBy(let shortBy) = finish, shortBy < 0 {
            throw .negativeShortBy(shortBy)
        }
        self.steps = steps
        self.finish = finish
    }
}
