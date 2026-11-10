/// The musical context of one AU render block: tempo, beat position and the transport-moving flag, bound to the sample
/// rate and the capability generation it was built for.
///
/// Tempo is exact integer microseconds per quarter note (BPM is 60,000,000 divided by it) and the beat position is
/// exact ticks of `MusicalTime.ticksPerQuarter`; the conversion to the `Double`s of an AU block belongs to the hosted
/// bridge. There is no time signature, measure, loop or cycle position here. A rate change is a refusal, not a rebase.
///
/// Pure: the value is built only by `make`, which reads the summary it is given and nothing else. It runs on the
/// control thread and makes no real-time or allocation-free claim. Equality is synthesized over integers, a `Bool`
/// and `CapabilityGeneration`; no text is stored.
struct AUHostContext: Hashable, Sendable {
    /// Tempo of the segment that holds `beatPositionTicks`.
    let microsPerQuarter: Int64
    /// Position in ticks, at least 0, `MusicalTime.ticksPerQuarter` per quarter note.
    let beatPositionTicks: Int64
    let isTransportMoving: Bool
    let sampleRateHz: Int
    let blockStartFrame: Int64
    let blockFrames: Int
    /// The live generation the context was bound to.
    let generation: CapabilityGeneration

    /// Whole quarter notes before `beatPositionTicks`.
    var quarterNotes: Int64 { beatPositionTicks / MusicalTime.ticksPerQuarter }
    /// Ticks past the last whole quarter note.
    var ticksIntoQuarter: Int64 { beatPositionTicks % MusicalTime.ticksPerQuarter }

    private init(
        microsPerQuarter: Int64, beatPositionTicks: Int64, isTransportMoving: Bool, sampleRateHz: Int,
        blockStartFrame: Int64, blockFrames: Int, generation: CapabilityGeneration
    ) {
        self.microsPerQuarter = microsPerQuarter
        self.beatPositionTicks = beatPositionTicks
        self.isTransportMoving = isTransportMoving
        self.sampleRateHz = sampleRateHz
        self.blockStartFrame = blockStartFrame
        self.blockFrames = blockFrames
        self.generation = generation
    }

    /// Builds the context of the block `[blockStartFrame, blockStartFrame + blockFrames)` from `summary`.
    ///
    /// The first failure wins, in the order of `AUHostContextRefusal`: block, negotiation staleness (resources or
    /// sampleRate), rate, loop, frame, then the position. A running transport reports the position of the block's first
    /// frame, extrapolated from the summary's anchor; a stopped transport reports the held anchor position and ignores
    /// the frame. The tempo is that of the segment holding the rounded position (at a boundary tick, the new segment).
    /// The caller passes a summary it has just read from `SchedulerMusicalState`: its freshness is not checked here.
    static func make(
        _ summary: SchedulerMusicalSummary, negotiated: NegotiatedRender, live: CapabilityGeneration,
        blockStartFrame: Int64, blockFrames: Int
    ) throws(AUHostContextRefusal) -> AUHostContext {
        if let fault = refusal(
            summary, negotiated: negotiated, live: live, blockStartFrame: blockStartFrame, blockFrames: blockFrames) {
            throw fault
        }
        let ticks = try position(summary, atFrame: blockStartFrame)
        guard let segment = summary.clock.map.segments.last(where: { $0.atTicks <= ticks }) else {
            throw .beforeMusicalOrigin(ticks: ticks)
        }
        return AUHostContext(
            microsPerQuarter: segment.microsPerQuarter, beatPositionTicks: ticks,
            isTransportMoving: summary.isRunning, sampleRateHz: negotiated.spec.sampleRateHz,
            blockStartFrame: blockStartFrame, blockFrames: blockFrames, generation: live)
    }

    /// Throws `.contextStale` with the `resources` and `sampleRate` axes where the context's generation differs from
    /// `live`, in `CapabilityAxis.allCases` order. A latency difference leaves the context valid: musical context does
    /// not depend on latency.
    func validate(against live: CapabilityGeneration) throws(AUHostContextRefusal) {
        let stale = generation.staleAxes(comparedTo: live).filter { $0 != .latency }
        guard stale.isEmpty else { throw .contextStale(stale) }
    }

    private static func refusal(
        _ summary: SchedulerMusicalSummary, negotiated: NegotiatedRender, live: CapabilityGeneration,
        blockStartFrame: Int64, blockFrames: Int
    ) -> AUHostContextRefusal? {
        guard blockFrames >= 1 else { return .invalidBlock(blockFrames) }
        let maximum = negotiated.spec.maximumFrames
        guard blockFrames <= maximum else {
            return .blockExceedsNegotiated(blockFrames: blockFrames, maximumFrames: maximum)
        }
        let stale = negotiated.generation.staleAxes(comparedTo: live).filter { $0 != .latency }
        guard stale.isEmpty else { return .negotiationStale(stale) }
        let summaryHz = summary.clock.nominalRate
        let negotiatedHz = negotiated.spec.sampleRateHz
        guard summaryHz == negotiatedHz else { return .rateMismatch(summaryHz: summaryHz, negotiatedHz: negotiatedHz) }
        guard summary.loop == nil else { return .loopActive }
        guard blockStartFrame >= 0 else { return .negativeFrame(blockStartFrame) }
        return nil
    }

    private static func position(
        _ summary: SchedulerMusicalSummary, atFrame frame: Int64
    ) throws(AUHostContextRefusal) -> Int64 {
        let ticks: Int64
        if summary.isRunning {
            do {
                ticks = try summary.clock.ticks(atFrame: frame)
            } catch {
                throw .ticksOverflow
            }
        } else {
            ticks = summary.clock.musical.ticks
        }
        guard ticks >= 0 else { throw .beforeMusicalOrigin(ticks: ticks) }
        return ticks
    }
}
