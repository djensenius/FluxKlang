import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RealtimeHandoffTests {
    /// #837: the constructor's canonical fixed planner, not a parallel experimental implementation.
    struct CycleCarryPlanning {
        @Test func fixedPlanEmptySingletonAndCapacityEndpoints() throws {
            for capacity in [1, 256] {
                let empty = KernelCarryPlan(carry: KernelRetirementCarry(), capacity: capacity)
                #expect(empty.count == 0 && empty.entry(at: 0) == nil)
                #expect(empty.refusal == nil && empty.cut == KernelRetirementLoss())
                let event = cycleEvent(-19, .program(channel: 2, program: 8, bank: 12))
                let plan = KernelCarryPlan(carry: carry([event]), capacity: capacity)
                #expect(plan.count == 1 && plan.superseded == 0 && plan.invalidRamps == 0)
                #expect(try #require(plan.entry(at: 0)).event == event)
                #expect(try #require(plan.entry(at: 0)).weight == 1)
                #expect(plan.entry(at: -1) == nil && plan.entry(at: 1) == nil)
                #expect(plan.entry(at: .max) == nil && plan.entry(at: .min) == nil)
            }
        }

        @Test func fixedPlanFullReverseOrderCutsOnlyLatestSurvivors() throws {
            let input = reverseFullCarry()
            let full = KernelCarryPlan(carry: input, capacity: 256)
            #expect(full.count == 256 && full.superseded == 0 && full.droppedAtRecord == 1)
            #expect(full.cut == KernelRetirementLoss() && full.refusal == nil)
            for index in 0..<256 {
                let entry = try #require(full.entry(at: index))
                #expect(entry.event.frame == Int64(index) - 128 && entry.weight == 1)
            }
            let small = KernelCarryPlan(carry: input, capacity: 1)
            #expect(small.count == 1 && small.cut.ramps == 255 && small.droppedAtRecord == 1)
            #expect(try #require(small.entry(at: 0)).event.frame == -128)
        }

        @Test func fixedPlanEqualFramesUseRecarriedThenOwnThenRecordedIndex() {
            let own = [control(7, sequence: 90), control(96, sequence: 80), control(8, sequence: 70)]
            let inherited = [control(0, sequence: 60), control(96, sequence: 50), control(7, sequence: 40)]
            let input = carry(own, recarried: inherited)
            let plan = KernelCarryPlan(carry: input, capacity: 256)
            #expect(events(plan) == [inherited[0], inherited[1], own[0], own[1], own[2]])
            #expect(weights(plan) == [1, 1, 2, 1, 1] && plan.superseded == 1)
            // Both boundary endpoints use recorded index, not sequence, to break frame ties.
            #expect(events(KernelCarryPlan(carry: carry(own), capacity: 256)) == own)
            #expect(events(KernelCarryPlan(carry: carry([], recarried: own), capacity: 256)) == own)
        }

        @Test func fixedPlanKeysKeepScopeChannelControllerParameterAndKindDistinct() {
            let input = [
                control(7), control(7, sequence: 1), control(8),
                cycleEvent(10, .control(channel: 1, controller: 7, value: 4)),
                cycleEvent(10, .control(channel: 0, controller: 7, value: 5), scope: 1),
                cycleEvent(10, .program(channel: 0, program: 1, bank: 1)),
                cycleEvent(10, .program(channel: 0, program: 2, bank: 2)),
                cycleEvent(10, .program(channel: 1, program: 3, bank: 2)),
                cycleEvent(10, .program(channel: 0, program: 4, bank: 2), scope: 1),
                ramp(10, parameter: 7), ramp(10, parameter: 7, value: 2),
                ramp(10, parameter: 7, scope: 1), ramp(10, parameter: 8)
            ]
            let plan = KernelCarryPlan(carry: carry(input), capacity: 256)
            #expect(events(plan) == [input[1], input[2], input[3], input[4], input[6], input[7],
                                     input[8], input[10], input[11], input[12]])
            #expect(weights(plan) == [2, 1, 1, 1, 2, 1, 1, 2, 1, 1])
            #expect(plan.superseded == 3)
        }

        @Test func fixedPlanNeverCoalescesOrderedDataEntryControls() {
            let controllers: [UInt8] = [6, 38, 96, 97, 98, 99, 100, 101, 121]
            let input = (controllers + controllers).enumerated()
                .map { control($0.element, sequence: UInt64($0.offset)) }
            let plan = KernelCarryPlan(carry: carry(input), capacity: 256)
            #expect(events(plan) == input && weights(plan) == Array(repeating: 1, count: 18))
            #expect(plan.superseded == 0 && plan.cut == KernelRetirementLoss())
        }

        @Test func fixedPlanFiltersNonfiniteBeforeKeysAndOverflowAndKeepsNegativeJumps() {
            let valid = ramp(.max, duration: .min)
            let input = [ramp(1, value: .nan, duration: .max), valid,
                         ramp(.max, value: .infinity, duration: 1),
                         ramp(.max, value: -.infinity, duration: .max)]
            let plan = KernelCarryPlan(carry: carry(input), capacity: 1)
            #expect(events(plan) == [valid] && weights(plan) == [1])
            #expect(plan.invalidRamps == 3 && plan.superseded == 0 && plan.refusal == nil)
            #expect(plan.cut == KernelRetirementLoss())
        }

        @Test func fixedPlanChecksOverflowBeyondCutButNotSupersededOverflow() {
            let early = control(7)
            let overflow = ramp(.max - 1, duration: 2)
            let refused = KernelCarryPlan(carry: carry([early, overflow]), capacity: 1)
            #expect(refused.refusal == .frameOverflow && refused.count == 0 && refused.superseded == 0)
            #expect(refused.cut == KernelRetirementLoss())
            let jump = ramp(.max, duration: -1)
            let accepted = KernelCarryPlan(carry: carry([early, overflow, jump]), capacity: 256)
            #expect(events(accepted) == [early, jump] && weights(accepted) == [1, 2])
            #expect(accepted.refusal == nil && accepted.superseded == 1)
            let cut = KernelCarryPlan(carry: carry([early, overflow, jump]), capacity: 1)
            #expect(cut.refusal == nil && cut.superseded == 1 && cut.cut.ramps == 1)
            // Equal-frame recorded order also supersedes an overflowing ramp.
            let tied = KernelCarryPlan(carry: carry([ramp(.max, duration: 1), jump]), capacity: 1)
            #expect(events(tied) == [jump] && weights(tied) == [2])
        }

        @Test func fixedPlanWeightsResolveOnlySurvivorsAndCutsCountByKind() {
            let input = [control(7), control(7, sequence: 1), control(8),
                         cycleEvent(11, .program(channel: 0, program: 2, bank: 0)), ramp(12)]
            let readmission = KernelCarryReadmission(carry: carry(input), blockCapacity: 1)
            let report = readmission.report
            #expect(report.planned == 1 && report.superseded == 1)
            #expect(report.cut.controls == 1 && report.cut.programs == 1 && report.cut.ramps == 1)
            #expect(readmission.resolved() == KernelCarryResolution(controls: 0, programs: 0, ramps: 0))
            #expect(readmission.next == input[1])
            readmission.consumeNext(delivered: true)
            #expect(readmission.resolved() == KernelCarryResolution(controls: 2, programs: 0, ramps: 0))
            #expect(readmission.report.delivered == 1 && readmission.report.pendingCarriedEvents == 0)
        }

        @Test func fixedPlanReplacementAndTwoHopEmissionsPreservePerHopLoss() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let rig = try CycleRig()
            let token = try RefusalCalling.claim(rig.events, &caller!)
            let old = cycleEvent(128, .control(channel: 0, controller: 7, value: 1))
            let survivor = cycleEvent(129, .control(channel: 0, controller: 7, value: 2))
            let future = cycleEvent(256, .control(channel: 0, controller: 96, value: 1))
            for event in [old, survivor, future] { #expect(rig.push(event, token, caller: &caller!) == .ok) }
            #expect(rig.run(0, 64).0.pending == 3)
            #expect(rig.cycle.retire().controls == 3)
            let second = try replacement(rig)
            #expect(second.carryReadmissionReport.planned == 2 && second.carryReadmissionReport.superseded == 1)
            #expect(second.unresolvedRetirementLoss.controls == 3)
            #expect(emissions(second, start: 128) == [CycleEmission(event: survivor, frame: 129)])
            #expect(second.unresolvedRetirementLoss.controls == 1)
            let own = cycleEvent(256, .control(channel: 0, controller: 96, value: 2))
            #expect(rig.push(own, token, caller: &caller!) == .ok)
            #expect(emissions(second, start: 192).isEmpty)
            #expect(second.retire().controls == 2)
            #expect(second.carryReadmissionReport.recarried == 1)
            #expect(second.unresolvedRetirementLoss.controls == 1)
            let third = try replacement(rig)
            #expect(third.inheritedRetirementCarry.ownCount == 1)
            #expect(third.carryReadmissionReport.planned == 2 && third.carryReadmissionReport.superseded == 0)
            #expect(third.unresolvedRetirementLoss.controls == 2)
            #expect(emissions(third, start: 256) == [CycleEmission(event: future, frame: 256),
                                                   CycleEmission(event: own, frame: 256)])
            #expect(third.carryReadmissionReport.delivered == 2)
            #expect(third.unresolvedRetirementLoss == KernelRetirementLoss())
        }
    }
}

