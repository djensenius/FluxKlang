import Foundation

// Commands and states are built only in this file (fileprivate initializers and setters), so callers cannot forge
// a command that skipped the detector's checks or a sequence the detector did not issue.

/// What one command does to its target.
enum ControlTriggerAction: String, Hashable, Sendable, CaseIterable {
    /// A momentary press edge.
    case press
    /// A momentary release, emitted only for bindings with `emitsRelease`: on a release edge, or when the held
    /// control's source is forgotten.
    case release
    /// A toggle or latch output turned on.
    case switchedOn
    /// A toggle output turned off by a press, or a toggle or latch cleared.
    case switchedOff
}

/// Why a command was emitted.
enum ControlTriggerCause: String, Hashable, Sendable, CaseIterable {
    /// A control input crossed a threshold (`handle`).
    case input
    /// A toggle or latch was cleared (`clear`).
    case clear
    /// A held control's source was forgotten (`forgetHeld`), for example on disconnect; always a `release`.
    case disconnect
}

/// One discrete command: which binding fired which neutral target from which control, why, and its sequence number.
/// Sequences are strictly increasing across every command one detector emits.
struct ControlTriggerCommand: Hashable, Sendable {
    let binding: BindingID
    let target: ControlTriggerTargetID
    let source: ControlSourceID
    let action: ControlTriggerAction
    let cause: ControlTriggerCause
    let sequence: UInt64

