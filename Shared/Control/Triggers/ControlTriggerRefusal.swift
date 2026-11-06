import Foundation

/// Why a trigger call was refused. A refusal never changes the detector: no held state, output or sequence moves.
enum ControlTriggerRefusal: Error, Hashable, Sendable {
    /// More than `ControlTriggerDetector.maximumBindings` bindings were supplied.
    case tooManyBindings(Int)
    /// Two supplied bindings share one ID, so inputs cannot be routed unambiguously.
    case duplicateBinding(BindingID)
    /// More than `ControlTriggerHostTruth.maximumSources` current sources were supplied.
    case tooManySources(Int)
    /// More than `ControlTriggerHostTruth.maximumTargets` target classes were supplied.
    case tooManyTargets(Int)
    case unknownBinding(BindingID)
    /// The input came from another control than the binding's.
    case sourceMismatch(expected: ControlSourceID, found: ControlSourceID)
    /// The binding's control source is not among the host's current sources (disconnected or replaced).
    case controllerStale(ControlSourceID)
    /// The host does not classify the target now (for example it was removed); a class is never assumed. Release
    /// edges and latch clears are exempt: they only end an action.
    case targetMissing(ControlTriggerTargetID)
    /// Only `.live` targets fire; hazardous, safety, structural and proposal targets are refused. Release edges and
    /// latch clears are exempt: they only end an action.
    case targetClass(ControlTriggerTargetID, ControlClass)
    /// A relative input reached an absolute trigger.
    case inputMismatch
    case nonFinite
    case inputOutOfRange(Double)
    /// Only a latch can be cleared; a toggle turns off on its own press.
    case notLatch(ControlTriggerMode)
    /// Sequences saturate at `UInt64.max` rather than wrap. A press, switch-on, switch-off or clear is refused
    /// unless the sequences left also cover every release still owed (each held momentary binding with
    /// `emitsRelease`), so releases are never refused for exhaustion.
    case sequenceExhausted
}

/// The host's current truth for firing triggers: which control sources are current and how each target is
/// classified. The caller rebuilds it whenever host truth changes; the detector never caches it, so a removed
/// control source or a target reclassed as hazardous is judged by what the host reports now. Like the detector, it
/// belongs on the control thread, never the audio thread.
struct ControlTriggerHostTruth: Hashable, Sendable {
    /// Equal to `ControlTriggerDetector.maximumBindings`, so every binding may have its own current source.
    static let maximumSources = ControlTriggerDetector.maximumBindings
    static let maximumTargets = 4096
    private let storedSources: Set<ControlSourceID>
    private let storedTargets: [ControlTriggerTargetID: ControlClass]

    var sources: Set<ControlSourceID> { storedSources }
    var targets: [ControlTriggerTargetID: ControlClass] { storedTargets }

    init(sources: Set<ControlSourceID>,
         targets: [ControlTriggerTargetID: ControlClass]) throws(ControlTriggerRefusal) {
        guard sources.count <= Self.maximumSources else { throw .tooManySources(sources.count) }
        guard targets.count <= Self.maximumTargets else { throw .tooManyTargets(targets.count) }
        storedSources = sources
        storedTargets = targets
    }

    /// Refuses a target the host does not classify, then any class other than `.live`.
    func requireFireable(_ target: ControlTriggerTargetID) throws(ControlTriggerRefusal) {
        guard let controlClass = targets[target] else { throw .targetMissing(target) }
        guard controlClass == .live else { throw .targetClass(target, controlClass) }
    }
}
