/// Evaluator-local budgets in floats, blocks and sample operations (never elapsed time). They sit beside, and never
/// replace, the `AudioRoutingLimits` already enforced when the schedule was made. The standard values are
/// conservative defaults, not owner-approved numbers. Every field lies in `1...ceiling`; values are validated and
/// immutable, so a limits value cannot be forged.
struct ReferenceEvaluatorLimits: Equatable, Sendable {
    static let scratchFloatsCeiling = 67_108_864
    static let stateFloatsCeiling = 67_108_864
    static let blocksPerRunCeiling = 65_536
    static let runWorkCeiling = 1_099_511_627_776
    static let runOutputFloatsCeiling = 67_108_864

    /// Built through a private non-throwing path; tests prove it equals the throwing initializer on the same values.
    static let standard = ReferenceEvaluatorLimits(standardValues: ())

    private let scratchFloats: Int
    private let stateFloats: Int
    private let blocksPerRun: Int
    private let runWork: Int
    private let runOutputFloats: Int

    var maximumScratchFloats: Int { scratchFloats }
    var maximumStateFloats: Int { stateFloats }
    var maximumBlocksPerRun: Int { blocksPerRun }
    var maximumRunWork: Int { runWork }
    var maximumRunOutputFloats: Int { runOutputFloats }

    init(
        maximumScratchFloats: Int, maximumStateFloats: Int, maximumBlocksPerRun: Int,
        maximumRunWork: Int, maximumRunOutputFloats: Int
    ) throws(ReferenceEvaluatorRefusal) {
        guard (1...Self.scratchFloatsCeiling).contains(maximumScratchFloats) else {
            throw .invalidLimits(.scratchFloats)
        }
        guard (1...Self.stateFloatsCeiling).contains(maximumStateFloats) else {
            throw .invalidLimits(.stateFloats)
        }
        guard (1...Self.blocksPerRunCeiling).contains(maximumBlocksPerRun) else {
            throw .invalidLimits(.blocksPerRun)
        }
        guard (1...Self.runWorkCeiling).contains(maximumRunWork) else {
            throw .invalidLimits(.runWork)
        }
        guard (1...Self.runOutputFloatsCeiling).contains(maximumRunOutputFloats) else {
            throw .invalidLimits(.runOutputFloats)
        }
        scratchFloats = maximumScratchFloats
        stateFloats = maximumStateFloats
        blocksPerRun = maximumBlocksPerRun
        runWork = maximumRunWork
        runOutputFloats = maximumRunOutputFloats
    }

    private init(standardValues: Void) {
        scratchFloats = 4_194_304
        stateFloats = 4_194_304
        blocksPerRun = 1_024
        runWork = 1_073_741_824
        runOutputFloats = 4_194_304
    }
}
