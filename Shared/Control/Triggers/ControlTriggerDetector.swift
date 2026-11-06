import Foundation

// Commands and states are built only in this file (fileprivate initializers and setters), so callers cannot forge
// a command that skipped the detector's checks or a sequence the detector did not issue.

/// What one command does to its target.
enum ControlTriggerAction: String, Hashable, Sendable, CaseIterable {
    /// A momentary press edge.
    case press
    /// A momentary release edge, emitted only for bindings with `emitsRelease`.
    case release
    /// A toggle or latch output turned on.
    case switchedOn
    /// A toggle output turned off by a press, or a latch cleared.
    case switchedOff
}

/// One discrete command: which binding fired which neutral target from which control, and its sequence number.
/// Sequences are strictly increasing across every command one detector emits.
struct ControlTriggerCommand: Hashable, Sendable {
    let binding: BindingID
    let target: ControlTriggerTargetID
    let source: ControlSourceID
    let action: ControlTriggerAction
    let sequence: UInt64

    fileprivate init(binding: ControlTriggerBinding, action: ControlTriggerAction, sequence: UInt64) {
        self.binding = binding.id
        target = binding.target
        source = binding.source
        self.action = action
        self.sequence = sequence
    }
}

/// Runtime-only state of one trigger binding; never persisted. Every binding starts released and off.
struct ControlTriggerState: Hashable, Sendable {
    /// The control rose to its press threshold and has not yet fallen to its release threshold.
    fileprivate(set) var held = false
    /// The toggle or latch output; always `false` for momentary bindings.
    fileprivate(set) var isOn = false

    fileprivate init() {}
}

/// Turns absolute control positions into discrete trigger commands. Each binding emits on its press edge only:
/// a control that stays at or above `pressAt` (repeated messages while held) emits nothing more until it has fallen
/// to `releaseAt` or below. The detector owns the sequence counter, so sequences never go backwards; at
/// `UInt64.max` it refuses further commands rather than wrapping.
struct ControlTriggerDetector: Hashable, Sendable {
    static let maximumBindings = 4096

    private struct Entry: Hashable, Sendable {
        let binding: ControlTriggerBinding
        var state = ControlTriggerState()
    }

    private var entries: [BindingID: Entry]
    /// The last sequence issued; `0` before the first command of a fresh detector.
    private(set) var lastSequence: UInt64

    /// A detector with every binding released and off. `lastSequence` resumes a counter (for example a persisted
    /// high-water mark) so a rebuilt detector never reissues a sequence; the first command is `lastSequence + 1`.
    init(bindings: [ControlTriggerBinding], after lastSequence: UInt64 = 0) throws(ControlTriggerRefusal) {
        guard bindings.count <= Self.maximumBindings else { throw .tooManyBindings(bindings.count) }
        var entries: [BindingID: Entry] = [:]
        for binding in bindings {
            guard entries.updateValue(Entry(binding: binding), forKey: binding.id) == nil else {
                throw .duplicateBinding(binding.id)
            }
        }
        self.entries = entries
        self.lastSequence = lastSequence
    }

    /// The bindings, sorted by ID.
    var bindings: [ControlTriggerBinding] { entries.values.map(\.binding).sorted { $0.id < $1.id } }

    func state(of id: BindingID) -> ControlTriggerState? { entries[id]?.state }

    /// Reads one decoded input of binding `id`. Checks run before any state is read, in this order: unknown binding,
    /// source mismatch, stale controller, target missing, target class, input kind, non-finite, out of range; a
    /// refusal changes nothing. Returns the command for a press edge (or an opted-in release edge), or `nil` when
    /// the input crosses no threshold or the edge emits nothing (a latch already on, a release without
    /// `emitsRelease`).
    mutating func handle(_ input: ControlInput, from source: ControlSourceID, binding id: BindingID,
                         truth: ControlTriggerHostTruth) throws(ControlTriggerRefusal) -> ControlTriggerCommand? {
        guard var entry = entries[id] else { throw .unknownBinding(id) }
        let binding = entry.binding
        guard source == binding.source else { throw .sourceMismatch(expected: binding.source, found: source) }
        guard truth.sources.contains(source) else { throw .controllerStale(source) }
        try truth.requireFireable(binding.target)
        guard case .absolute(let position) = input else { throw .inputMismatch }
        guard position.isFinite else { throw .nonFinite }
        guard (0...1).contains(position) else { throw .inputOutOfRange(position) }
        let action: ControlTriggerAction?
        if !entry.state.held, position >= binding.pressAt {
            entry.state.held = true
            action = Self.pressed(binding.mode, &entry.state)
        } else if entry.state.held, position <= binding.releaseAt {
            entry.state.held = false
            action = binding.emitsRelease == true ? .release : nil
        } else {
            return nil
        }
        let command = try issue(action, for: binding)
        entries[id] = entry
        return command
    }

    /// Clears a latch: a `switchedOff` command when it is on, `nil` when it is already off. Clearing is a host
    /// action, not a control input, so the controller need not be current; the target must still be present and
    /// `.live`. The held flag is kept, so a control still held must be released before it can latch again.
    mutating func clear(_ id: BindingID, truth: ControlTriggerHostTruth) throws(ControlTriggerRefusal)
        -> ControlTriggerCommand? {
        guard var entry = entries[id] else { throw .unknownBinding(id) }
        guard entry.binding.mode == .latch else { throw .notLatch(entry.binding.mode) }
        try truth.requireFireable(entry.binding.target)
        guard entry.state.isOn else { return nil }
        entry.state.isOn = false
        let command = try issue(.switchedOff, for: entry.binding)
        entries[id] = entry
        return command
    }

    /// Forgets that the controls of `source` are held, without emitting anything; toggle and latch outputs are kept.
    /// Call when a controller disconnects or reconnects, so its next press is an edge. A momentary binding with
    /// `emitsRelease` gets no release command here; its consumer treats the disconnect itself as a release.
    mutating func forgetHeld(on source: ControlSourceID) {
        for (id, entry) in entries where entry.binding.source == source {
            entries[id]?.state.held = false
        }
    }

    private static func pressed(_ mode: ControlTriggerMode,
                                _ state: inout ControlTriggerState) -> ControlTriggerAction? {
        switch mode {
        case .momentary:
            return .press
        case .toggle:
            state.isOn.toggle()
            return state.isOn ? .switchedOn : .switchedOff
        case .latch:
            guard !state.isOn else { return nil }
            state.isOn = true
            return .switchedOn
        }
    }

    private mutating func issue(_ action: ControlTriggerAction?, for binding: ControlTriggerBinding)
        throws(ControlTriggerRefusal) -> ControlTriggerCommand? {
        guard let action else { return nil }
        guard lastSequence < .max else { throw .sequenceExhausted }
        lastSequence += 1
        return ControlTriggerCommand(binding: binding, action: action, sequence: lastSequence)
    }
}
