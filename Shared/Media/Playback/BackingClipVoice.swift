//
//  BackingClipVoice.swift
//  FluxKlang
//
//  The backing-clip playback voice state machine (#111 PB1) over a PF1
//  `PrefetchPlayhead`. It is armed only by an explicit `arm` against current
//  readiness (media-contract.md §7), never at construction. Pure values: no
//  clock, disk, audio unit or pump. Rendering lives in BackingClipVoice+Render.
//

/// One backing-clip voice. `disarmed` → `armed` → `playing` → `stopped`; `stopped` is terminal.
/// Every refused operation leaves the voice unchanged.
struct BackingClipVoice: Sendable, Equatable {
    let spec: BackingClipSpec
    private(set) var playhead: PrefetchPlayhead
    private(set) var state: BackingVoiceState
    private(set) var hasPendingLocate: Bool
    /// Silence frames reported as underruns by renders of this voice.
    private(set) var underrunFrames: Int64

    private init(spec: BackingClipSpec, playhead: PrefetchPlayhead) {
        self.spec = spec
        self.playhead = playhead
        state = .disarmed
        hasPendingLocate = false
        underrunFrames = 0
    }

    /// A new voice: always `.disarmed`, at frame 0. Nothing constructs an armed voice.
    static func make(spec: BackingClipSpec, plan: PrefetchPlan, stream: UInt32, sourceGeneration: UInt64,
                     readGeneration: UInt64) throws(BackingClipRefusal) -> BackingClipVoice {
        do throws(PrefetchRefusal) {
            let playhead = try PrefetchPlayhead.make(plan: plan, stream: stream, position: 0,
                                                     sourceGeneration: sourceGeneration,
                                                     readGeneration: readGeneration)
            return BackingClipVoice(spec: spec, playhead: playhead)
        } catch {
            throw .prefetch(error)
        }
    }

    /// The next source frame; `totalFrames` after `.reachedEnd`, the first missing frame after a `.stopVoice` stop.
    var position: Int64 { playhead.position }
    var sourceGeneration: UInt64 { playhead.sourceGeneration }
    var readGeneration: UInt64 { playhead.readGeneration }
    var residentBlocks: [PrefetchBlock] { playhead.blocks }

    var snapshot: BackingVoiceSnapshot {
        BackingVoiceSnapshot(state: state, position: position, sourceGeneration: sourceGeneration,
                             readGeneration: readGeneration, blocks: playhead.blocks,
                             discardedStaleBlocks: playhead.discardedStaleBlocks, underrunFrames: underrunFrames,
                             hasPendingLocate: hasPendingLocate)
    }

    static func == (lhs: BackingClipVoice, rhs: BackingClipVoice) -> Bool {
        lhs.spec == rhs.spec && lhs.snapshot == rhs.snapshot && lhs.playhead.stream == rhs.playhead.stream
            && lhs.playhead.plan == rhs.playhead.plan
    }

    /// `.disarmed` → `.armed`, only when `readiness` has the action `.ready` and every dependency current.
    /// Refusals: stopped, `alreadyArmed`, `alreadyPlaying`, then `notReady(state)`, then `staleDependencies`.
    mutating func arm(readiness: ActionReadiness, ledger: GenerationLedger) throws(BackingClipRefusal) {
        switch state {
        case .stopped(let reason): throw .voiceStopped(reason)
        case .armed: throw .alreadyArmed
        case .playing: throw .alreadyPlaying
        case .disarmed: break
        }
        let found = readiness.state(spec.action)
        guard found == .ready else { throw .notReady(found) }
        guard readiness.isCurrent(spec.action, ledger: ledger) else { throw .staleDependencies }
        state = .armed
    }

    /// `.armed` → `.playing`. From `.disarmed` it refuses `notArmed`.
    mutating func play() throws(BackingClipRefusal) {
        switch state {
        case .stopped(let reason): throw .voiceStopped(reason)
        case .playing: throw .alreadyPlaying
        case .disarmed: throw .notArmed
        case .armed: state = .playing
        }
    }

