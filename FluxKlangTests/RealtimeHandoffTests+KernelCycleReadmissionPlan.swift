import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #364 E5c, slice KCR2: planning rules of the re-admission (`KernelCarryReadmission.init`) that no existing
// re-admission test fully pinned (`readmissionKeepsNegativeDurationRampsAsJumpsAndSkipsNonFinite` covers part of the
// invalid-ramp rule): supersede keys, invalid ramps, the overflow bound, the cut by kind and the recorded order on a
// frame tie.

private func control(_ controller: UInt8, _ value: UInt32 = 9) -> KernelEventPayload {
    .control(channel: 0, controller: controller, value: value)
}

private func program(_ channel: UInt8, _ program: UInt8, bank: UInt16 = 0) -> KernelEventPayload {
    .program(channel: channel, program: program, bank: bank)
}

private func ramp(_ parameter: UInt32, _ value: Float, _ duration: Int64 = 0) -> KernelEventPayload {
    .rampTo(parameter: parameter, value: value, durationFrames: duration)
}

/// A `.replacingCycle` cycle of `blockCapacity` on `rig`'s parts; the caller retires the previous cycle first.
private func replacement(of rig: CycleRig, blockCapacity: Int = 64, perLaneQuota: Int = 64) throws -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
    return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                           blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
}

/// Pushes `pending` through `token`, runs `rig.cycle` over [0, 64) so they stay buffered, and retires it.
private func retire(_ rig: CycleRig, _ token: ProducerToken, pending: [KernelEvent]) {
    for event in pending { #expect(rig.push(event, token) == .ok) }
    #expect(rig.run(0, 64).0.pending == pending.count)
    _ = rig.cycle.retire()
}

/// Every emission of one block of `cycle` over `[start, start + 64)`.
private func block(_ cycle: KernelCycle, _ start: Int64) -> [CycleEmission] {
    var emitted: [CycleEmission] = []
    _ = cycle.run(blockStart: start, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return emitted
}

/// `events`, each emitted at its own frame.
private func emissions(_ events: [KernelEvent]) -> [CycleEmission] {
    events.map { CycleEmission(event: $0, frame: $0.frame) }
}

private func stateful(_ loss: KernelRetirementLoss) -> [Int] { [loss.controls, loss.programs, loss.ramps] }

private let programFive = KernelEventPayload.program(channel: 0, program: 5, bank: 0)

private func at(_ frame: Int64, _ payload: KernelEventPayload) -> CycleEmission {
    CycleEmission(event: cycleEvent(frame, payload), frame: frame)
}

extension RealtimeHandoffTests.CycleCarryReadmissionBounds {
    /// Acceptance (b), lock half (a source scan, not a proof): the render-side bodies contain no lock, queue,
    /// planner, `events` or array-mutating token.
    @Test(.enabled(if: Self.sourcesAreReachable, "the kernel sources are not next to the tests"))
    func readmissionRenderSourcesHaveNoLockOrArrayToken() throws {
        let directory = try #require(Self.eventsDirectory())
        let bodies: [(String, String)] = [
            ("KernelBlockDecider.swift", "private func readmit("),
            ("KernelCarryReadmission.swift", "var next: KernelEvent?"),
            ("KernelCarryReadmission.swift", "func consumeNext("),
            ("KernelCarryReadmission.swift", "func supersede("),
            ("KernelCarryReadmission.swift", "func retire(coveredBy"),
            ("KernelCarryReadmission.swift", "func discard("),
            ("KernelCarryReadmission.swift", "func leavePending("),
            ("KernelCarryReadmission.swift", "func covered("),
            ("KernelCarryReadmission.swift", "func statefulKinds("),
            ("KernelCarryReadmission.swift", "private func resolve(")
        ]
        let banned = ["Mutex", "withLock", "_lock", "NSLock", "pthread_", "Dispatch", "plan(", ".events",
                      "Array", "[KernelEvent]"]
        for (file, declaration) in bodies {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let body = try #require(KernelRetirementCarryTests.functionBody(declaration, in: text))
            #expect(KernelRetirementCarryTests.arrayMutations(in: body).isEmpty, "\(declaration)")
            #expect(banned.filter { body.contains($0) }.isEmpty, "\(declaration)")
        }
    }

    private static func eventsDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Audio/Kernel/Events", "../../Sources/FluxKlang/Shared/Audio/Kernel/Events"]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("KernelCycle.swift").path) }
    }

    private static let sourcesAreReachable = eventsDirectory() != nil
}

extension RealtimeHandoffTests.CycleRetirementCarryHandoff {
    /// The body of `func retire(` in `KernelCycle.swift` records through `carry.record(` and mentions no array
    /// growth, `events` getter, planner or lock token. A source scan, not an allocation proof.
    @Test(.enabled(if: Self.sourcesAreReachable, "the kernel sources are not next to the tests"))
    func retirementCarryHandoffRetireSourceHasNoArrayOrLockToken() throws {
        let directory = try #require(Self.eventsDirectory())
        let text = try String(contentsOf: directory.appendingPathComponent("KernelCycle.swift"), encoding: .utf8)
        let body = try #require(KernelRetirementCarryTests.functionBody("func retire(", in: text))
        #expect(body.contains("carry.record("))
        #expect(KernelRetirementCarryTests.arrayMutations(in: body).isEmpty)
        let banned = [".events", "Mutex", ".lock", "lock()", "plan("]
        #expect(banned.filter { body.contains($0) }.isEmpty)
    }

    private static func eventsDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Audio/Kernel/Events", "../../Sources/FluxKlang/Shared/Audio/Kernel/Events"]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("KernelCycle.swift").path) }
    }

    private static let sourcesAreReachable = eventsDirectory() != nil
}

