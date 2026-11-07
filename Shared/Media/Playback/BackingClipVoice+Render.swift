//
//  BackingClipVoice+Render.swift
//  FluxKlang
//
//  Rendering of a backing-clip voice (#111 PB1). A render works on a copy of the
//  playhead and is applied only when it succeeds, so any refusal leaves the voice
//  unchanged. It never does I/O: it serves what the prefetch pool holds and
//  reports every gap, wrap and locate as a `RuntimeDiscontinuity`. One call is one
//  chunk: it never straddles a loop wrap (see DESIGN.md, "Render protocol").
//

/// The finished state of one render. Only the render step in this file can build it.
struct BackingRenderCommit {
    let playhead: PrefetchPlayhead
    let state: BackingVoiceState
    let underrunFrames: Int64

    fileprivate init(playhead: PrefetchPlayhead, state: BackingVoiceState, underrunFrames: Int64) {
        self.playhead = playhead
        self.state = state
        self.underrunFrames = underrunFrames
    }
}

extension BackingClipVoice {
    /// Renders up to `frames` output frames whose first frame plays at `sample`, as ONE chunk.
    /// `frames` over the loop length is refused even when the playhead is outside the loop (conservative, consistent).
    ///
    /// Refusal order: stopped, not playing, `frames` outside `1...plan.poolFrames`, `sample.frame + frames`
    /// overflow, `frames` over the loop length, a wrap with an exhausted read generation, then the cumulative
    /// counters (`underrunFrames`, then `discardedStaleBlocks` for a wrap). The chunk stops at the loop end (the
    /// voice wraps: a new read, `.loopWrapped`) or the clip end (`.reachedEnd`); the rest is `unrenderedFrames`,
    /// never an underrun. Under `.stopVoice` the chunk stops at the first missing frame.
    mutating func render(frames: Int, at sample: RuntimeSampleStamp) throws(BackingClipRefusal) -> BackingRender {
        try requireNotStopped()
        guard state == .playing else { throw .notPlaying(state) }
        let maximum = playhead.plan.poolFrames
        guard (1...maximum).contains(frames) else {
            throw .prefetch(.renderLengthOutOfRange(frames: frames, maximum: maximum))
        }
        guard !sample.frame.addingReportingOverflow(Int64(frames)).overflow else {
            throw .prefetch(.frameOverflow(startFrame: sample.frame, frames: frames))
        }
        if let loopFrames = spec.loopFrames, Int64(frames) > loopFrames {
            throw .renderExceedsLoop(frames: frames, loopFrames: loopFrames)
        }
        let (chunk, wraps) = nextChunk(frames: frames)
        try requireRenderCapacity(chunk: chunk, wraps: wraps)
        var run = BackingRenderRun(voice: self, sample: sample, frames: frames)
        do throws(PrefetchRefusal) {
            try run.execute(chunk: chunk, wraps: wraps, locatePending: hasPendingLocate)
        } catch {
            throw .prefetch(error)
        }
        apply(run.commit())
        return run.result()
    }

    /// The chunk length (at least 1) and whether it ends at the loop end. Compares against remaining frames only.
    private func nextChunk(frames: Int) -> (chunk: Int, wraps: Bool) {
        if let loop = spec.loop, playhead.position < loop.endFrame {
            let distance = loop.endFrame - playhead.position
            return distance <= Int64(frames) ? (Int(distance), true) : (frames, false)
        }
        return (Int(min(Int64(frames), spec.totalFrames - playhead.position)), false)
    }

    private func requireRenderCapacity(chunk: Int, wraps: Bool) throws(BackingClipRefusal) {
        if wraps && playhead.readGeneration == UInt64.max { throw .prefetch(.generationOverflow) }
        let adding = Int64(chunk)
        // PF1's own counter never exceeds the voice's (the voice adds every gap PF1 adds, and more under stopVoice).
        guard BackingCounterGuard.capacityAdmits(current: underrunFrames, adding: adding,
                                                 ceiling: spec.counterCeiling) else {
            throw .counterWouldOverflow(.underrunFrames)
        }
        if wraps { try requireDiscardCapacity(adding: playhead.blocks.count) }
    }
}

