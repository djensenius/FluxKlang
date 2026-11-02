/// Closed, single-owner offline processor, not Sendable and not RT-certified.
///
/// The caller must supply live, correctly Float-bound storage and exclusive
/// output/peak access for the entire call. Geometry checks are not a pointer
/// validity proof. No publication, retirement, FaultLatch or engine ACK is wired.
/// Actual hot integration still requires #190's K < 2^39 lifetime/HB,
/// nonreentrant logical chains, including separate M5 refusal counters.
struct OfflineAudioRoutingProcessor: ~Copyable {
    private let plan: PreparedAudioRoutingPlan
    private let arena: ScratchArena

    var layout: AudioRoutingLayout { plan.layout }

    init(project: ProjectDocument, selectedGraph: GraphDocument, limits: AudioRoutingLimits) throws {
        let prepared = try AudioRoutingCompiler.compile(
            project: project, selectedGraph: selectedGraph, limits: limits
        )
        let preparedArena = try ScratchArena(
            byteCapacity: prepared.scratchBytes, alignment: MemoryLayout<Float>.alignment
        )
        plan = prepared
        arena = preparedArena
    }

    /// Full fixed-stride slabs must be disjoint, including their inactive padding.
    /// Geometry refusals touch no memory. Other refusals silence active outputs
    /// and peaks without touching padding; no partially computed output escapes.
    mutating func process(
        frames: Int, input: UnsafeBufferPointer<Float>,
        output: UnsafeMutableBufferPointer<Float>, peaks: UnsafeMutableBufferPointer<Float>
    ) -> AudioRoutingProcessResult {
        guard frames >= 0, frames <= plan.layout.maxFrames else { return .refused(.invalidFrames) }
        if let refusal = geometry(input: input, output: output, peaks: peaks) { return .refused(refusal) }
        if frames == 0 {
            for channel in 0..<peaks.count { peaks[channel] = 0 }
            return .processed
        }
        arena.resetCycle()
        guard let scratch = arena.take(Float.self, count: plan.scratchFloats) else {
            silence(frames: frames, output: output, peaks: peaks)
            return .refused(.scratchUnavailable)
        }
        if let refusal = stage(frames: frames, input: input, scratch: scratch) {
            silence(frames: frames, output: output, peaks: peaks)
            return .refused(refusal)
        }
        if let refusal = compute(frames: frames, scratch: scratch) {
            silence(frames: frames, output: output, peaks: peaks)
            return .refused(refusal)
        }
        commit(frames: frames, scratch: scratch, output: output, peaks: peaks)
        return .processed
    }

    private func geometry(
        input: UnsafeBufferPointer<Float>,
        output: UnsafeMutableBufferPointer<Float>, peaks: UnsafeMutableBufferPointer<Float>
    ) -> AudioRoutingProcessRefusal? {
        guard input.count == plan.layout.inputSampleCount, output.count == plan.layout.outputSampleCount,
              peaks.count == plan.layout.peakCount,
              let source = AudioRoutingByteInterval(base: input.baseAddress, count: input.count),
              let destination = AudioRoutingByteInterval(
                base: output.baseAddress.map { UnsafePointer($0) }, count: output.count
              ),
              let meters = AudioRoutingByteInterval(
                base: peaks.baseAddress.map { UnsafePointer($0) }, count: peaks.count
              ) else {
            return .invalidBufferGeometry
        }
        guard !source.overlaps(destination), !source.overlaps(meters), !destination.overlaps(meters) else {
            return .overlappingStorage
        }
        return nil
    }

    private func stage(
        frames: Int, input: UnsafeBufferPointer<Float>, scratch: UnsafeMutableBufferPointer<Float>
    ) -> AudioRoutingProcessRefusal? {
        // All offsets below are bounded by the checked preflight slab products
        // and sums. Every active input is staged once, even if it is disconnected.
        let stride = plan.layout.maxFrames
        for endpoint in plan.layout.inputs {
            for channel in 0..<endpoint.channels {
                let offset = (endpoint.firstChannel + channel) * stride
                for frame in 0..<frames {
                    let value = input[offset + frame]
                    guard value.isFinite else { return .nonFiniteInput }
                    scratch.baseAddress?.advanced(by: offset + frame).initialize(to: value)
                }
            }
        }
        return nil
    }

    private func compute(
        frames: Int, scratch: UnsafeMutableBufferPointer<Float>
    ) -> AudioRoutingProcessRefusal? {
        let stride = plan.layout.maxFrames
        for channel in 0..<plan.rows.count {
            let row = plan.rows[channel]
            let offset = plan.outputScratchOffset + channel * stride
            var peak: Float = 0
            for frame in 0..<frames {
                var sample: Float = 0
                if row.isIdentity {
                    sample = scratch[plan.terms[row.firstTerm] + frame]
                } else {
                    for term in row.firstTerm..<(row.firstTerm + row.termCount) {
                        // Float32, declared order, duplicates preserved. Check each
                        // intermediate sum, not just the final result; never widen.
                        sample += scratch[plan.terms[term] + frame]
                        guard sample.isFinite else { return .nonFiniteSum }
                    }
                }
                peak = max(peak, abs(sample))
                scratch.baseAddress?.advanced(by: offset + frame).initialize(to: sample)
            }
            scratch.baseAddress?.advanced(by: plan.peakScratchOffset + channel).initialize(to: peak)
        }
        return nil
    }

    private func commit(
        frames: Int, scratch: UnsafeMutableBufferPointer<Float>,
        output: UnsafeMutableBufferPointer<Float>, peaks: UnsafeMutableBufferPointer<Float>
    ) {
        for channel in 0..<plan.layout.peakCount {
            let offset = channel * plan.layout.maxFrames
            for frame in 0..<frames {
                output[offset + frame] = scratch[plan.outputScratchOffset + offset + frame]
            }
            peaks[channel] = scratch[plan.peakScratchOffset + channel]
        }
    }

    private func silence(
        frames: Int, output: UnsafeMutableBufferPointer<Float>, peaks: UnsafeMutableBufferPointer<Float>
    ) {
        for channel in 0..<plan.layout.peakCount {
            let offset = channel * plan.layout.maxFrames
            for frame in 0..<frames { output[offset + frame] = 0 }
            peaks[channel] = 0
        }
    }
}

@available(*, unavailable)
extension OfflineAudioRoutingProcessor: Sendable {}

/// Checked half-open byte interval; empty slabs never overlap.
private struct AudioRoutingByteInterval {
    let start: UInt
    let end: UInt

    init?(base: UnsafePointer<Float>?, count: Int) {
        guard count >= 0 else { return nil }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard !overflow else { return nil }
        guard let base else {
            guard count == 0 else { return nil }
            start = 0
            end = 0
            return
        }
        let address = UInt(bitPattern: base)
        guard address % UInt(MemoryLayout<Float>.alignment) == 0 else { return nil }
        let (limit, wraps) = address.addingReportingOverflow(UInt(bytes))
        guard !wraps else { return nil }
        start = address
        end = limit
    }

    func overlaps(_ other: Self) -> Bool {
        start != end && other.start != other.end && start < other.end && other.start < end
    }
}