extension RealtimeHandoffTests.CycleCarryReadmission {
    /// Negative frames keep their original value through planning: during a replacement block over [-128, -64)
    /// a carried `control` at -100, the later of two carried `program`s on channel 0 (-90) and a carried ramp at
    /// -70 are emitted at their own frames, before an own same-channel `program` at -80 where earlier, and the
    /// carried `program` at -110 is superseded inside the carry. Kills: carried frames clamped to 0 (emitted late,
    /// after newer own state); the carry's own supersession done on clamped frames.
    @Test func readmissionKeepsNegativeFramesThroughPlanning() throws {
        let rig = try CycleRig(laneCapacity: 32)
        let token = try #require(rig.events.claimProducer())
        let programSix = KernelEventPayload.program(channel: 0, program: 6, bank: 0)
        let carried: [(Int64, KernelEventPayload)] = [(-110, programFive), (-100, control(7)), (-90, programSix),
                                                      (-70, ramp(1, 1))]
        for (frame, payload) in carried { #expect(rig.push(cycleEvent(frame, payload), token) == .ok) }
        #expect(rig.cycle.run(blockStart: -256, frames: 64) { _, _ in }.pending == 4)
        #expect(rig.cycle.retire().stateful == 4)
        let next = try replacement(of: rig)
        let programNine = KernelEventPayload.program(channel: 0, program: 9, bank: 0)
        #expect(rig.push(cycleEvent(-80, programNine), token) == .ok)
        #expect(block(next, -128) == [at(-100, control(7)), at(-90, programSix), at(-80, programNine),
                                    at(-70, ramp(1, 1))])
        let report = next.carryReadmissionReport
        #expect(report.planned == 3 && report.superseded == 1 && report.delivered == 3)
        #expect(next.unresolvedRetirementLoss == KernelRetirementLoss() && next.parameterValue(1) == 1)
    }

    /// Negative frames at the replacement's `retire()`: an own pending `program` at -80 covers the carried one at
    /// -100 (superseded, not carried again). Kills: a carried frame clamped to 0, so no longer covered.
    @Test func readmissionRetireCoversNegativeCarriedFrames() throws {
        let rig = try CycleRig(laneCapacity: 32)
        let token = try #require(rig.events.claimProducer())
        #expect(rig.push(cycleEvent(-100, programFive), token) == .ok)
        #expect(rig.cycle.run(blockStart: -256, frames: 64) { _, _ in }.pending == 1)
        _ = rig.cycle.retire()
        let next = try replacement(of: rig)
        #expect(rig.push(cycleEvent(-80, .program(channel: 0, program: 9, bank: 0)), token) == .ok)
        #expect(block(next, -256).isEmpty)
        #expect(next.retire().programs == 1)
        let report = next.carryReadmissionReport
        #expect(report.supersededByReplacement == 1 && report.recarried == 0)
        #expect(try replacement(of: rig).inheritedRetirementCarry.count == 1)
    }

    /// Same-frame carried ramps on parameter 2 from producer 0 (scope 0, sequence 9, to 1) and producer 1
    /// (scope 1, sequence 0, to 0.25) re-admit in the retiring buffer's order (producer lane before sequence), so
    /// 0.25 is the parameter's state. Kills: ties re-ordered by sequence during planning.
    @Test func readmissionKeepsTheRetiringBuffersTieOrderAcrossProducers() throws {
        let rig = try CycleRig(laneCapacity: 32)
        let first = try #require(rig.events.claimProducer())
        let second = try #require(rig.events.claimProducer())
        let early = cycleEvent(100, ramp(2, 1), sequence: 9)
        let late = cycleEvent(100, ramp(2, 0.25), scope: 1, sequence: 0)
        #expect(rig.push(early, first) == .ok && rig.push(late, second) == .ok)
        #expect(rig.run(0, 64).0.pending == 2)
        #expect(rig.cycle.retire().ramps == 2)
        let next = try replacement(of: rig)
        #expect(next.inheritedRetirementCarry.events == [early, late])
        let emitted = [CycleEmission(event: early, frame: 100), CycleEmission(event: late, frame: 100)]
        #expect(block(next, 64) == emitted)
        #expect(next.parameterValue(2) == 0.25)
    }

    /// Capacity selection keeps the retiring buffer's tie order: with `blockCapacity` 1, of two frame-100
    /// `control`s from producer 0 (sequence 9) and producer 1 (sequence 0), producer 0's is kept and producer 1's
    /// is `cut`. Kills: the cut chosen by sequence.
    @Test func readmissionCapacityCutKeepsTheFirstInBufferOrder() throws {
        let rig = try CycleRig(laneCapacity: 32)
        let first = try #require(rig.events.claimProducer())
        let second = try #require(rig.events.claimProducer())
        let kept = cycleEvent(100, control(7), sequence: 9)
        #expect(rig.push(kept, first) == .ok && rig.push(cycleEvent(100, control(8), scope: 1), second) == .ok)
        #expect(rig.run(0, 64).0.pending == 2)
        _ = rig.cycle.retire()
        let next = try replacement(of: rig, blockCapacity: 1, perLaneQuota: 1)
        #expect(block(next, 64) == [CycleEmission(event: kept, frame: 100)])
        let report = next.carryReadmissionReport
        #expect(report.planned == 1 && report.cut.controls == 1)
        #expect(stateful(next.unresolvedRetirementLoss) == [1, 0, 0])
    }

    /// Negative frames across two hops: a carried `program` at -100 the replacement (no own events) never reaches
    /// is carried again at -100, as re-carried (`ownCount` 0), and the third cycle emits it there, in a block over
    /// [-128, -64). Kills: a re-carried frame clamped or shifted.
    @Test func readmissionKeepsNegativeFramesAcrossTwoHops() throws {
        let rig = try CycleRig()
        let token = try #require(rig.events.claimProducer())
        #expect(rig.push(cycleEvent(-100, programFive), token) == .ok)
        #expect(rig.cycle.run(blockStart: -256, frames: 64) { _, _ in }.pending == 1)
        _ = rig.cycle.retire()
        let next = try replacement(of: rig)
        #expect(block(next, -256).isEmpty)
        #expect(next.retire().programs == 1 && next.carryReadmissionReport.recarried == 1)
        let third = try replacement(of: rig)
        #expect(third.inheritedRetirementCarry.events == [cycleEvent(-100, programFive)])
        #expect(third.inheritedRetirementCarry.ownCount == 0)
        #expect(block(third, -128) == [at(-100, programFive)])
        #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
    }

    /// Cross-hop tie order: a carried CC0 bank select and an own `program` on channel 0, both at 5,000 (different
    /// targets, so neither covers the other), are pending at the replacement's `retire()`, which records the own
    /// one first; the third cycle still emits the bank select first, as the replacement's merge would have
    /// (carried before own on a tie). Kills: re-carried events ordered after own ones by recorded index.
    @Test func readmissionKeepsCarriedBeforeOwnOnATieAcrossTwoHops() throws {
        let rig = try CycleRig()
        let token = try #require(rig.events.claimProducer())
        let bankSelect = control(0, 1)
        retire(rig, token, pending: [cycleEvent(5_000, bankSelect)])
        let next = try replacement(of: rig)
        #expect(rig.push(cycleEvent(5_000, programFive), token) == .ok)
        #expect(block(next, 64).isEmpty)
        #expect(next.retire().stateful == 2 && next.carryReadmissionReport.recarried == 1)
        let third = try replacement(of: rig)
        let carry = third.inheritedRetirementCarry
        #expect(carry.events == [cycleEvent(5_000, programFive), cycleEvent(5_000, bankSelect)])
        #expect(carry.ownCount == 1)
        #expect(block(third, 4_992) == [at(5_000, bankSelect), at(5_000, programFive)])
        #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
    }
}

