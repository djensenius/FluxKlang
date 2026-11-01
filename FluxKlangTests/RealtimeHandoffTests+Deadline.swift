import Testing
@testable import FluxKlang

// #64 E2: `DeadlinePolicy` (late dispatch, drop and admission) and `ClockPulseGate` (stale skip, rate limit and a
// single resync). Both are render-owned value types with no shared state, so there is no concurrency stress test.

private typealias Root = RealtimeHandoffTests

/// One representative payload per case, covering every lane.
private let allPayloads: [KernelEventPayload] = [
    .noteOff(channel: 0, note: 60),
    .clockPulse,
    .control(channel: 1, controller: 7, value: 100),
    .program(channel: 2, program: 5, bank: 1),
    .noteOn(channel: 3, note: 64, velocity: 100),
    .rampTo(parameter: 9, value: 0.5, durationFrames: 480)
]

private func event(_ payload: KernelEventPayload, at frame: Int64) -> KernelEvent {
    KernelEvent(frame: frame, scope: 0, sequence: 0, payload: payload)
}

private func deadline(tolerance: Int64, lookahead: Int64) -> DeadlinePolicy? {
    try? DeadlinePolicy(lateTolerance: tolerance, lookahead: lookahead)
}

private func gate(maximum: Int, stale: Int64, skipped: UInt64 = 0) -> ClockPulseGate? {
    try? ClockPulseGate(maximumPulsesPerBlock: maximum, staleTolerance: stale, startingSkippedStale: skipped)
}

/// Admits each `(pulseFrame, blockStart)` in order and returns the decisions.
private func feed(_ gate: inout ClockPulseGate, _ pulses: [(Int64, Int64)]) -> [ClockPulseDecision] {
    pulses.map { gate.admit(pulseFrame: $0.0, blockStart: $0.1) }
}

private func isDroppable(_ payload: KernelEventPayload) -> Bool {
    if case .noteOn = payload { return true }
    return false
}

/// Exact reference model in `Int128`: the documented contract with no overflow to reason about.
private func reference(_ policy: DeadlinePolicy, _ event: KernelEvent, start: Int64, frames: Int64)
    -> DeadlineDecision {
    let frame = Int128(event.frame), begin = Int128(start)
    if frame >= begin {
        return frame < begin + Int128(max(frames, 0)) ? .dispatch(atFrame: event.frame) : .notYet
    }
    let late = begin - frame
    return isDroppable(event.payload) && late > Int128(policy.lateTolerance) ? .dropLate
        : .dispatchLate(atFrame: start)
}

private func referenceAdmit(_ policy: DeadlinePolicy, frame: Int64, now: Int64, last: Int64?) -> KernelStatus {
    if Int128(frame) > Int128(now) + Int128(policy.lookahead) { return .refused(.beyondLookahead) }
    if let last, frame < last { return .refused(.nonMonotonic) }
    return .ok
}

/// Deterministic SplitMix64.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value &>> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value &>> 31)
    }

    /// Mostly values near `pivot` or the extremes, so boundaries are hit often.
    mutating func frame(near pivot: Int64) -> Int64 {
        switch next() % 4 {
        case 0: Int64(bitPattern: next())
        case 1: [Int64.min, .min + 1, -1, 0, 1, .max - 1, .max][Int(next() % 7)]
        default: pivot &+ Int64(truncatingIfNeeded: next() % 2_049) &- 1_024
        }
    }
}

extension RealtimeHandoffTests {
    struct Deadlines {
        static let tolerance: Int64 = 10
        static let start: Int64 = 1_000
        static let frames: Int64 = 64