    /// `.armed` or `.playing` → `.disarmed`; position and blocks are kept.
    mutating func disarm() throws(BackingClipRefusal) {
        switch state {
        case .stopped(let reason): throw .voiceStopped(reason)
        case .disarmed: throw .notArmed
        case .armed, .playing: state = .disarmed
        }
    }

    /// Any non-stopped state → `.stopped(.requested)`.
    mutating func stop() throws(BackingClipRefusal) {
        try requireNotStopped()
        state = .stopped(.requested)
    }

    /// Moves the playhead to `frame` in `0...totalFrames - 1` in any non-stopped state. It is a new read: the read
    /// generation advances and resident blocks are dropped. A playing voice keeps playing; the next render reports
    /// one `.locate` at its first frame. Refusals in order: stopped, range, read generation exhausted
    /// (`.prefetch(.generationOverflow)`), `.counterWouldOverflow(.discardedStaleBlocks)`.
    mutating func seek(to frame: Int64) throws(BackingClipRefusal) {
        try requireNotStopped()
        guard (0..<spec.totalFrames).contains(frame) else {
            throw .seekOutOfRange(frame: frame, totalFrames: spec.totalFrames)
        }
        guard playhead.readGeneration < UInt64.max else { throw .prefetch(.generationOverflow) }
        try requireDiscardCapacity(adding: playhead.blocks.count)
        var next = playhead
        do throws(PrefetchRefusal) { try next.locate(to: frame) } catch { throw .prefetch(error) }
        playhead = next
        hasPendingLocate = true
    }

    /// Adds a filled block (PF1 rules: stale blocks are discarded and counted, not refused). A stale block is
    /// refused with `.counterWouldOverflow(.discardedStaleBlocks)` when the count could not advance. That guard runs
    /// BEFORE PF1, so it wins over PF1's own refusals (e.g. a stale block that is also too long at the ceiling).
    @discardableResult
    mutating func insert(_ block: PrefetchBlock) throws(BackingClipRefusal) -> PrefetchInsertOutcome {
        try requireNotStopped()
        let stale = block.sourceGeneration < playhead.sourceGeneration
            || block.readGeneration < playhead.readGeneration
        if stale { try requireDiscardCapacity(adding: 1) }
        var next = playhead
        let outcome: PrefetchInsertOutcome
        do throws(PrefetchRefusal) { outcome = try next.insert(block) } catch { throw .prefetch(error) }
        playhead = next
        return outcome
    }

    /// Refuses before PF1 adds `count` to `discardedStaleBlocks` when the spec ceiling would be passed.
    func requireDiscardCapacity(adding count: Int) throws(BackingClipRefusal) {
        guard BackingCounterGuard.capacityAdmits(current: Int64(playhead.discardedStaleBlocks), adding: Int64(count),
                                                 ceiling: spec.counterCeiling) else {
            throw .counterWouldOverflow(.discardedStaleBlocks)
        }
    }

    /// Stops an armed or playing voice (`.readinessLost`) whose action is no longer current. A disarmed or stopped
    /// voice is untouched, and returning readiness never re-arms. Returns true when this call stopped the voice.
    @discardableResult
    mutating func readinessChanged(readiness: ActionReadiness, ledger: GenerationLedger) -> Bool {
        switch state {
        case .disarmed, .stopped: return false
        case .armed, .playing:
            guard !readiness.isCurrent(spec.action, ledger: ledger) else { return false }
            state = .stopped(.readinessLost)
            return true
        }
    }

    func requireNotStopped() throws(BackingClipRefusal) {
        if case .stopped(let reason) = state { throw .voiceStopped(reason) }
    }

    /// Applies a finished render. Only `BackingRenderCommit`, built by the render step, can be passed.
    mutating func apply(_ commit: BackingRenderCommit) {
        playhead = commit.playhead
        state = commit.state
        underrunFrames = commit.underrunFrames
        hasPendingLocate = false
    }
}