extension RealtimeHandoffTests {
    /// How a replacement plans the carry it inherited, before render drains it (the preparation rules on
    /// `KernelCarryReadmission`).
    struct CycleCarryReadmissionPlan {
        /// Programs supersede per (scope, channel), whatever the program and bank: the scope-0 channel-0 `program`
        /// at 100 is replaced by the one at 120 (program 7, bank 8), while the channel-1 one and the scope-1
        /// channel-0 one are kept; the replaced one resolves with its survivor. Kills: the program or bank in the
        /// key; the scope or channel left out of it.
        @Test func readmissionSupersedesProgramsPerScopeAndChannel() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let pending = [cycleEvent(100, program(0, 1, bank: 1)), cycleEvent(110, program(1, 9, bank: 9)),
                           cycleEvent(120, program(0, 7, bank: 8)), cycleEvent(125, program(0, 2, bank: 2), scope: 1)]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planned == 3 && report.superseded == 1)
            #expect(block(next, 64) == emissions(Array(pending.dropFirst())))
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Ramps supersede per parameter, whatever the value and duration, and no kind supersedes another: all in
        /// scope 0, the ramp on parameter 1 at 110 replaces the one at 100, while the ramp on parameter 2, a CC0 and a
        /// channel-0 `program` and a ramp on parameter 0 (each keyed by number 0 where it has one) are all kept.
        /// The scope half of the (scope, parameter) key is pinned by
        /// `readmissionCrossScopeRampsOnOneParameterApplyInFrameOrder`, not here.
        /// Kills: the parameter left out of a ramp's key; keys of different kinds colliding.
        @Test func readmissionSupersedesRampsPerParameterAndNeverAcrossKinds() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let pending = [cycleEvent(100, ramp(1, 1, 5)), cycleEvent(105, ramp(2, 0.5, 6)),
                           cycleEvent(110, ramp(1, 0.25, 7)), cycleEvent(115, control(0)),
                           cycleEvent(120, program(0, 5)), cycleEvent(125, ramp(0, 0.75))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planned == 5 && report.superseded == 1)
            #expect(block(next, 64) == emissions(Array(pending.dropFirst())))
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Every invalid carried ramp (NaN, ±infinity) is removed before supersession and the overflow check: a later
        /// invalid ramp does not replace a valid one (parameters 0 and 2), an earlier one adds no weight to the valid
        /// one after it (parameter 1, so it stays unresolved), and an invalid ramp whose completion would overflow
        /// `Int64` does not refuse the plan. The largest finite values and a zero duration are valid, and so is a
        /// negative duration down to `Int64.min` (#718: a jump), so parameter 3's one at 122 is superseded by the one
        /// at 124 and resolves with it. Kills: only NaN treated as invalid; a negative duration treated as invalid;
        /// invalid ramps superseding or superseded; the overflow checked before the removal.
        @Test func readmissionRemovesEveryInvalidRampBeforePlanning() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let valid = [cycleEvent(100, ramp(0, 0.5)), cycleEvent(115, ramp(1, 0.25)),
                         cycleEvent(120, ramp(2, .greatestFiniteMagnitude, 1)),
                         cycleEvent(124, ramp(3, -.greatestFiniteMagnitude, 1))]
            let pending = [valid[0], cycleEvent(105, ramp(0, .infinity)), cycleEvent(110, ramp(1, .nan)), valid[1],
                           valid[2], cycleEvent(122, ramp(3, 1, Int64.min)), valid[3],
                           cycleEvent(126, ramp(2, -.infinity)), cycleEvent(Int64.max - 10, ramp(2, .nan, 100))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            let report = next.carryReadmissionReport
            #expect(report.planRefusal == nil && report.invalidRamps == 4)
            #expect(report.planned == 4 && report.superseded == 1)
            #expect(block(next, 64) == emissions(valid))
            #expect(next.carryReadmissionReport.refused == 0)
            #expect(stateful(next.unresolvedRetirementLoss) == [0, 0, 4])
        }

