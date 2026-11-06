/// Resource dimension used in typed refusal and overflow reporting.
enum RoutingResource: Equatable, Sendable {
    case blockFrames, inputChannels, outputChannels, terms, slotSamples
    case delayFrames, scratchFloats, scratchBytes, sampleWork
}

/// Structural defect found in a schedule draft. This verifier does not establish
/// that a draft is graph-equivalent to its source document.
enum RoutingInconsistency: Equatable, Sendable {
    case duplicateNode, slotLayout, stepOrder, rowShape, termSource
    case causality, endpoint, delayLine, unresolvedReference
}

enum RoutingScheduleRefusal: Error, Equatable, Sendable {
    case invalidSampleRate(Int)
    case invalidBlockFrames(Int)
    case invalidLimits(RoutingResource)
    case resourceLimit(RoutingResource, required: Int, maximum: Int)
    case arithmeticOverflow(RoutingResource)
    case graphBounds(ProjectGraphLimitError)
    case invalidGraph(GraphValidationError)
    case unsupportedNodeKind(NodeID, NodeKind)
    case unsupportedNodeShape(NodeID)
    case unsupportedCapabilities(NodeID)
    case duplicateRoleBinding(RoleID)
    case invalidGain(NodeID)
    case feedbackDelayTooShort(EdgeID, Int)
    case feedbackGainNotCapped(EdgeID)
    case cycleWithoutDelay([NodeID])
    case inconsistentSchedule(RoutingInconsistency)
}

/// Validated caller budget and integer render geometry.
struct RoutingScheduleRequest: Sendable {
    static let sampleRateRange = 1...768_000
    let sampleRate: Int
    let blockFrames: Int
    let limits: AudioRoutingLimits

    init(
        sampleRate: Int, blockFrames: Int, limits: AudioRoutingLimits
    ) throws(RoutingScheduleRefusal) {
        guard Self.sampleRateRange.contains(sampleRate) else { throw .invalidSampleRate(sampleRate) }
        guard blockFrames > 0 else { throw .invalidBlockFrames(blockFrames) }
        guard limits.maxFrames > 0 else { throw .invalidLimits(.blockFrames) }
        guard limits.maxInputChannels >= 0 else { throw .invalidLimits(.inputChannels) }
        guard limits.maxOutputChannels >= 0 else { throw .invalidLimits(.outputChannels) }
        guard limits.maxTerms >= 0 else { throw .invalidLimits(.terms) }
        guard limits.maxScratchBytes > 0 else { throw .invalidLimits(.scratchBytes) }
        guard limits.maxSampleWork >= 0 else { throw .invalidLimits(.sampleWork) }
        guard blockFrames <= limits.maxFrames else {
            throw .resourceLimit(.blockFrames, required: blockFrames, maximum: limits.maxFrames)
        }
        self.sampleRate = sampleRate
        self.blockFrames = blockFrames
        self.limits = limits
    }
}

/// Planar float region; channel c begins at offset + c * frames.
struct RoutingSlot: Equatable, Sendable {
    let offset: Int
    let channels: Int
    let frames: Int
}

enum RoutingOperation: Equatable, Sendable {
    case copy
    case zero
    case scale(Float)
}

struct RoutingRow: Equatable, Sendable {
    let terms: [Int]
    let isBitCopy: Bool
}

struct RoutingStep: Equatable, Sendable {
    let node: NodeID
    let level: Int
    let operation: RoutingOperation
    let output: RoutingSlot
    let rows: [RoutingRow]
    let mixOrder: [EdgeID]
}

struct RoutingEndpoint: Equatable, Sendable {
    let endpoint: AudioRoutingEndpoint
    let slot: RoutingSlot
}

struct RoutingDelayLine: Equatable, Sendable {
    let cut: FeedbackCut
    let source: RoutingSlot
    let delayed: RoutingSlot
    let storage: RoutingSlot
}

struct RoutingAccounting: Equatable, Sendable {
    let inputChannels: Int
    let outputChannels: Int
    let termCount: Int
    let scratchFloats: Int
    let scratchBytes: Int
    let sampleWork: Int
}

/// Untrusted, editable plan data; only structural verification can promote it.
struct RoutingScheduleDraft: Equatable, Sendable {
    var graph: GraphID
    var revision: ContractRevision
    var inputs: [RoutingEndpoint]
    var steps: [RoutingStep]
    var outputs: [RoutingEndpoint]
    var delayLines: [RoutingDelayLine]
}

enum RoutingMath {
    static func add(
        _ lhs: Int, _ rhs: Int, resource: RoutingResource
    ) throws(RoutingScheduleRefusal) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw .arithmeticOverflow(resource) }
        return value
    }

    static func multiply(
        _ lhs: Int, _ rhs: Int, resource: RoutingResource
    ) throws(RoutingScheduleRefusal) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw .arithmeticOverflow(resource) }
        return value
    }
}
