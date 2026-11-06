// #64 E5a release tombstones: the latest release time of every note key, so a `noteOn` that a strictly later
// `noteOff` already released can never sound after it, whatever lane or block either was drained in.
// Reference model; not RT-certified.

/// Render-owned latest release frame per (scope, channel, note): the same key space as `NoteOwnership`.
/// Reference model; not RT-certified.
///
/// Why. The fan-in keeps FIFO order per lane only. A partial drain (the block buffer's free room or the per-lane
/// quota) can therefore deliver a `noteOff` from one lane before an earlier-stamped `noteOn` of the same key from
/// another lane: the release finds nothing to release, and the late `noteOn` would then sound for ever with no
/// fault. Cross-lane order of same-key events is otherwise not guaranteed; this rule makes "release wins"
/// deterministic.
///
/// Rule. Every applied `noteOff` event (decided, or consumed while silenced or flushing, whether or not it
/// released anything) and every `noteOff` still pending in a retired cycle's block buffer (`KernelCycle.retire()`)
/// records `max(tombstone, event.frame)` for its key. A decided `noteOn` whose original
/// `event.frame` is strictly before its key's tombstone is superseded: never emitted or owned, counted in
/// `KernelCycleResult.discardedSuperseded`. Ties go to the `noteOn` (round 4b): a `noteOn` at its key's release
/// frame is a new note (a same-frame retrigger) whose own `noteOff` comes later, so it cannot stick. A same-frame
/// `noteOn`/`noteOff` pair meant as one note is a zero-length note, which producers must not send.
///
/// Expiry is lazy and O(1): a tombstone before `blockStart − lateTolerance` is ignored, because any `noteOn` at or
/// before it is already dropped late by `DeadlinePolicy`. Nothing is ever cleared on render.
///
/// Panic and resets. Synthesized releases (safety requests, critical-fault recovery) record nothing, so a fresh
/// `noteOn` after a panic sounds normally; tombstones already recorded are kept (they only ever suppress notes
/// whose release was seen). "Release wins" includes a `noteOff` consumed undecided while silenced or left pending by
/// a retired cycle: it records its own, possibly future, event frame and is deliberately not clamped to
/// `blockStart`. Clamping would let an
/// earlier-stamped `noteOn` of that key, arriving after recovery, sound with no release left (a stuck note).
/// The trade-off is fail-safe: that `noteOn` is suppressed instead (a possible missed note, never a stuck one).
/// Bound: such a tombstone can suppress its key for at most the deadline policy's lookahead after `blockStart`
/// plus `lateTolerance` (96,000 frames, about 2 s at 48 kHz, for MIDI receive), never more than
/// `KernelLimits.maximumHorizonFrames`. Accepted trade-off.
///
/// Sharing (round 2g): `NoteOwnership` allocates and owns the table, so every `KernelCycle` over one ownership
/// (a `.replacingCycle` replacement included) reads and writes the same history; a replacement never forgets a
/// release its predecessor applied. Same contract as the ownership: only render touches it, one cycle at a time.
///
/// Storage: `scopes × 16 × 128` `Int64` words, allocated in `init` and freed in `deinit`. Render only after init.
final class ReleaseTombstones: @unchecked Sendable {
    /// No release recorded.
    static let none = Int64.min

    let scopeCount: Int
    private let frames: UnsafeMutablePointer<Int64>

    /// Control-side preparation. `scopes` is clamped to `1...NoteOwnership.maximumScopes`.
    init(scopes: Int) {
        scopeCount = min(max(scopes, 1), NoteOwnership.maximumScopes)
        let count = scopeCount &* NoteOwnership.maximumNotesPerScope
        frames = .allocate(capacity: count)
        frames.initialize(repeating: Self.none, count: count)
    }

    /// Control-side teardown only.
    deinit {
        frames.deallocate()
    }

    /// Render only. Records a `noteOff` event's release of its key at its original frame; other payloads and
    /// out-of-range keys are ignored.
    func release(_ event: KernelEvent) {
        guard case .noteOff(let channel, let note) = event.payload,
              let index = index(event.scope, channel, note) else { return }
        if event.frame > frames[index] { frames[index] = event.frame }
    }

    /// Render only. `true` when `event` is a `noteOn` whose key has a recorded release strictly after its original
    /// frame that has not expired: it is not before `blockStart − lateTolerance` (saturating).
    func supersedes(_ event: KernelEvent, blockStart: Int64, lateTolerance: Int64) -> Bool {
        guard case .noteOn(let channel, let note, _) = event.payload,
              let index = index(event.scope, channel, note) else { return false }
        let tombstone = frames[index]
        let (horizon, overflow) = blockStart.subtractingReportingOverflow(lateTolerance)
        guard tombstone != Self.none, overflow || tombstone >= horizon else { return false }
        return event.frame < tombstone
    }

    private func index(_ scope: UInt32, _ channel: UInt8, _ note: UInt8) -> Int? {
        guard scope < UInt32(truncatingIfNeeded: scopeCount), Int(channel) < NoteOwnership.channels,
              Int(note) < NoteOwnership.notesPerChannel else { return nil }
        return (Int(scope) &* NoteOwnership.channels &+ Int(channel)) &* NoteOwnership.notesPerChannel &+ Int(note)
    }
}