        /// #718 one ramp rule across a replacement: carried ramps with a finite negative duration (-5 and
        /// `Int64.min`) are planned, not invalid, keep their payload and frame, and jump to their targets in the first
        /// block; once delivered nothing is unresolved, so the replacement asks for no receiver resync. Kills: a
        /// negative duration dropped as invalid (unresolved loss, stale receiver); its duration rewritten.
        @Test func readmissionCarriesNegativeDurationRampsAsJumpsWithoutResync() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            let pending = [cycleEvent(100, ramp(1, 0.75, -5)), cycleEvent(110, ramp(2, -0.5, Int64.min))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            #expect(next.inheritedRetirementLoss.ramps == 2 && next.unresolvedRetirementLoss.receiverStateMayBeStale)
            let report = next.carryReadmissionReport
            #expect(report.planRefusal == nil && report.invalidRamps == 0 && report.planned == 2)
            #expect(block(next, 64) == emissions(pending))
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
            #expect(!next.unresolvedRetirementLoss.receiverStateMayBeStale)
            #expect(next.parameterValue(1) == 0.75 && next.parameterValue(2) == -0.5 && rig.ramps.activeCount == 0)
        }

        /// A negative duration counts as 0 in the overflow check (#718: a jump completes at its own frame): a carried
        /// ramp at `Int64.min + 5` lasting -10 frames is planned, not refused `.frameOverflow`. Built directly from a
        /// carry, since a cycle never leaves such a frame pending. Kills: the raw negative duration added.
        @Test func readmissionOverflowCheckTreatsNegativeDurationAsAJump() {
            var carry = KernelRetirementCarry()
            let event = KernelEvent(frame: .min + 5, scope: 0, sequence: 0, payload: ramp(1, 1, -10))
            #expect(carry.record(event) == .stored)
            let report = KernelCarryReadmission(carry: carry, blockCapacity: 64).report
            #expect(report.planRefusal == nil && report.planned == 1 && report.invalidRamps == 0)
            #expect(report.cut == KernelRetirementLoss())
        }

