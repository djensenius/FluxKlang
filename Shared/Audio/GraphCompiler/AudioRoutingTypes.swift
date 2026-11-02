/// Caller-supplied offline preparation budgets; these are not production defaults.
struct AudioRoutingLimits {
    let maxFrames: Int
    let maxInputChannels: Int
    let maxOutputChannels: Int
    let maxTerms: Int
    let maxScratchBytes: Int
    /// Sample operations, not elapsed time.
    let maxSampleWork: Int
}

struct AudioRoutingEndpoint: Equatable {
    let node: NodeID
    let port: PortID
    let role: RoleID
    let channels: Int
    let firstChannel: Int
}

/// Internal planar Float32 ABI. Each channel has a fixed `maxFrames` stride,
/// including for short and zero-frame calls. Peaks are per output channel.
struct AudioRoutingLayout: Equatable {
    let graph: GraphID
    let revision: ContractRevision
    let maxFrames: Int
    let inputs: [AudioRoutingEndpoint]
    let outputs: [AudioRoutingEndpoint]
    let inputSampleCount: Int
    let outputSampleCount: Int
    let peakCount: Int
}

enum AudioRoutingPreparationError: Error, Equatable {
    case invalidConfiguration
    case resourceLimit
    case arithmeticOverflow
    case unsupported
    case collectionBounds(ProjectGraphLimitError)
    case contractFailure(ProjectValidationError)
}

enum AudioRoutingProcessRefusal: Equatable {
    case invalidFrames
    case invalidBufferGeometry
    case overlappingStorage
    case nonFiniteInput
    case nonFiniteSum
    case scratchUnavailable
}

enum AudioRoutingProcessResult: Equatable {
    case processed
    case refused(AudioRoutingProcessRefusal)
}