extension RealtimeHandoffTests.CycleCarryPlanning {
    /// Release only: actual canonical planning and every result field/entry consumed into preallocated sinks.
    /// Uses the existing process-wide gate. Warm-up is separate; zero is required, never a baseline comparison.
    @Test(.enabled(if: optimizedBuild, "Release allocation qualification"),
          .enabled(if: !threadSanitized, "Thread Sanitizer's allocator bypasses malloc_logger"),
          .enabled(if: mallocLoggerIsFree(), "malloc_logger is already in use"))
    func carryPlanningAndConsumptionAllocateNothing() throws {
        let fixtures = [KernelRetirementCarry(), carry([control(7)]), reverseFullCarry(),
                        carry(Array(repeating: control(7), count: 256)),
                        carry([control(7)], recarried: [control(96), control(8)]),
                        carry([cycleEvent(10, .program(channel: 0, program: 1, bank: 0)),
                               cycleEvent(11, .program(channel: 0, program: 2, bank: 1)),
                               cycleEvent(12, .program(channel: 0, program: 3, bank: 0), scope: 1),
                               control(121), ramp(13), ramp(14, scope: 1)]),
                        carry([ramp(.max, value: .nan, duration: 1), ramp(.max, duration: -1)]),
                        carry([control(7), ramp(.max, duration: 1)]),
                        carry([ramp(.max, duration: 1), ramp(.max, duration: 0)])]
        let sink = UnsafeMutablePointer<KernelCarryPlan.Entry>.allocate(capacity: 256)
        let metadata = UnsafeMutablePointer<Int>.allocate(capacity: 8)
        sink.initialize(repeating: KernelCarryPlan.Entry(event: control(0), weight: 0), count: 256)
        metadata.initialize(repeating: 0, count: 8)
        defer {
            sink.deinitialize(count: 256)
            sink.deallocate()
            metadata.deinitialize(count: 8)
            metadata.deallocate()
        }
        let positive = try #require(allocations {
            UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16).deallocate()
        })
        #expect(positive >= 1)
        // All setup, warm-up, assertions and allocating test conveniences remain outside the measured closures.
        for fixture in fixtures {
            for capacity in [1, 256] { consumePlan(fixture, capacity: capacity, sink: sink, metadata: metadata) }
        }
        for fixture in fixtures {
            for capacity in [1, 256] {
                let expected = KernelCarryPlan(carry: fixture, capacity: capacity)
                let counted = try #require(allocations {
                    consumePlan(fixture, capacity: capacity, sink: sink, metadata: metadata)
                })
                #expect(counted == 0)
                #expect(metadata[0] == expected.count && metadata[1] == expected.invalidRamps)
                #expect(metadata[2] == expected.superseded && metadata[3] == expected.droppedAtRecord)
                #expect(metadata[4] == expected.cut.controls && metadata[5] == expected.cut.programs)
                #expect(metadata[6] == expected.cut.ramps && metadata[7] == (expected.refusal == nil ? 0 : 1))
                for index in 0..<expected.count {
                    let entry = try #require(expected.entry(at: index))
                    #expect(sink[index].event == entry.event && sink[index].weight == entry.weight)
                }
            }
        }
    }

    @Test func carryPlanningStorageLayoutIsFixed() {
        RealtimeHandoffTests.requireBitwise(KernelCarryPlan.self)
        RealtimeHandoffTests.requireBitwise(KernelCarryPlan.Entry.self)
        let entry = MemoryLayout<KernelCarryPlan.Entry>.stride
        let plan = MemoryLayout<KernelCarryPlan>.stride
        let carry = MemoryLayout<KernelRetirementCarry>.stride
        print("carry-plan layout: event=\(MemoryLayout<KernelEvent>.stride) entry=\(entry) plan=\(plan) carry=\(carry)")
        #expect(plan == 256 * entry + 80)
    }

    /// Scan the complete planner (including private helpers), plus the small shared helpers it calls.
    /// This deliberately does not scan the allocating object/slot constructor as if it were allocation-free.
    @Test(.enabled(if: Self.eventsDirectory() != nil, "the kernel sources are not next to the tests"))
    func carryPlanningSourcesHaveNoAllocationGrowthOrLockToken() throws {
        let directory = try #require(Self.eventsDirectory())
        let planner = try String(contentsOf: directory.appendingPathComponent("KernelCarryPlan.swift"), encoding: .utf8)
        try checkSource(planner)
        let helpers = [
            ("KernelRetirementCarry.swift", "func event(at"),
            ("KernelRetirementCarry.swift", "var ownCount:"),
            ("KernelEvent.swift", "var isCoalescible:"),
            ("KernelEvent.swift", "static func isAdmissibleRampTarget("),
            ("KernelEvent.swift", "static func rampFrames("),
            ("NoteOwnership.swift", "mutating func drop(")
        ]
        for (file, declaration) in helpers {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            try checkSource(#require(KernelRetirementCarryTests.functionBody(declaration, in: text)))
        }
    }

    private func checkSource(_ text: String) throws {
        let code = text.split(separator: "\n").map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n").replacingOccurrences(of: "InlineArray", with: "FixedStorage")
        #expect(KernelRetirementCarryTests.arrayMutations(in: code).isEmpty)
        let banned = ["Array", "Dictionary", "Set<", "Set(", ".sorted", ".map", ".filter", ".reduce",
                      ".allocate", "malloc", "calloc", "realloc", "Mutex", "withLock", "NSLock",
                      "_lock", "lock(", "os_unfair", "pthread_", "Dispatch", ".events", "[KernelEvent]",
                      "class ", "reserveCapacity"]
        #expect(banned.filter { code.contains($0) }.isEmpty)
    }

    private static func eventsDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        return ["../Shared/Audio/Kernel/Events", "../../Sources/FluxKlang/Shared/Audio/Kernel/Events"]
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("KernelCarryPlan.swift").path) }
    }
}

