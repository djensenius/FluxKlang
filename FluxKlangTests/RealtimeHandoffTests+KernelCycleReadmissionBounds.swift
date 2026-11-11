import Darwin
import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #364 E5c, slice KCR1: render-side bounds (allocations, locks) and a Thread Sanitizer stress of the re-admission,
// and the RPN/NRPN data-entry controls the re-admission never coalesces (`KernelEventPayload.isCoalescible`).

private let programFive = KernelEventPayload.program(channel: 0, program: 5, bank: 0)

private func control(_ controller: UInt8, _ value: UInt32 = 9) -> KernelEventPayload {
    .control(channel: 0, controller: controller, value: value)
}

private func ramp(_ parameter: UInt32, _ value: Float, _ duration: Int64) -> KernelEventPayload {
    .rampTo(parameter: parameter, value: value, durationFrames: duration)
}

/// A `.replacingCycle` cycle on `rig`'s parts; the caller retires the previous cycle first.
private func replacement(of rig: CycleRig) throws -> KernelCycle {
    let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership, safety: rig.safety,
                                 ramps: rig.ramps, admissionRefusals: rig.cycle.admissionRefusals)
    return try KernelCycle(parts, pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                           blockCapacity: 64, perLaneQuota: 64)
}

/// Pushes `pending` through `token`, runs `rig.cycle` over [0, 64) so they stay buffered, and retires it.
private func retire(_ rig: CycleRig, _ token: ProducerToken, pending: [(Int64, KernelEventPayload)]) {
    for (frame, payload) in pending { #expect(rig.push(cycleEvent(frame, payload), token) == .ok) }
    #expect(rig.run(0, 64).0.pending == pending.count)
    _ = rig.cycle.retire()
}

private func at(_ frame: Int64, _ payload: KernelEventPayload) -> CycleEmission {
    CycleEmission(event: cycleEvent(frame, payload), frame: frame)
}

/// Every emission of one block of `cycle` over `[start, start + frames)`.
private func block(_ cycle: KernelCycle, _ start: Int64, frames: Int64 = 64) -> [CycleEmission] {
    var emitted: [CycleEmission] = []
    _ = cycle.run(blockStart: start, frames: frames) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return emitted
}

extension RealtimeHandoffTests {
    /// Data-entry controls (6, 38, 96–101, and 121, which deselects the parameter), whose effect depends on order and
    /// count, are never coalesced by the re-admission: each keeps its own slot, order and weight, and no own event
    /// supersedes or covers one.
    struct CycleCarryReadmissionCommands {
        /// The predicate: the RPN/NRPN data-entry family and Reset All Controllers are not coalescible; other controls
        /// (the other channel-mode messages included), programs and ramps are; notes and clock pulses never are.
        /// Kills: a family member coalesced; CC7 kept.
        @Test func readmissionCoalescesAllButDataEntryControls() {
            for controller: UInt8 in [6, 38, 96, 97, 98, 99, 100, 101, 121] {
                #expect(!control(controller).isCoalescible, "CC\(controller)")
            }
            for controller: UInt8 in [0, 5, 7, 37, 39, 64, 95, 102, 120, 122, 123, 127] {
                #expect(control(controller).isCoalescible, "CC\(controller)")
            }
            #expect(programFive.isCoalescible && ramp(1, 1, 64).isCoalescible)
            let others: [KernelEventPayload] = [.noteOn(channel: 0, note: 60, velocity: 100),
                                                .noteOff(channel: 0, note: 60), .clockPulse]
            #expect(others.allSatisfy { !$0.isCoalescible })
        }

        /// Two carried Data Increments (CC96) on one key, at 100 and 200, are both re-admitted, in order, each with
        /// its own weight: one stays unresolved until the second is delivered. Kills: last-writer coalescing (one
        /// increment that resolves both).
        @Test func readmissionKeepsRepeatedDataIncrementsWithTheirOwnWeights() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, control(96, 1)), (200, control(96, 2))])
            let next = try replacement(of: rig)
            #expect(next.carryReadmissionReport.planned == 2 && next.carryReadmissionReport.superseded == 0)
            #expect(block(next, 64) == [at(100, control(96, 1))])
            #expect(next.unresolvedRetirementLoss.controls == 1)
            #expect(block(next, 192) == [at(200, control(96, 2))])
            #expect(next.carryReadmissionReport.delivered == 2)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// At the replacement's `retire()`, a pending own CC96 at 5,010 does not cover the carried CC96 at 5,000:
        /// both are carried (own first) and the third cycle emits both, in frame order. Kills: a carried command
        /// discarded as covered.
        @Test func readmissionRetireDoesNotCoverACarriedDataIncrement() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(5_000, control(96, 1))])
            let next = try replacement(of: rig)
            #expect(rig.push(cycleEvent(5_010, control(96, 2)), token) == .ok)
            #expect(block(next, 64).isEmpty)
            #expect(next.retire().controls == 2)
            let report = next.carryReadmissionReport
            #expect(report.supersededByReplacement == 0 && report.recarried == 1 && report.pendingCarriedEvents == 0)
            let third = try replacement(of: rig)
            let carry = third.inheritedRetirementCarry
            #expect(carry.events == [cycleEvent(5_010, control(96, 2)), cycleEvent(5_000, control(96, 1))])
            #expect(carry.ownCount == 1)
            #expect(block(third, 4_992) == [at(5_000, control(96, 1)), at(5_010, control(96, 2))])
            #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// Across two hops: repeated Data Increments and Decrements (CC96, CC97, same-frame pairs included) the
        /// replacement never reaches are all carried again, in order, and the third cycle emits all five in order.
        /// Kills: commands coalesced at either hop; same-frame commands reordered.
        @Test func readmissionKeepsRepeatedDataStepsAcrossTwoHops() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let pending: [(Int64, KernelEventPayload)] = [(5_000, control(96, 1)), (5_000, control(96, 2)),
                                                          (5_010, control(97, 3)), (5_010, control(97, 4)),
                                                          (5_020, control(96, 5))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            #expect(next.carryReadmissionReport.planned == 5 && next.carryReadmissionReport.superseded == 0)
            #expect(block(next, 64).isEmpty)
            #expect(next.retire().controls == 5 && next.carryReadmissionReport.recarried == 5)
            let third = try replacement(of: rig)
            #expect(third.inheritedRetirementCarry.events == pending.map { cycleEvent($0.0, $0.1) })
            #expect(third.inheritedRetirementCarry.ownCount == 0)
            #expect(third.carryReadmissionReport.planned == 5 && third.carryReadmissionReport.superseded == 0)
            #expect(block(third, 4_992) == pending.map { at($0.0, $0.1) })
            #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// An RPN (101, 100) and an NRPN (99, 98) sequence, each selecting a parameter and writing it with Data Entry
        /// MSB (6) and LSB (38) twice with different values, are replayed in full and in order. Kills: a parameter
        /// number or data entry coalesced (the first write lost or applied to the wrong parameter).
        @Test func readmissionReplaysParameterNumberSequencesInFull() throws {
            for (msb, lsb) in [(UInt8(101), UInt8(100)), (99, 98)] {
                let rig = try CycleRig(laneCapacity: 32)
                let token = try #require(rig.events.claimProducer())
                let values: [(UInt8, UInt32)] = [(msb, 0), (lsb, 0), (6, 2), (38, 1),
                                                 (msb, 0), (lsb, 1), (6, 64), (38, 2)]
                let pending = values.enumerated().map { index, value in
                    (100 + Int64(index) * 10, control(value.0, value.1))
                }
                retire(rig, token, pending: pending)
                let next = try replacement(of: rig)
                let report = next.carryReadmissionReport
                #expect(report.planned == 8 && report.superseded == 0, "CC\(msb)")
                #expect(block(next, 64) + block(next, 128) == pending.map { at($0.0, $0.1) }, "CC\(msb)")
                #expect(next.unresolvedRetirementLoss == KernelRetirementLoss(), "CC\(msb)")
            }
        }

        /// Reset All Controllers (CC121) deselects the parameter (RP-015), so its place among data-entry commands
        /// matters: an RPN select (101, 100) at 100 and 110, CC121 at 120, Data Entry at 130 (no parameter selected)
        /// and CC121 at 140 are all re-admitted, in order. Kills: the first CC121 coalesced into the last, which would
        /// let the Data Entry write RPN 0.
        @Test func readmissionKeepsResetAllControllersInPlace() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let pending: [(Int64, KernelEventPayload)] = [(100, control(101, 0)), (110, control(100, 0)),
                                                          (120, control(121, 0)), (130, control(6, 5)),
                                                          (140, control(121, 0))]
            retire(rig, token, pending: pending)
            let next = try replacement(of: rig)
            #expect(next.carryReadmissionReport.planned == 5 && next.carryReadmissionReport.superseded == 0)
            #expect(block(next, 64) + block(next, 128) == pending.map { at($0.0, $0.1) })
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// At the replacement's `retire()`, a pending own CC121 at 5,040 does not cover the carried CC121 at 5,020
        /// between an RPN select and a Data Entry: the four carried events are carried again after the own one and the
        /// third cycle emits all five in frame order. Kills: a carried reset discarded as covered.
        @Test func readmissionRetireDoesNotCoverACarriedReset() throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let carried: [(Int64, KernelEventPayload)] = [(5_000, control(101, 0)), (5_010, control(100, 0)),
                                                          (5_020, control(121, 0)), (5_030, control(6, 5))]
            retire(rig, token, pending: carried)
            let next = try replacement(of: rig)
            let reset: (Int64, KernelEventPayload) = (5_040, control(121, 0))
            #expect(rig.push(cycleEvent(reset.0, reset.1), token) == .ok)
            #expect(block(next, 64).isEmpty)
            #expect(next.retire().controls == 5)
            let report = next.carryReadmissionReport
            #expect(report.supersededByReplacement == 0 && report.recarried == 4)
            let third = try replacement(of: rig)
            #expect(third.inheritedRetirementCarry.events == ([reset] + carried).map { cycleEvent($0.0, $0.1) })
            #expect(third.inheritedRetirementCarry.ownCount == 1)
            #expect(block(third, 4_992) == (carried + [reset]).map { at($0.0, $0.1) })
            #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// A mixed sequence on one channel: carried CC7 at 100 and 120 coalesce into the survivor at 120 (weight 2),
        /// while the CC96 at 110 between them keeps its own slot and place. Delivered in two blocks, the CC96 resolves
        /// 1 of the 3 lost controls and the CC7 survivor the other 2. Kills: the first CC7 kept instead of the last;
        /// a weight lost or double-counted.
        @Test func readmissionCoalescesAroundADataIncrement() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, control(7, 1)), (110, control(96, 1)), (120, control(7, 2))])
            let next = try replacement(of: rig)
            #expect(next.carryReadmissionReport.planned == 2 && next.carryReadmissionReport.superseded == 1)
            #expect(next.unresolvedRetirementLoss.controls == 3)
            #expect(block(next, 64, frames: 50) == [at(110, control(96, 1))])
            #expect(next.unresolvedRetirementLoss.controls == 2)
            #expect(block(next, 114) == [at(120, control(7, 2))])
            #expect(next.carryReadmissionReport.delivered == 2)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
        }

        /// A coalescible control still coalesces as before: three carried CC7 writers re-admit as the last (weight
        /// 3), which a pending own CC7 at the replacement's `retire()` covers, resolving all three. Kills: the
        /// data-entry exception applied to every control.
        @Test func readmissionStillCoalescesVolume() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            retire(rig, token, pending: [(100, control(7, 1)), (110, control(7, 2)), (5_000, control(7, 3))])
            let next = try replacement(of: rig)
            #expect(next.carryReadmissionReport.planned == 1 && next.carryReadmissionReport.superseded == 2)
            #expect(rig.push(cycleEvent(5_010, control(7, 4)), token) == .ok)
            #expect(block(next, 64).isEmpty)
            #expect(next.retire().controls == 1)
            let report = next.carryReadmissionReport
            #expect(report.supersededByReplacement == 1 && report.recarried == 0)
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
            let third = try replacement(of: rig)
            #expect(third.inheritedRetirementCarry.events == [cycleEvent(5_010, control(7, 4))])
        }
    }

    /// Render-side bounds of the re-admission: a machine count of heap allocations and a source scan for locks.
    struct CycleCarryReadmissionBounds {
        /// Issue #364 acceptance (b), allocation half: with libmalloc's `malloc_logger` hook counting this thread's
        /// allocations, a replacement's `run`s (re-admitting and merging) and `retire()` (superseding a covered
        /// pending slot, carrying another again) allocate exactly as much as the same replacement with an empty
        /// carry, and, in an optimized build, nothing. (Unoptimized builds allocate in the existing `run` path
        /// whatever the carry.) A positive control must count first. Disabled under Thread Sanitizer, whose
        /// allocator bypasses the hook, and skipped (returns without failing) when another tool already holds the
        /// hook. Kills: an `Array` or class allocation on the re-admission path.
        @Test(.enabled(if: !threadSanitized, "Thread Sanitizer's allocator bypasses malloc_logger"),
              .enabled(if: mallocLoggerIsFree(), "malloc_logger is already in use"))
        func readmissionRenderPathAllocatesNothing() throws {
            guard let positive = allocations({
                UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16).deallocate()
            }) else { return }
            #expect(positive >= 1)
            _ = try renderScenario(carried: true, probed: false)
            let baseline = try renderScenario(carried: false, probed: true)
            let probed = try renderScenario(carried: true, probed: true)
            #expect(baseline.emitted == 2 && probed.emitted == 6)
            let report = probed.report
            #expect(report.delivered == 4 && report.supersededByReplacement == 1 && report.recarried == 1)
            guard let base = baseline.allocations, let counted = probed.allocations else { return }
            #expect(counted == base)
            #expect(counted == 0 || !optimizedBuild)
        }

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

        /// Retires a cycle with four carried events and two far-future ones (none unless `carried`), lets the
        /// replacement's own lanes carry an earlier `program` on the carried one's channel, a `control` and a later
        /// far-future `control` 10, then runs three blocks (merging in timeline order) and retires it (the own
        /// `control` 10 covers and supersedes the carried one; `control` 11 is carried again), counting allocations
        /// on this thread when `probed`. Emissions go to preallocated storage.
        private func renderScenario(carried: Bool, probed: Bool) throws -> ProbeOutcome {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let pending: [(Int64, KernelEventPayload)] = [(128, programFive), (140, control(7)),
                                                          (150, ramp(1, 1, 64)), (200, control(8)),
                                                          (5_000, control(10)), (5_000, control(11))]
            retire(rig, token, pending: carried ? pending : [])
            let next = try replacement(of: rig)
            let newer = KernelEventPayload.program(channel: 0, program: 9, bank: 0)
            #expect(rig.push(cycleEvent(100, newer), token) == .ok)
            #expect(rig.push(cycleEvent(130, control(9)), token) == .ok)
            #expect(rig.push(cycleEvent(6_000, control(10)), token) == .ok)
            let sink = UnsafeMutablePointer<KernelEvent>.allocate(capacity: 16)
            defer { sink.deallocate() }
            var emitted = 0
            let work = {
                for start in stride(from: Int64(64), to: 256, by: 64) {
                    _ = next.run(blockStart: start, frames: 64) { event, _ in
                        guard emitted < 16 else { return }
                        sink[emitted] = event
                        emitted &+= 1
                    }
                }
                _ = next.retire()
            }
            let counted = probed ? allocations(work) : { work(); return nil }()
            return ProbeOutcome(allocations: counted, emitted: emitted, report: next.carryReadmissionReport)
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

    /// Issue #364 acceptance (c): re-admission across a real thread hand-over, for Thread Sanitizer.
    @Suite(.serialized) struct CycleCarryReadmissionStress {
        /// 16 rounds: render retires a cycle with 8 carried events, waits for control's replacement and keeps running
        /// it (at most 256 blocks) until control is done, while control retries the preparation (refused until the
        /// retire) and then polls `unresolvedRetirementLoss` and `carryReadmissionReport` until nothing is stale,
        /// checking each only ever improves. Waits are bounded spins. Kills: a data race between render's
        /// re-admission counters and control's reads; a lost event.
        @Test func renderReadmitsWhileControlPreparesAndPolls() throws {
            for round in 0..<16 { try stressRound(Int64(round)) }
        }

        private func stressRound(_ round: Int64) throws {
            let rig = try CycleRig(laneCapacity: 32)
            let token = try #require(rig.events.claimProducer())
            let pending = (0..<8).map { index -> (Int64, KernelEventPayload) in
                let frame = 1_070 + round + Int64(index) * 7
                return index % 2 == 0 ? (frame, .program(channel: UInt8(index), program: 1, bank: 0))
                    : (frame, control(UInt8(index)))
            }
            for (frame, payload) in pending { #expect(rig.push(cycleEvent(frame, payload), token) == .ok) }
            #expect(rig.cycle.run(blockStart: 1_000, frames: 64) { _, _ in }.pending == 8)
            let parts = KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                         safety: rig.safety, ramps: rig.ramps,
                                         admissionRefusals: rig.cycle.admissionRefusals)
            let run = CycleStressRun()
            let replaced = CycleSlots<KernelCycle>(1)
            let seen = CycleSlots<[CycleEmission]>(1)
            let notes = CycleSlots<[String]>(2)
            let workers: [@Sendable (CycleStressRun) -> Void] = [
                { run in
                    guard run.arriveAndWait() else { return }
                    _ = rig.cycle.retire()
                    var spins = 0
                    while replaced.get(0) == nil, spins < 1_000_000, !run.shouldStop {
                        spins &+= 1
                        _ = sched_yield()
                    }
                    guard let next = replaced.get(0) else { return notes.set(0, ["render: no replacement"]) }
                    var emitted: [CycleEmission] = []
                    var start = Int64(1_064)
                    for _ in 0..<256 where notes.get(1) == nil || start < 1_192 {
                        _ = next.run(blockStart: start, frames: 64) {
                            emitted.append(CycleEmission(event: $0, frame: $1))
                        }
                        start &+= 64
                    }
                    seen.set(0, emitted)
                    notes.set(0, [])
                },
                { run in
                    guard run.arriveAndWait() else { return }
                    notes.set(1, prepareAndPoll(parts, run, replaced))
                }
            ]
            try #require(runCycleWorkers(run, workers))
            #expect(notes.get(0) == [] && notes.get(1) == [])
            let emitted = try #require(seen.get(0))
            #expect(emitted == pending.map { at($0.0, $0.1) })
            let next = try #require(replaced.get(0))
            #expect(next.unresolvedRetirementLoss == KernelRetirementLoss())
            #expect(next.carryReadmissionReport.delivered == 8)
        }
    }
}

