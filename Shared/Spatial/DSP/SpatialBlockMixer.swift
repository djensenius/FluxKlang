//
//  SpatialBlockMixer.swift
//  FluxKlang
//
//  The offline spatial block mixer (#115 SM2): applies a `SpatialRenderPlan`
//  through preallocated delay lines and moves between plans over a
//  sample-count ramp that aligns gains by source, channel and speaker ID.
//

/// A closed, single-owner offline mixer. Not `Sendable`, not real-time certified.
///
/// Layout is planar with a fixed stride of `limits.maxFrames`: input row `r`
/// starts at `r * maxFrames`, output speaker `s` at `s * maxFrames`. Input rows
/// follow the most recently installed plan's row order; while a ramp runs, the
/// rows (and output speakers) that only the previous plan had follow, in the
/// previous plan's order. `init` allocates everything; `transition` and
/// `process` call no allocating API of their own and take no lock. The caller
/// must supply live Float storage and exclusive output access for the whole
/// call: the geometry checks are not a pointer validity proof.
struct SpatialBlockMixer: ~Copyable {
    let limits: SpatialMixerLimits
    private var delayLines: SpatialDelayLines
    private var state: SpatialPlanTransition
    private var rowSamples: [Float]

    init(limits: SpatialMixerLimits, initial: SpatialRenderPlan) throws(SpatialMixerRefusal) {
        try limits.validate(initial)
        self.limits = limits
        delayLines = SpatialDelayLines(ringCount: 2 * limits.maxSpeakers, capacity: limits.delayCapacity)
        state = SpatialPlanTransition(rowCapacity: 2 * limits.maxRows, speakerCapacity: 2 * limits.maxSpeakers,
                                      plan: initial)
        rowSamples = [Float](repeating: 0, count: 2 * limits.maxRows)
        state.commit(initial, rampFrames: 0, delayLines: &delayLines)
    }

    /// The plan the mixer is at, or ramping to.
    var activePlan: SpatialRenderPlan { state.plan }
    var isTransitioning: Bool { state.isRamping }
    var rampFrames: Int { state.rampFrames }
    var rampProgress: Int { state.rampProgress }
    var delayWritePosition: Int { delayLines.writeIndex }
    /// The number of input rows `process` expects (new plan rows, then old-only rows while ramping).
    var inputRowCount: Int { state.rowCount }
    /// The number of output speakers `process` writes (new plan speakers, then old-only speakers while ramping).
    var outputSpeakerCount: Int { state.speakerCount }
    /// Allocates; for queries and tests, not for the process path.
    var outputSpeakerIDs: [SpeakerID] { state.speakerIDs }
    /// Allocates; for queries and tests, not for the process path.
    var inputRowKeys: [SpatialMixerRowKey] {
        zip(state.rowSources, state.rowChannels).map { SpatialMixerRowKey(source: $0, channel: $1) }
    }

    /// Moves to `plan` over `rampFrames` frames (`0...48,000`; 0 switches at once). Refusal order:
    /// ramp length, plan size, plan shape, delay, then a ramp already running (only for `rampFrames > 0`).
    /// A refusal changes nothing. `rampFrames == 0` is allowed mid-ramp but drops the in-flight state: gains step
    /// to the new plan, the delay crossfade is abandoned and the leaving speakers' tails are cut.
    mutating func transition(to plan: SpatialRenderPlan, rampFrames: Int) throws(SpatialMixerRefusal) {
        guard SpatialMixerLimits.rampRange.contains(rampFrames) else { throw .invalidRampFrames(rampFrames) }
        try limits.validate(plan)
        if rampFrames > 0, state.isRamping { throw .transitionInProgress }
        state.commit(plan, rampFrames: rampFrames, delayLines: &delayLines)
    }

    /// Mixes `frames` frames. Buffer counts must equal `inputRowCount * maxFrames` and
    /// `outputSpeakerCount * maxFrames` and the buffers must not overlap; those refusals touch no
    /// memory. A wrong input count with a valid output count is `geometryMismatch` and leaves the output
    /// untouched. A `frames` outside `0...maxFrames` silences the whole output buffer. A refusal never
    /// advances the ramp or the delay write position. Padding beyond `frames` in a slab is untouched.
    /// The overlap guard fails open if a buffer's address range overflows (unreachable for real buffers).
    mutating func process(
        frames: Int, input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>
    ) -> SpatialMixerResult {
        if let refusal = geometryRefusal(input: input, output: output) { return .refused(refusal) }
        guard frames >= 0, frames <= limits.maxFrames else {
            output.update(repeating: 0)
            return .refused(.invalidFrames(frames))
        }
        var sanitized = 0
        for frame in 0..<frames {
            sanitized += mixFrame(frame, input: input, output: output)
        }
        state.advance(frames: frames)
        return .processed(sanitizedSamples: sanitized)
    }

    private func geometryRefusal(
        input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>
    ) -> SpatialMixerRefusal? {
        let stride = limits.maxFrames
        guard input.count == state.rowCount * stride, output.count == state.speakerCount * stride else {
            return .geometryMismatch
        }
        guard !input.isEmpty, !output.isEmpty, let inBase = input.baseAddress, let outBase = output.baseAddress else {
            return nil
        }
        let inStart = UInt(bitPattern: inBase)
        let outStart = UInt(bitPattern: outBase)
        let (inEnd, inOverflow) = inStart.addingReportingOverflow(UInt(input.count * MemoryLayout<Float>.stride))
        let (outEnd, outOverflow) = outStart.addingReportingOverflow(UInt(output.count * MemoryLayout<Float>.stride))
        guard !inOverflow, !outOverflow, inStart < outEnd, outStart < inEnd else { return nil }
        return .overlappingBuffers
    }

    /// One frame: sanitise the input rows, write every speaker's feed, read every tap, advance the ring.
    private mutating func mixFrame(
        _ frame: Int, input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        let stride = limits.maxFrames
        let rows = state.rowCount
        let speakers = state.speakerCount
        var sanitized = 0
        for row in 0..<rows {
            let sample = input[row * stride + frame]
            rowSamples[row] = sample.isFinite ? sample : 0
            if !sample.isFinite { sanitized += 1 }
        }
        let fraction = state.fraction(at: frame)
        for speaker in 0..<speakers {
            var sum = 0.0
            for row in 0..<rows {
                sum += Double(state.gain(row: row, speaker: speaker, fraction: fraction)) * Double(rowSamples[row])
            }
            let feed = Float(sum)
            if !feed.isFinite { sanitized += 1 }
            delayLines.write(feed.isFinite ? feed : 0, ring: state.ringSlots[speaker])
        }
        for speaker in 0..<speakers {
            let sample = tap(speaker: speaker, fraction: fraction)
            if !sample.isFinite { sanitized += 1 }
            output[speaker * stride + frame] = sample.isFinite ? sample : 0
        }
        delayLines.advance()
        return sanitized
    }

    /// The speaker's delayed output: one tap, or a linear crossfade of the old and new delay taps.
    private func tap(speaker: Int, fraction: Double) -> Float {
        if speaker >= state.activeSpeakerCount, fraction >= 1 { return 0 }
        let ring = state.ringSlots[speaker]
        let target = state.toDelays[speaker]
        let start = state.fromDelays[speaker]
        if fraction >= 1 || start == target { return delayLines.read(ring: ring, delay: target) }
        let early = Double(delayLines.read(ring: ring, delay: start))
        let late = Double(delayLines.read(ring: ring, delay: target))
        return Float((1 - fraction) * early + fraction * late)
    }
}