        /// The overflow refusal is exact: a carried ramp at `Int64.max - 10` lasting 10 frames completes at
        /// `Int64.max` and is planned; lasting 11 frames it refuses the plan (`.frameOverflow`), so nothing is
        /// planned. Kills: an off-by-one completion bound.
        @Test func readmissionRefusesOnlyARampCompletionPastInt64Max() throws {
            for (duration, refused) in [(Int64(10), false), (11, true)] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: [cycleEvent(Int64.max - 10, ramp(1, 1, duration))])
                let report = try replacement(of: rig).carryReadmissionReport
                let expected: KernelCarryRefusal? = refused ? .frameOverflow : nil
                #expect(report.planRefusal == expected && report.planned == (refused ? 0 : 1), "duration \(duration)")
            }
        }

        /// The capacity cut keeps the earliest survivors and counts the rest by kind: a `control`, a `program` and
        /// two ramps fit a 4-event replacement exactly (nothing cut); a 2-event one keeps the `control` and the
        /// `program` and cuts both ramps, which stay unresolved. Kills: an off-by-one capacity; a cut counted as the
        /// wrong kind.
        @Test func readmissionCapacityCutCountsEachKind() throws {
            let pending = [cycleEvent(100, control(7)), cycleEvent(110, program(0, 5)), cycleEvent(120, ramp(1, 1)),
                           cycleEvent(125, ramp(2, 0.5))]
            for capacity in [4, 2] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: pending)
                let next = try replacement(of: rig, blockCapacity: capacity)
                let report = next.carryReadmissionReport
                #expect(report.planned == capacity && stateful(report.cut) == [0, 0, 4 - capacity])
                #expect(report.cut.stateful == 4 - capacity)
                #expect(block(next, 64) == emissions(Array(pending.prefix(capacity))))
                #expect(stateful(next.unresolvedRetirementLoss) == [0, 0, 4 - capacity])
            }
        }

        /// On a frame tie the re-admission preserves the order the retiring cycle recorded; it does not sort by lane
        /// itself. A `control` (state lane, sequence 9) and a ramp (content lane, sequence 1) at 100, pushed in
        /// either order, are recorded `control` first because that is the retiring buffer's (frame, lane, producer
        /// lane, sequence) order; the re-admission then keeps that recorded order. Kills: ties re-ordered by
        /// sequence; the recorded order reversed on a tie.
        @Test func readmissionKeepsTheRetiringBuffersLaneOrderOnATie() throws {
            let state = cycleEvent(100, control(7), sequence: 9)
            let content = cycleEvent(100, ramp(1, 1), sequence: 1)
            for pending in [[content, state], [state, content]] {
                let rig = try CycleRig()
                let token = try #require(rig.events.claimProducer())
                retire(rig, token, pending: pending)
                let next = try replacement(of: rig)
                #expect(next.inheritedRetirementCarry.events == [state, content])
                #expect(block(next, 64) == emissions([state, content]))
            }
        }
    }
}