// Test-only conveniences may allocate; none run inside the measurement.
private func carry(_ own: [KernelEvent], recarried: [KernelEvent] = []) -> KernelRetirementCarry {
    var carry = KernelRetirementCarry()
    for event in own { carry.record(event) }
    carry.beginRecarried()
    for event in recarried { carry.record(event) }
    return carry
}

private func control(_ controller: UInt8, sequence: UInt64 = 0) -> KernelEvent {
    cycleEvent(10, .control(channel: 0, controller: controller, value: 1), sequence: sequence)
}

private func ramp(_ frame: Int64, parameter: UInt32 = 0, value: Float = 1, duration: Int64 = 0,
                  scope: UInt32 = 0) -> KernelEvent {
    cycleEvent(frame, .rampTo(parameter: parameter, value: value, durationFrames: duration), scope: scope)
}

private func reverseFullCarry() -> KernelRetirementCarry {
    var carry = KernelRetirementCarry()
    for index in (0..<256).reversed() {
        carry.record(ramp(Int64(index) - 128, parameter: UInt32(index)))
    }
    carry.record(control(7))
    return carry
}

private func events(_ plan: borrowing KernelCarryPlan) -> [KernelEvent] {
    var events: [KernelEvent] = []
    for index in 0..<plan.count {
        if let entry = plan.entry(at: index) { events.append(entry.event) }
    }
    return events
}