/// The working copy of one render.
private struct BackingRenderRun {
    let spec: BackingClipSpec
    let sample: RuntimeSampleStamp
    let requested: Int
    var playhead: PrefetchPlayhead
    var segments: [PrefetchSegment] = []
    var discontinuities: [RuntimeDiscontinuity] = []
    var rendered = 0
    var stopped: BackingStopReason?
    var outcome = BackingRenderOutcome.complete
    var underrunFrames: Int64

    init(voice: BackingClipVoice, sample: RuntimeSampleStamp, frames: Int) {
        spec = voice.spec
        self.sample = sample
        requested = frames
        playhead = voice.playhead
        underrunFrames = voice.underrunFrames
    }

    mutating func execute(chunk: Int, wraps: Bool, locatePending: Bool) throws(PrefetchRefusal) {
        if locatePending { discontinuities.append(event(.locate, at: 0)) }
        if spec.underrun == .stopVoice {
            guard try renderResident(chunk: chunk) else { return }
        } else {
            try renderAll(chunk: chunk)
        }
        try settle(chunk: chunk, wraps: wraps)
    }

    private mutating func renderAll(chunk: Int) throws(PrefetchRefusal) {
        let render = try playhead.render(frames: chunk, at: sample)
        segments += render.segments
        discontinuities += render.underruns
        underrunFrames += render.underruns.reduce(0) { $0 + Int64($1.frames ?? 0) }
        rendered = chunk
    }

    /// Probes on a copy. With no gap the probe is committed; otherwise only the resident prefix is rendered on the
    /// real playhead (a discarded probe never advances PF1's `underrunFrames`) and the voice stops. Returns whether
    /// the chunk was complete.
    private mutating func renderResident(chunk: Int) throws(PrefetchRefusal) -> Bool {
        var probe = playhead
        let render = try probe.render(frames: chunk, at: sample)
        guard let gap = render.underruns.first else {
            playhead = probe
            segments = render.segments
            rendered = chunk
            return true
        }
        var prefix = 0
        for segment in render.segments {
            guard case .served(_, let frames) = segment else { break }
            prefix += frames
        }
        if prefix > 0 { segments = try playhead.render(frames: prefix, at: sample).segments }
        discontinuities.append(gap)
        underrunFrames += Int64(gap.frames ?? 0)
        rendered = prefix
        stopped = .underrun
        outcome = .underrunStopped(unrenderedFrames: requested - prefix)
        return false
    }

    private mutating func settle(chunk: Int, wraps: Bool) throws(PrefetchRefusal) {
        if wraps, let loop = spec.loop {
            try playhead.locate(to: loop.startFrame)
            discontinuities.append(event(.loopWrap, at: chunk))
            outcome = .loopWrapped(unrenderedFrames: requested - chunk)
        } else if playhead.position == spec.totalFrames {
            stopped = .reachedEnd
            outcome = .reachedEnd(unrenderedFrames: requested - chunk)
        }
    }

    private func event(_ kind: RuntimeDiscontinuityKind, at offset: Int) -> RuntimeDiscontinuity {
        let stamp = RuntimeSampleStamp(clock: sample.clock, generation: sample.generation,
                                       frame: sample.frame + Int64(offset))
        return RuntimeDiscontinuity(kind: kind, sample: stamp, frames: nil, stream: playhead.stream, host: nil)
    }

    func commit() -> BackingRenderCommit {
        BackingRenderCommit(playhead: playhead, state: stopped.map { .stopped($0) } ?? .playing,
                            underrunFrames: underrunFrames)
    }

    func result() -> BackingRender {
        BackingRender(segments: segments, discontinuities: discontinuities, renderedFrames: rendered,
                      stopped: stopped, outcome: outcome, readGeneration: playhead.readGeneration)
    }
}