/// Control: prepares the replacement (retrying while the predecessor has not retired), hands it over, then polls
/// the unresolved loss and the report until nothing is stale, checking that both only improve. Returns failures.
@Sendable private func prepareAndPoll(_ parts: KernelCycleParts, _ run: CycleStressRun,
                                      _ replaced: CycleSlots<KernelCycle>) -> [String] {
    var attempts = 0
    var prepared: KernelCycle?
    while prepared == nil, attempts < 1_000_000, !run.shouldStop {
        attempts &+= 1
        do {
            let gate = try ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48)
            prepared = try KernelCycle(parts, pulses: gate, blockCapacity: 64, perLaneQuota: 64)
        } catch KernelCycle.PreparationError.ownershipClaim(.predecessorNotRetired) {
            _ = sched_yield()
        } catch {
            return ["control: \(error)"]
        }
    }
    guard let next = prepared else { return ["control: no claim after \(attempts) attempts"] }
    replaced.set(0, next)
    var lastStateful = Int.max
    var lastDelivered = 0
    var lastPending = Int.max
    var polls = 0
    while polls < 1_000_000, !run.shouldStop {
        polls &+= 1
        let loss = next.unresolvedRetirementLoss
        let report = next.carryReadmissionReport
        let regressed = report.delivered < lastDelivered || report.pendingCarriedEvents > lastPending
        if loss.stateful > lastStateful || regressed {
            return ["control: regressed at \(polls)"]
        }
        lastStateful = loss.stateful
        lastDelivered = report.delivered
        lastPending = report.pendingCarriedEvents
        if !loss.receiverStateMayBeStale { return [] }
        _ = sched_yield()
    }
    return ["control: still stale after \(polls) polls"]
}

