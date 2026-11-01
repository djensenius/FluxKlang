// G-MEDIA §3 kernel values. Every stored field is fixed-size and BitwiseCopyable:
// no strings, Foundation objects, ARC or Array storage. These are native Swift
// values, not a promised C ABI/wire layout. Raw-string enum metadata is not
// stored in instances; Codable/rawValue/debug operations belong off the RT path.
// RuntimePreparation resolves identities before dispatch, never on the render thread.

struct RuntimeSampleStamp: Sendable, BitwiseCopyable {
    let clock: UInt32
    let generation: UInt64
    let frame: Int64
}

struct RuntimeMusicalStamp: Sendable, BitwiseCopyable {
    let transport: UInt64
    let musicalMap: UInt64
    let ticks: Int64
    let loopIteration: UInt32
}

struct RuntimeClockAnchor: Sendable, BitwiseCopyable {
    let sample: RuntimeSampleStamp
    let host: HostStamp
    let musical: RuntimeMusicalStamp?
}

struct RuntimeGenerationKey: Equatable, Sendable, BitwiseCopyable {
    let kind: GenerationKind
    let slot: UInt32
}

struct RuntimeGenerationRequirement: Equatable, Sendable, BitwiseCopyable {
    let key: RuntimeGenerationKey
    let generation: UInt64
}

/// Eight inline optional entries, never a heap-backed collection. Only the
/// prepare-time initializer accepts an Array; indexed reads allocate nothing.
struct RuntimeRequirements: Sendable, BitwiseCopyable {
    private let first: (RuntimeGenerationRequirement?, RuntimeGenerationRequirement?)
    private let second: (RuntimeGenerationRequirement?, RuntimeGenerationRequirement?)
    private let third: (RuntimeGenerationRequirement?, RuntimeGenerationRequirement?)
    private let fourth: (RuntimeGenerationRequirement?, RuntimeGenerationRequirement?)
    let count: Int

    init(_ values: [RuntimeGenerationRequirement]) throws(TriggerValidationError) {
        guard values.count <= TriggerStamp.maximumRequirements else { throw .tooManyRequirements(values.count) }
        func entry(_ index: Int) -> RuntimeGenerationRequirement? {
            index < values.count ? values[index] : nil
        }
        first = (entry(0), entry(1))
        second = (entry(2), entry(3))
        third = (entry(4), entry(5))
        fourth = (entry(6), entry(7))
        count = values.count
    }

    subscript(index: Int) -> RuntimeGenerationRequirement? {
        switch index {
        case 0: first.0
        case 1: first.1
        case 2: second.0
        case 3: second.1
        case 4: third.0
        case 5: third.1
        case 6: fourth.0
        case 7: fourth.1
        default: nil
        }
    }
}

struct RuntimeTriggerStamp: Sendable, BitwiseCopyable {
    let id: UInt32
    let action: UInt32
    let originHost: HostStamp
    let horizonFrame: Int64
    let requires: RuntimeRequirements
    let target: TriggerTarget
    let latePolicy: LatePolicy
    let retroactiveMs: Int
    let stoppedPolicy: StoppedPolicy
    let loopIteration: UInt32
}

enum RuntimeStaleDependency: Equatable, Sendable, BitwiseCopyable {
    case connectionEpoch, hostEpoch
    case generation(RuntimeGenerationKey)
}

struct RuntimeTriggerOutcome: Sendable, BitwiseCopyable {
    let trigger: UInt32
    let result: OutcomeResult
    let reason: DropReason?
    let stale: RuntimeStaleDependency?
    let assignedFrame: Int64?
    let frame: Int64?
    let startOffsetFrames: Int64
    let musicalMap: UInt64?
}

enum RuntimeCaptureStopReason: UInt8, Sendable, BitwiseCopyable { case diskFull, deviceLost }

/// Associated values restrict previousFrame and reason to their specified kinds.
enum RuntimeDiscontinuityKind: Sendable, BitwiseCopyable {
    case clockRestart(previousFrame: Int64)
    case sampleJump, underrun, overflow, sourceLost, sourceRestored, locate, loopWrap, formatChange
    case captureStopped(reason: RuntimeCaptureStopReason)
}

struct RuntimeDiscontinuity: Sendable, BitwiseCopyable {
    let kind: RuntimeDiscontinuityKind
    let sample: RuntimeSampleStamp
    let frames: UInt32?
    let stream: UInt32?
    let host: HostStamp?
}