        @Test func initAcceptsBoundedHorizonsAndRejectsTheRest() {
            let maximum = KernelLimits.maximumHorizonFrames
            let accepted: [(Int64, Int64)] = [(0, 1), (0, maximum), (maximum, maximum), (480, 96_000), (5, 5)]
            for (tolerance, lookahead) in accepted {
                let policy = deadline(tolerance: tolerance, lookahead: lookahead)
                #expect(policy?.lateTolerance == tolerance && policy?.lookahead == lookahead)
            }
            let rejected: [(Int64, Int64)] = [(-1, 10), (0, 0), (0, -1), (0, maximum + 1), (11, 10),
                                              (.min, .max), (.max, .max), (.min, .min), (maximum + 1, maximum + 1)]
            for (tolerance, lookahead) in rejected {
                #expect(throws: DeadlinePolicy.PreparationError.horizonOutOfRange(
                    lateTolerance: tolerance, lookahead: lookahead)) {
                    try DeadlinePolicy(lateTolerance: tolerance, lookahead: lookahead)
                }
            }
        }

        @Test func initFromHorizonAndPolicy() throws {
            #expect(throws: DeadlinePolicy.PreparationError.noHorizon) { try DeadlinePolicy(horizon: .none) }
            let fromHorizon = try DeadlinePolicy(horizon: .frames(lateTolerance: 3, lookahead: 9))
            #expect(fromHorizon.lateTolerance == 3 && fromHorizon.lookahead == 9)
            let fromPolicy = try DeadlinePolicy(policy: Root.policy())
            #expect(fromPolicy.lateTolerance == 480 && fromPolicy.lookahead == 96_000)
            #expect(throws: DeadlinePolicy.PreparationError.policy(.violates(.r1SingleConsumer))) {
                try DeadlinePolicy(policy: Root.policy(consumers: 2))
            }
            #expect(throws: DeadlinePolicy.PreparationError.noHorizon) {
                try DeadlinePolicy(policy: Root.telemetryPolicy())
            }
        }

        /// Every lane × {early in block, block start, last frame, next block, late within, at and beyond tolerance}.
        @Test func laneByPositionMatrix() throws {
            let policy = try #require(deadline(tolerance: Self.tolerance, lookahead: 1_000))
            let late = DeadlineDecision.dispatchLate(atFrame: Self.start)
            for payload in allPayloads {
                let rows: [(Int64, DeadlineDecision)] = [
                    (Self.start + 1, .dispatch(atFrame: Self.start + 1)),
                    (Self.start, .dispatch(atFrame: Self.start)),
                    (Self.start + Self.frames - 1, .dispatch(atFrame: Self.start + Self.frames - 1)),
                    (Self.start + Self.frames, .notYet),
                    (Self.start - 1, late),
                    (Self.start - Self.tolerance, late),
                    (Self.start - Self.tolerance - 1, isDroppable(payload) ? .dropLate : late)
                ]
                for (frame, expected) in rows {
                    let decision = policy.decide(event(payload, at: frame), blockStart: Self.start,
                                                 blockFrames: Self.frames)
                    #expect(decision == expected, "\(payload) at \(frame)")
                }
            }
        }

        /// Plan row `lateNoteBeyondToleranceDroppedAndCounted`: this test and `laneByPositionMatrix` assert the drop
        /// one frame beyond tolerance; `decide` is pure, so counting `dropLate` is E5's job
        /// (`KernelCycleResult.droppedLate`).
        @Test func lateNoteWithinToleranceDispatchesAtBlockStart() throws {
            let policy = try #require(deadline(tolerance: 0, lookahead: 1))
            let noteOn = KernelEventPayload.noteOn(channel: 0, note: 1, velocity: 1)
            #expect(policy.decide(event(noteOn, at: 99), blockStart: 100, blockFrames: 1) == .dropLate)
            #expect(policy.decide(event(noteOn, at: 100), blockStart: 100, blockFrames: 1) == .dispatch(atFrame: 100))
            #expect(policy.decide(event(noteOn, at: 101), blockStart: 100, blockFrames: 1) == .notYet)
            let wide = try #require(deadline(tolerance: 1, lookahead: 1))
            #expect(wide.decide(event(noteOn, at: 99), blockStart: 100, blockFrames: 1) == .dispatchLate(atFrame: 100))
        }

        @Test func lateReleaseIsNeverDropped() throws {
            let policy = try #require(deadline(tolerance: 0, lookahead: 1))
            let off = KernelEventPayload.noteOff(channel: 15, note: 127)
            let starts: [Int64] = [.min + 1, -1, 0, 1, 1_000, .max - 1, .max]
            for start in starts {
                for frames in [Int64.min, -1, 0, 1, 64, .max] {
                    for frame in [Int64.min, start &- 1, start / 2 &- 1] where frame < start {
                        let decision = policy.decide(event(off, at: frame), blockStart: start, blockFrames: frames)
                        #expect(decision == .dispatchLate(atFrame: start), "\(frame) \(start) \(frames)")
                    }
                }
            }
        }

        /// Trap-free guard only: E5 never calls `decide` when `frames <= 0` (see "Empty cycles" on `DeadlinePolicy`).
        @Test func emptyBlockHasNoInBlockFramesGuardIsDefined() throws {
            let policy = try #require(deadline(tolerance: Self.tolerance, lookahead: 1_000))
            for frames in [Int64.min, -1, 0] {
                for payload in allPayloads {
                    #expect(policy.decide(event(payload, at: Self.start), blockStart: Self.start,
                                          blockFrames: frames) == .notYet)
                    #expect(policy.decide(event(payload, at: Self.start - 1), blockStart: Self.start,
                                          blockFrames: frames) == .dispatchLate(atFrame: Self.start))
                    let beyond = policy.decide(event(payload, at: Self.start - Self.tolerance - 1),
                                               blockStart: Self.start, blockFrames: frames)
                    #expect(beyond == (isDroppable(payload) ? .dropLate : .dispatchLate(atFrame: Self.start)))
                }
            }
        }

        @Test func extremeFramesDoNotTrap() throws {
            let policy = try #require(deadline(tolerance: Self.tolerance, lookahead: 1_000))
            let noteOn = KernelEventPayload.noteOn(channel: 0, note: 0, velocity: 0)
            let noteOff = KernelEventPayload.noteOff(channel: 0, note: 0)
            // A block near `.max` reaches `.max` exactly; its end is never computed, so nothing overflows.
            #expect(policy.decide(event(noteOn, at: .max), blockStart: .max - 1, blockFrames: 64)
                == .dispatch(atFrame: .max))
            #expect(policy.decide(event(noteOn, at: .max), blockStart: .max, blockFrames: .max)
                == .dispatch(atFrame: .max))
            #expect(policy.decide(event(noteOn, at: .max), blockStart: .min, blockFrames: .max) == .notYet)
            // `[.min, .min + .max)` is `[.min, -1)`.
            #expect(policy.decide(event(noteOn, at: -2), blockStart: .min, blockFrames: .max) == .dispatch(atFrame: -2))
            #expect(policy.decide(event(noteOn, at: -1), blockStart: .min, blockFrames: .max) == .notYet)
            // Lateness of 2^64 − 1 frames.
            #expect(policy.decide(event(noteOn, at: .min), blockStart: .max, blockFrames: 1) == .dropLate)
            #expect(policy.decide(event(noteOff, at: .min), blockStart: .max, blockFrames: 1)
                == .dispatchLate(atFrame: .max))
            let values: [Int64] = Root.adversarialFrames + [.min + 1, .max - 1, -Self.tolerance - 1]
            for payload in allPayloads {
                for frame in values {
                    for start in values {
                        for frames in values {
                            let decision = policy.decide(event(payload, at: frame), blockStart: start,
                                                         blockFrames: frames)
                            #expect(decision == reference(policy, event(payload, at: frame), start: start,
                                                          frames: frames))
                        }
                    }
                }
            }
        }

        @Test func decisionsMatchReferenceModelOnSeededRandomInputs() throws {
            var random = SplitMix(state: 0x64E2)
            let tolerances: [Int64] = [0, 1, 10, KernelLimits.maximumHorizonFrames]
            for tolerance in tolerances {
                let policy = try #require(deadline(tolerance: tolerance, lookahead: KernelLimits.maximumHorizonFrames))
                for _ in 0..<5_000 {
                    let start = random.frame(near: 0)
                    let frames = random.frame(near: 64)
                    let payload = allPayloads[Int(random.next() % UInt64(allPayloads.count))]
                    let candidate = event(payload, at: random.frame(near: start &- tolerance))
                    let decision = policy.decide(candidate, blockStart: start, blockFrames: frames)
                    #expect(decision == reference(policy, candidate, start: start, frames: frames))
                    let now = random.frame(near: candidate.frame &- policy.lookahead)
                    let last: Int64? = random.next() % 3 == 0 ? nil : random.frame(near: candidate.frame)
                    #expect(policy.admit(eventFrame: candidate.frame, now: now, lastAdmittedFrame: last)
                        == referenceAdmit(policy, frame: candidate.frame, now: now, last: last))
                }
            }
        }

        /// Stuck-note trap: a `noteOn` at 990 and its `noteOff` at 999 both collapse to `dispatchLate(1000)`.
        /// Applied in original-frame order the note is released; re-sorting by decided frame then lane (release
        /// first) would apply the `noteOff` first and leave the note owned.
        @Test func collapsedLateEventsAppliedInOriginalFrameOrderReleaseTheNote() throws {
            let policy = try #require(deadline(tolerance: Self.tolerance, lookahead: 1_000))
            let owner = try NoteOwnership(scopes: 1)
            let noteOn = event(.noteOn(channel: 2, note: 64, velocity: 90), at: 990)
            let noteOff = event(.noteOff(channel: 2, note: 64), at: 999)
            let ordered = [noteOff, noteOn].sorted { ($0.frame, $0.lane) < ($1.frame, $1.lane) }
            #expect(ordered == [noteOn, noteOff])
            for candidate in ordered {
                let decision = policy.decide(candidate, blockStart: Self.start, blockFrames: Self.frames)
                #expect(decision == .dispatchLate(atFrame: Self.start))
                switch candidate.payload {
                case .noteOn(let channel, let note, _):
                    #expect(owner.noteOn(scope: 0, channel: channel, note: note) == .ok)
                case .noteOff(let channel, let note):
                    #expect(owner.noteOff(scope: 0, channel: channel, note: note))
                default:
                    Issue.record("unexpected payload")
                }
            }
            #expect(!owner.isOwned(scope: 0, channel: 2, note: 64))
            // The trap, for contrast: decided frame then lane puts the release first and strands the note.
            let resorted = ordered.sorted { $0.lane < $1.lane }
            #expect(resorted == [noteOff, noteOn])
            #expect(!owner.noteOff(scope: 0, channel: 2, note: 64))
            #expect(owner.noteOn(scope: 0, channel: 2, note: 64) == .ok)
            #expect(owner.isOwned(scope: 0, channel: 2, note: 64))
        }

        @Test func beyondLookaheadRefusedAtAdmission() throws {
            let policy = try #require(deadline(tolerance: 0, lookahead: 1_000))
            #expect(policy.admit(eventFrame: 2_000, now: 1_000) == .ok)
            #expect(policy.admit(eventFrame: 2_001, now: 1_000) == .refused(.beyondLookahead))
            #expect(policy.admit(eventFrame: 1_000, now: 1_000) == .ok)
            #expect(policy.admit(eventFrame: .min, now: 1_000) == .ok)  // Late: `decide` handles it.
            // Extremes: `now + lookahead` would overflow; the distance is computed exactly instead.
            #expect(policy.admit(eventFrame: .max, now: .max) == .ok)
            #expect(policy.admit(eventFrame: .max, now: .max - 1_000) == .ok)
            #expect(policy.admit(eventFrame: .max, now: .max - 1_001) == .refused(.beyondLookahead))
            #expect(policy.admit(eventFrame: .max, now: .min) == .refused(.beyondLookahead))
            #expect(policy.admit(eventFrame: .min + 1_000, now: .min) == .ok)
            #expect(policy.admit(eventFrame: .min + 1_001, now: .min) == .refused(.beyondLookahead))
            #expect(policy.admit(eventFrame: .min, now: .max) == .ok)
        }

        @Test func nonMonotonicFramePerProducerRefused() throws {
            let policy = try #require(deadline(tolerance: 0, lookahead: 1_000))
            #expect(policy.admit(eventFrame: 499, now: 0, lastAdmittedFrame: 500) == .refused(.nonMonotonic))
            #expect(policy.admit(eventFrame: 500, now: 0, lastAdmittedFrame: 500) == .ok)
            #expect(policy.admit(eventFrame: 501, now: 0, lastAdmittedFrame: 500) == .ok)
            #expect(policy.admit(eventFrame: 499, now: 0, lastAdmittedFrame: nil) == .ok)
            #expect(policy.admit(eventFrame: .min, now: 0, lastAdmittedFrame: .max) == .refused(.nonMonotonic))
            // The horizon is checked first.
            #expect(policy.admit(eventFrame: 5_000, now: 0, lastAdmittedFrame: 6_000) == .refused(.beyondLookahead))
        }
    }

    struct ClockPulses {
        @Test func initAcceptsBoundsAndRejectsTheRest() {
            let limit = ClockPulseGate.maximumPulsesPerBlockLimit
            for maximum in [1, 4, limit] {
                #expect(gate(maximum: maximum, stale: 0)?.maximumPulsesPerBlock == maximum)
            }
            for maximum in [Int.min, -1, 0, limit + 1, .max] {
                #expect(throws: ClockPulseGate.PreparationError.maximumPulsesPerBlockOutOfRange(maximum)) {
                    try ClockPulseGate(maximumPulsesPerBlock: maximum, staleTolerance: 0)
                }
            }
            for stale in [Int64(0), 1, KernelLimits.maximumHorizonFrames] {
                #expect(gate(maximum: 1, stale: stale)?.staleTolerance == stale)
            }
            for stale in [Int64.min, -1, KernelLimits.maximumHorizonFrames + 1, .max] {
                #expect(throws: ClockPulseGate.PreparationError.staleToleranceOutOfRange(stale)) {
                    try ClockPulseGate(maximumPulsesPerBlock: 1, staleTolerance: stale)
                }
            }
            let fresh = gate(maximum: 1, stale: 0)
            #expect(fresh?.skippedStale == 0 && fresh?.rateLimited == 0 && fresh?.resyncPending == false)
        }

        @Test func pulsesRateLimitedPerBlock() throws {
            var pulses = try #require(gate(maximum: 4, stale: 10))
            let decisions = feed(&pulses, (100...105).map { ($0, 100) })
            #expect(decisions == [.emit, .emit, .emit, .emit, .rateLimited, .rateLimited])
            #expect(pulses.rateLimited == 2 && pulses.skippedStale == 0)
            let first = pulses.takeResync(), second = pulses.takeResync()
            #expect(first && !second)
            #expect(pulses.rateLimited == 2 && pulses.skippedStale == 0)  // Taking never touches the counters.
        }

        @Test func perBlockCountResetsOnNewBlockOnly() throws {
            var pulses = try #require(gate(maximum: 2, stale: 10))
            // Any change of `blockStart`, including backwards (a relocation), starts a new block.
            let decisions = feed(&pulses, [(0, 0), (1, 0), (2, 0), (64, 64), (64, 64), (65, 64), (0, 0)])
            #expect(decisions == [.emit, .emit, .rateLimited, .emit, .emit, .rateLimited, .emit])
        }

        @Test func stalePulsesSkippedAndCounted() throws {
            var pulses = try #require(gate(maximum: 4, stale: 10))
            let atTolerance = feed(&pulses, [(990, 1_000)])
            #expect(atTolerance == [.emit] && !pulses.resyncPending && pulses.skippedStale == 0)
            let beyond = feed(&pulses, [(989, 1_000)])
            #expect(beyond == [.skipStale] && pulses.skippedStale == 1 && pulses.resyncPending)
            // Stale pulses do not spend the block's budget: three more emits fit after the first.
            let rest = feed(&pulses, Array(repeating: (1_000, 1_000), count: 4))
            #expect(rest == [.emit, .emit, .emit, .rateLimited])
            var exact = try #require(gate(maximum: 1, stale: 0))
            #expect(feed(&exact, [(100, 100), (99, 100)]) == [.emit, .skipStale])
        }

        @Test func stalePulsesSkippedWithSingleResyncNoBurst() throws {
            var pulses = try #require(gate(maximum: 4, stale: 10))
            let burst = feed(&pulses, (0..<100).map { ($0, 1_000) })
            #expect(burst == Array(repeating: .skipStale, count: 100))
            #expect(pulses.skippedStale == 100 && pulses.rateLimited == 0 && pulses.resyncPending)
            let markers = (0..<100).filter { _ in pulses.takeResync() }.count
            #expect(markers == 1 && !pulses.resyncPending)
            #expect(pulses.skippedStale == 100 && pulses.rateLimited == 0)  // Taking never touches the counters.
            #expect(feed(&pulses, [(1_000, 1_000)]) == [.emit])
            let afterEmit = pulses.takeResync()
            #expect(!afterEmit)
            // Same stall (this block already skipped): no second marker.
            #expect(feed(&pulses, [(0, 1_000)]) == [.skipStale])
            let sameStall = pulses.takeResync()
            #expect(!sameStall && pulses.skippedStale == 101)
            // A clean block re-arms, so the next stall raises exactly one new marker.
            #expect(feed(&pulses, [(2_000, 2_000), (0, 3_000), (1, 3_000)]) == [.emit, .skipStale, .skipStale])
            let again = pulses.takeResync(), drained = pulses.takeResync()
            #expect(again && !drained)
        }

        /// A continuous stale stall across many blocks, taken every block, yields one marker until a clean block.
        @Test func resyncOncePerStaleStallAcrossBlocks() throws {
            var pulses = try #require(gate(maximum: 4, stale: 10))
            var markers = 0
            for block in Int64(1)...50 {
                let start = block * 1_000
                #expect(feed(&pulses, [(start - 500, start), (start, start)]) == [.skipStale, .emit])
                if pulses.takeResync() { markers += 1 }
            }
            #expect(markers == 1 && pulses.skippedStale == 50)
            // Blocks the gate never sees (no pulses) are not clean: a stale pulse after a gap is the same stall.
            #expect(feed(&pulses, [(90_000, 100_000)]) == [.skipStale])
            let afterGap = pulses.takeResync()
            #expect(!afterGap)
            // One clean block, then a new stall: exactly one new marker over many blocks.
            #expect(feed(&pulses, [(101_000, 101_000)]) == [.emit])
            for block in Int64(102)...120 {
                let start = block * 1_000
                _ = feed(&pulses, [(start - 500, start)])
                if pulses.takeResync() { markers += 1 }
            }
            #expect(markers == 2)
        }

        /// Sustained rate limiting across many blocks, taken every block, yields one marker until a clean block.
        @Test func resyncOncePerRateLimitedStallAcrossBlocks() throws {
            var pulses = try #require(gate(maximum: 1, stale: 10))
            var markers = 0
            for block in Int64(0)..<50 {
                #expect(feed(&pulses, [(block * 64, block * 64), (block * 64, block * 64)]) == [.emit, .rateLimited])
                if pulses.takeResync() { markers += 1 }
            }
            #expect(markers == 1 && pulses.rateLimited == 50 && pulses.skippedStale == 0)
            #expect(feed(&pulses, [(3_200, 3_200)]) == [.emit])  // Clean block.
            for block in Int64(51)..<60 {
                _ = feed(&pulses, [(block * 64, block * 64), (block * 64, block * 64)])
                if pulses.takeResync() { markers += 1 }
            }
            #expect(markers == 2)
        }

        /// The pending marker is not lost to a later emit in the same block or to a block change before the take.
        @Test func resyncSurvivesEmitAndBlockChangeUntilTaken() throws {
            var pulses = try #require(gate(maximum: 4, stale: 10))
            #expect(feed(&pulses, [(0, 1_000), (1_000, 1_000), (1_001, 1_000)]) == [.skipStale, .emit, .emit])
            #expect(pulses.resyncPending)
            #expect(feed(&pulses, [(2_000, 2_000)]) == [.emit])
            #expect(pulses.resyncPending)
            let markers = (0..<10).filter { _ in pulses.takeResync() }.count
            #expect(markers == 1 && pulses.skippedStale == 1 && pulses.rateLimited == 0)
        }

        /// Review regression: after a stall's marker is taken, a later skip is the same stall, not a new one, both in
        /// the stalled block and in a following block that has emitted but not yet skipped when the take happens.
        /// Only a completed clean block re-arms; a take never does, whatever the current block has seen so far.
        @Test func skipLaterInSameBlockAfterEmitIsSameStall() throws {
            var pulses = try #require(gate(maximum: 4, stale: 10))
            #expect(feed(&pulses, [(0, 1_000), (1_000, 1_000)]) == [.skipStale, .emit])
            let first = pulses.takeResync()
            #expect(first)
            #expect(feed(&pulses, [(1_001, 1_000), (1, 1_000)]) == [.emit, .skipStale])
            let second = pulses.takeResync()
            #expect(!second && !pulses.resyncPending && pulses.skippedStale == 2)
            #expect(feed(&pulses, [(2_000, 2_000)]) == [.emit])
            let afterFreshEmit = pulses.takeResync()
            #expect(!afterFreshEmit)
            #expect(feed(&pulses, [(1_500, 2_000)]) == [.skipStale])
            let afterLaterSkip = pulses.takeResync()
            #expect(!afterLaterSkip && !pulses.resyncPending && pulses.skippedStale == 3)
        }

        @Test func countersSaturate() throws {
            var pulses = try #require(try? ClockPulseGate(maximumPulsesPerBlock: 1, staleTolerance: 0,
                                                          startingSkippedStale: .max - 1,
                                                          startingRateLimited: .max - 1))
            _ = feed(&pulses, Array(repeating: (.min, .max), count: 3) + Array(repeating: (0, 0), count: 4))
            #expect(pulses.skippedStale == .max && pulses.rateLimited == .max)
        }

        @Test func extremePulsesDoNotTrap() throws {
            let horizon = KernelLimits.maximumHorizonFrames
            var pulses = try #require(gate(maximum: 2, stale: horizon))
            let decisions = feed(&pulses, [(.min, .max), (.max, .min), (.max, .max), (.max - horizon, .max),
                                           (.max - horizon - 1, .max)])
            #expect(decisions == [.skipStale, .emit, .emit, .emit, .skipStale])
            for frame in Root.adversarialFrames {
                for start in Root.adversarialFrames {
                    let decision = pulses.admit(pulseFrame: frame, blockStart: start)
                    let stale = Int128(start) - Int128(frame) > Int128(horizon)
                    #expect((decision == .skipStale) == stale, "\(frame) \(start)")
                }
            }
        }

        @Test func decisionsAreBitwiseCopyable() {
            Root.requireBitwise(DeadlineDecision.self)
            Root.requireBitwise(ClockPulseDecision.self)
            Root.requireBitwise(DeadlinePolicy.self)
            Root.requireBitwise(ClockPulseGate.self)
        }
    }
}