    fileprivate init(binding: ControlTriggerBinding, action: ControlTriggerAction, cause: ControlTriggerCause,
                     sequence: UInt64) {
        self.binding = binding.id
        target = binding.target
        source = binding.source
        self.action = action
        self.cause = cause
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
///
/// Releases are never refused for exhaustion. A release is owed by every held momentary binding with
/// `emitsRelease`, and every other command (press, switch-on, switch-off, clear) is refused with
/// `sequenceExhausted` unless the sequences left after it still cover every release owed after it, including one
/// owed by the binding it presses. Release edges and `forgetHeld` therefore always have room.
///
/// Held flags and toggle/latch outputs live only in this value. Rebuilding a detector (for example to change its
/// bindings) resets every binding to released and off without emitting any command, so a caller that rebuilds
/// while a control is held or an output is on must end those actions itself. Use it on the control thread, never
/// the audio thread.
struct ControlTriggerDetector: Hashable, Sendable {
    static let maximumBindings = 4096

    private struct Entry: Hashable, Sendable {
        let binding: ControlTriggerBinding
        var state = ControlTriggerState()

        /// Held with `emitsRelease` (momentary only), so a release command is still owed.
        var owesRelease: Bool { state.held && binding.emitsRelease == true }
    }

    private var entries: [BindingID: Entry]
    /// How many entries owe a release (`owesRelease`), kept in step wherever a held flag changes so a command
    /// checks its headroom in O(1) rather than recounting every binding.
    private(set) var owedCount: Int
    /// The last sequence issued; `0` before the first command of a fresh detector.
    private(set) var lastSequence: UInt64

    /// A detector with every binding released and off. `lastSequence` resumes a counter (for example a persisted
    /// high-water mark) so a rebuilt detector never reissues a sequence; the first command is `lastSequence + 1`.
    /// Nothing held or on in a previous detector carries over and no command is emitted for it: the caller must
    /// release or switch off those targets itself.
    init(bindings: [ControlTriggerBinding], after lastSequence: UInt64 = 0) throws(ControlTriggerRefusal) {
        guard bindings.count <= Self.maximumBindings else { throw .tooManyBindings(bindings.count) }
        var entries: [BindingID: Entry] = [:]
        for binding in bindings {
            guard entries.updateValue(Entry(binding: binding), forKey: binding.id) == nil else {
                throw .duplicateBinding(binding.id)
            }
        }
        self.entries = entries
        // Every binding starts released, so nothing is owed yet.
        owedCount = 0
        self.lastSequence = lastSequence
    }

    /// The bindings, sorted by ID.
    var bindings: [ControlTriggerBinding] { entries.values.map(\.binding).sorted { $0.id < $1.id } }

    func state(of id: BindingID) -> ControlTriggerState? { entries[id]?.state }

    /// Reads one decoded input of binding `id`. Checks run before any state changes, in this order: unknown
    /// binding, source mismatch, stale control source, input kind, non-finite, out of range, then target missing and
    /// target class, then sequence headroom. A release edge (held, and at or below `releaseAt`) skips the target
    /// checks, because it only ends an action. A refusal changes nothing. Returns the command for a press edge (or
    /// an opted-in release edge), or `nil` when the target is fireable and the edge emits nothing (a latch already
    /// on) or the input crosses no threshold, or on a release edge without `emitsRelease`. Any non-release input on
    /// a missing or non-`.live` target is refused with the target refusal.
    mutating func handle(_ input: ControlInput, from source: ControlSourceID, binding id: BindingID,
                         truth: ControlTriggerHostTruth) throws(ControlTriggerRefusal) -> ControlTriggerCommand? {
        guard var entry = entries[id] else { throw .unknownBinding(id) }
        let binding = entry.binding
        guard source == binding.source else { throw .sourceMismatch(expected: binding.source, found: source) }
        guard truth.sources.contains(source) else { throw .controllerStale(source) }
        guard case .absolute(let position) = input else { throw .inputMismatch }
        guard position.isFinite else { throw .nonFinite }
        guard (0...1).contains(position) else { throw .inputOutOfRange(position) }
        let action: ControlTriggerAction?
        if entry.state.held, position <= binding.releaseAt {
            entry.state.held = false
            action = binding.emitsRelease == true ? .release : nil
        } else {
            try truth.requireFireable(binding.target)
            guard !entry.state.held, position >= binding.pressAt else { return nil }
            entry.state.held = true
            action = Self.pressed(binding.mode, &entry.state)
        }
        let command = try issue(action, for: entry, cause: .input)
        store(entry)
        return command
    }

    /// Clears a toggle or latch: a `switchedOff` command when it is on, `nil` when it is already off. Clearing is a
    /// host action that only ends an action, so neither a current control source nor a present, `.live` target is
    /// required; only sequence headroom is, including the releases still owed. A momentary binding is refused with
    /// `notLatch`. The held flag is kept, so a control still held must be released before its next press is an edge.
    mutating func clear(_ id: BindingID) throws(ControlTriggerRefusal) -> ControlTriggerCommand? {
        guard var entry = entries[id] else { throw .unknownBinding(id) }
        guard entry.binding.mode != .momentary else { throw .notLatch(entry.binding.mode) }
        guard entry.state.isOn else { return nil }
        entry.state.isOn = false
        let command = try issue(.switchedOff, for: entry, cause: .clear)
        store(entry)
        return command
    }

    /// Forgets that the controls of `sources` are held, so their next press is an edge. Call when a control source
    /// disconnects or reconnects. Returns a `release` (cause `.disconnect`) for every held momentary binding with
    /// `emitsRelease` on those sources, sorted by binding ID with consecutive sequences; no other binding emits, and
    /// toggle and latch outputs are kept. Targets are not checked, because a release only ends an action. The
    /// headroom reserved by presses guarantees room for these releases; the call is all-or-nothing regardless.
    mutating func forgetHeld(on sources: Set<ControlSourceID>) throws(ControlTriggerRefusal)
        -> [ControlTriggerCommand] {
        let held = entries.filter { sources.contains($0.value.binding.source) && $0.value.state.held }
        let releasing = held.values.filter(\.owesRelease).map(\.binding).sorted { $0.id < $1.id }
        guard UInt64.max - lastSequence >= UInt64(releasing.count) else { throw .sequenceExhausted }
        for id in held.keys { entries[id]?.state.held = false }
        owedCount -= releasing.count
        var commands: [ControlTriggerCommand] = []
        for binding in releasing { commands.append(next(.release, for: binding, cause: .disconnect)) }
        return commands
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

    /// Issues `action` for `entry` (in its new state) when it leaves a sequence for every release owed after it.
    /// A release always passes: it was reserved when its press was issued.
    private mutating func issue(_ action: ControlTriggerAction?, for entry: Entry, cause: ControlTriggerCause)
        throws(ControlTriggerRefusal) -> ControlTriggerCommand? {
        guard let action else { return nil }
        guard UInt64.max - lastSequence > owedReleases(with: entry) else { throw .sequenceExhausted }
        return next(action, for: entry.binding, cause: cause)
    }

    /// Releases owed if `entry` replaced its stored state.
    private func owedReleases(with entry: Entry) -> UInt64 {
        let stored = entries[entry.binding.id]?.owesRelease == true ? 1 : 0
        return UInt64(owedCount - stored) + (entry.owesRelease ? 1 : 0)
    }

    /// Stores `entry`, moving `owedCount` by the change in its `owesRelease`.
    private mutating func store(_ entry: Entry) {
        if entries[entry.binding.id]?.owesRelease == true { owedCount -= 1 }
        if entry.owesRelease { owedCount += 1 }
        entries[entry.binding.id] = entry
    }

    /// The owed releases counted over every binding (O(bindings)). Only for tests that cross-check `owedCount`.
    func recountOwedReleases() -> Int { entries.values.filter(\.owesRelease).count }

    private mutating func next(_ action: ControlTriggerAction, for binding: ControlTriggerBinding,
                               cause: ControlTriggerCause) -> ControlTriggerCommand {
        lastSequence += 1
        return ControlTriggerCommand(binding: binding, action: action, cause: cause, sequence: lastSequence)
    }
}