private func weights(_ plan: borrowing KernelCarryPlan) -> [Int] {
    var weights: [Int] = []
    for index in 0..<plan.count {
        if let entry = plan.entry(at: index) { weights.append(entry.weight) }
    }
    return weights
}

private func replacement(_ rig: CycleRig) throws -> KernelCycle {
    try KernelCycle(KernelCycleParts(events: rig.events, faults: rig.faults, ownership: rig.ownership,
                                    safety: rig.safety, ramps: rig.ramps,
                                    admissionRefusals: rig.cycle.admissionRefusals),
                    pulses: ClockPulseGate(maximumPulsesPerBlock: 4, staleTolerance: 48),
                    blockCapacity: 64, perLaneQuota: 64)
}

private func emissions(_ cycle: KernelCycle, start: Int64) -> [CycleEmission] {
    var emitted: [CycleEmission] = []
    _ = cycle.run(blockStart: start, frames: 64) { emitted.append(CycleEmission(event: $0, frame: $1)) }
    return emitted
}

/// Keep the measured operation opaque to its caller, and consume every field into observable, preallocated sinks.
@inline(never)
private func consumePlan(_ carry: borrowing KernelRetirementCarry, capacity: Int,
                         sink: UnsafeMutablePointer<KernelCarryPlan.Entry>, metadata: UnsafeMutablePointer<Int>) {
    let plan = KernelCarryPlan(carry: carry, capacity: capacity)
    var index = 0
    while let entry = plan.entry(at: index) {
        sink[index] = entry
        index += 1
    }
    metadata[0] = plan.count
    metadata[1] = plan.invalidRamps
    metadata[2] = plan.superseded
    metadata[3] = plan.droppedAtRecord
    metadata[4] = plan.cut.controls
    metadata[5] = plan.cut.programs
    metadata[6] = plan.cut.ramps
    metadata[7] = plan.refusal == nil ? 0 : 1
}