// MARK: allocation counting through libmalloc's `malloc_logger` hook

/// One allocation-probe scenario: the allocations counted (`nil` if not probed), emissions and the report.
private struct ProbeOutcome {
    let allocations: Int?
    let emitted: Int
    let report: KernelCarryReadmissionReport
}

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private let probedThread = Atomic<UInt>(0)
private let probedAllocations = Atomic<Int>(0)

/// Counts allocation records (`type & 2`, which includes reallocations) made on `probedThread`.
private let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    guard type & 2 != 0, UInt(bitPattern: pthread_self()) == probedThread.load(ordering: .relaxed) else { return }
    probedAllocations.add(1, ordering: .relaxed)
}

/// Whether this build is optimized (`-O`), where the existing `run` path allocates nothing either.
private let optimizedBuild = !_isDebugAssertConfiguration()

/// Whether libmalloc's `malloc_logger` hook exists and is unset (no other tool is using it).
private func mallocLoggerIsFree() -> Bool {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }
    return symbol.assumingMemoryBound(to: MallocLogger?.self).pointee == nil
}

/// Whether this process runs under Thread Sanitizer.
private let threadSanitized = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

/// The allocations `body` makes on the calling thread, counted through libmalloc's process-wide `malloc_logger`
/// hook, or `nil` when the hook is missing or already in use. Counts every zone's `malloc`, `calloc`, `realloc` and
/// `valloc`, including Swift's object and buffer allocations; does not see stack memory, `mmap` or allocations on
/// other threads.
private func allocations(_ body: () -> Void) -> Int? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let slot = symbol.assumingMemoryBound(to: MallocLogger?.self)
    guard slot.pointee == nil else { return nil }
    probedAllocations.store(0, ordering: .relaxed)
    probedThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
    slot.pointee = countingLogger
    body()
    slot.pointee = nil
    probedThread.store(0, ordering: .relaxed)
    return probedAllocations.load(ordering: .relaxed)
}
