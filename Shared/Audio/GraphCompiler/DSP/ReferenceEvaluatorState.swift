/// Evaluator state between blocks: the number of blocks already processed and the planar ring storage of every
/// delay line (`lines[i]` belongs to `schedule.delayLines[i]` and holds `channels * delayFrames` floats, channel `c`
/// in `c * delayFrames ..< (c + 1) * delayFrames`). `GraphReferenceEvaluator.initialState` (all `+0.0`) is the
/// blessed constructor; every evaluator entry point validates a state before use and refuses a mismatch with
/// `.stateMismatch` without touching it.
struct ReferenceEvaluatorState: Equatable, Sendable {
    let blocksProcessed: Int
    let lines: [[Float]]
}
