import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests
typealias ScratchProbeSlot = PreparedPlanSlot<ScratchPlanProbe>

/// A 3-byte, byte-aligned element, so cursors land on odd offsets.
private struct Triple: BitwiseCopyable {
    let first: UInt8
    let second: UInt8
    let third: UInt8
}

/// Byte offset of `buffer` from `base`, or `nil` for an empty buffer.
private func offset<T>(_ buffer: UnsafeMutableBufferPointer<T>?, from base: UnsafeRawPointer) -> Int? {
    guard let start = buffer?.baseAddress else { return nil }
    return UnsafeRawPointer(start) - base
}

/// Reference model of one arena, in byte offsets from its base address; alignment is of the absolute address.
private struct ScratchModel {
    let base: UInt
    let capacity: Int
    let alignment: Int
    var used = 0
    var highWater = 0
    var exhausted: UInt64 = 0

    /// The expected offset of a take with `count > 0`, or `nil` (counted) when it must be refused.
    mutating func take(count: Int, stride: Int, typeAlignment: Int) -> Int? {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
        let effective = UInt(max(alignment, typeAlignment))
        let start = Int((base + UInt(used) + effective - 1) / effective * effective - base)
        guard count > 0, !overflow, bytes <= capacity - start else {
            exhausted += 1
            return nil
        }
        used = start + bytes
        highWater = max(highWater, used)
        return start
    }
}

/// Drives one arena and its model side by side, fills every buffer with its own marker byte and records
/// divergences.
private struct ScratchRun {
    let arena: ScratchArena
    var model: ScratchModel
    var taken: [(range: Range<Int>, marker: UInt8)] = []
    var divergences: [String] = []

    init(_ arena: ScratchArena) {
        self.arena = arena
        model = ScratchModel(base: UInt(bitPattern: arena.storageBaseAddress), capacity: arena.byteCapacity,
                             alignment: arena.alignment)
    }

    mutating func take<T: BitwiseCopyable>(_: T.Type, _ count: Int) {
        let context = "\(T.self) x \(count), capacity \(arena.byteCapacity), alignment \(arena.alignment)"
        let buffer = arena.take(T.self, count: count)
        if count == 0 {
            if buffer?.count != 0 || buffer?.baseAddress != nil { divergences.append("\(context): not empty") }
            return
        }
        // Fill whatever came back before judging it, one byte at a time through `UnsafeMutablePointer`'s
        // transparent subscript, so the stores are in this (ASan-instrumented) module and ASan sees any
        // out-of-bounds buffer being written.
        let marker = UInt8(truncatingIfNeeded: taken.count + 1)
        let raw = buffer.map { UnsafeMutableRawBufferPointer($0) }
        if let bytes = raw?.bindMemory(to: UInt8.self).baseAddress, let raw {
            for index in 0..<raw.count { bytes[index] = marker }
        }
        let expected = model.take(count: count, stride: MemoryLayout<T>.stride,
                                  typeAlignment: MemoryLayout<T>.alignment)
        let actual = offset(buffer, from: arena.storageBaseAddress)
        guard actual == expected, buffer?.count ?? count == count,
              arena.exhaustedCount == model.exhausted, arena.highWater == model.highWater else {
            divergences.append("\(context): offset \(String(describing: actual)), model \(String(describing: expected))"
                               + ", exhausted \(arena.exhaustedCount), highWater \(arena.highWater)")
            return
        }
        guard let raw, let actual else { return }
        taken.append((actual..<actual + raw.count, marker))
    }

    /// Every buffer still holds only its own marker, so no two overlapped.
    func intact() -> Bool {
        taken.allSatisfy { entry in
            entry.range.allSatisfy { arena.storageBaseAddress.load(fromByteOffset: $0, as: UInt8.self) == entry.marker }
        }
    }

    mutating func resetCycle() {
        arena.resetCycle()
        model.used = 0
        taken.removeAll(keepingCapacity: true)
    }
}

extension RealtimeHandoffTests {
    static let scratchRetireScope = FaultScope(handoff: 7, target: 0)

    /// A dedicated M6 retire queue for one slot, with the latch it raises `.retireBacklog` on.
    static func scratchRetireQueue(capacity: Int) throws -> (DeferredReleaseQueue, FaultLatch) {
        let faults = try FaultLatch(scopes: [scratchRetireScope])
        let retire = Self.policy(purpose: .retire, producer: .render, consumer: .control, capacity: capacity,
                                 deadline: .none)
        return (try DeferredReleaseQueue(policy: retire, faults: faults, scope: scratchRetireScope), faults)
    }
}

extension RealtimeHandoffTests {
    struct ScratchTaking {
        static func preparationError(_ bytes: Int, _ alignment: Int) -> ScratchArena.PreparationError? {
            do {
                _ = try ScratchArena(byteCapacity: bytes, alignment: alignment)
                return nil
            } catch {
                return error
            }
        }

        @Test func initRefusesAdversarialGeometry() {
            let maximum = ScratchArena.maximumByteCapacity
            for bytes in [Int.min, -1, 0, maximum + 1, .max] {
                #expect(Self.preparationError(bytes, 16) == .byteCapacity(bytes))
            }
            let largest = ScratchArena.maximumAlignment
            for alignment in [Int.min, -16, -1, 0, 3, 6, 12, 24, largest - 1, largest + 1, largest * 2, 1 << 62, .max] {
                #expect(Self.preparationError(64, alignment) == .alignment(alignment))
            }
            #expect(Self.preparationError(0, 3) == .byteCapacity(0))
            for alignment in [1, 2, 4, 8, 16, 64, 256, largest] {
                #expect(Self.preparationError(1, alignment) == nil)
            }
            #expect(Self.preparationError(maximum, largest) == nil)
            let arena = try? ScratchArena(byteCapacity: 100, alignment: 64)
            #expect(arena?.byteCapacity == 100)
            #expect(arena?.alignment == 64)
            #expect(arena.map { UInt(bitPattern: $0.storageBaseAddress) % 64 } == 0)
        }

        /// Mixed element types and counts against the model, for every alignment and several capacities, over two
        /// cycles, then an exact fill: buffers are where the model puts them, aligned to
        /// `max(arena alignment, T alignment)`, inside the storage and disjoint; anything that does not fit is
        /// `nil`.
        @Test func takeRespectsAlignmentAndCapacity() throws {
            for alignment in [1, 2, 4, 8, 16, 64, ScratchArena.maximumAlignment] {
                for capacity in [1, 3, 16, 61, 256, 1_024] {
                    var run = ScratchRun(try ScratchArena(byteCapacity: capacity, alignment: alignment))
                    for _ in 0..<2 {
                        run.resetCycle()
                        run.take(Triple.self, 1)
                        run.take(UInt64.self, 1)
                        run.take(UInt8.self, 0)
                        run.take(UInt8.self, 1)
                        run.take(SIMD4<Float>.self, 1)
                        run.take(UInt16.self, 3)
                        run.take(UInt32.self, 2)
                        run.take(Triple.self, 5)
                        run.take(UInt64.self, 2)
                        run.take(UInt8.self, 9)
                        run.take(SIMD4<Float>.self, 2)
                        run.take(UInt64.self, 40)
                        run.take(UInt8.self, 1)
                        #expect(run.intact(), "capacity \(capacity), alignment \(alignment)")
                    }
                    let start = (run.model.used + alignment - 1) / alignment * alignment
                    if start < capacity { run.take(UInt8.self, capacity - start) }
                    run.take(UInt8.self, 1)
                    #expect(run.model.used == capacity || start >= capacity)
                    #expect(run.intact(), "capacity \(capacity), alignment \(alignment)")
                    #expect(run.divergences.isEmpty, "\(run.divergences)")
                }
            }
        }

        @Test func exhaustionReturnsNilAndCounts() throws {
            let arena = try ScratchArena(byteCapacity: 32, alignment: 4)
            let base = arena.storageBaseAddress
            #expect(offset(arena.take(UInt32.self, count: 6), from: base) == 0)
            #expect(arena.take(UInt32.self, count: 3) == nil)  // 12 bytes into 8: never a partial buffer
            #expect(arena.exhaustedCount == 1)
            #expect(arena.highWater == 24)
            #expect(offset(arena.take(UInt32.self, count: 2), from: base) == 24)  // the refusal moved nothing
            #expect(arena.take(UInt8.self, count: 1) == nil)
            #expect(arena.exhaustedCount == 2)
            #expect(arena.highWater == 32)

            let padded = try ScratchArena(byteCapacity: 20, alignment: 8)
            let paddedBase = padded.storageBaseAddress
            #expect(offset(padded.take(UInt8.self, count: 1), from: paddedBase) == 0)
            #expect(padded.take(UInt64.self, count: 2) == nil)  // 16 bytes fit in 19, but not after 7 of padding
            #expect(offset(padded.take(UInt64.self, count: 1), from: paddedBase) == 8)
            #expect(offset(padded.take(UInt8.self, count: 4), from: paddedBase) == 16)
            #expect(padded.take(UInt8.self, count: 1) == nil)
            #expect(padded.exhaustedCount == 2)
            #expect(padded.highWater == 20)
        }

        /// The same bytes every cycle: the same base address and what the last cycle wrote is still there (a
        /// fresh allocation would differ; under ASan its quarantine also changes the address).
        @Test func resetCycleReusesSameStorage() throws {
            let arena = try ScratchArena(byteCapacity: 4_096, alignment: 64)
            let base = arena.storageBaseAddress
            var moved = 0
            var lost = 0
            for cycle in 0..<1_000 {
                arena.resetCycle()
                let buffer = try #require(arena.take(UInt32.self, count: 1_024))
                if UnsafeRawPointer(buffer.baseAddress) != base { moved += 1 }
                if cycle > 0, !buffer.allSatisfy({ $0 == UInt32(cycle - 1) }) { lost += 1 }
                buffer.initialize(repeating: UInt32(cycle))
                if arena.take(UInt8.self, count: 1) != nil { moved += 1 }
            }
            #expect(moved == 0)
            #expect(lost == 0)
            #expect(arena.storageBaseAddress == base)
            #expect(arena.highWater == 4_096)
            #expect(arena.exhaustedCount == 1_000)
        }

        /// Negative, zero, `Int.max` and overflowing `count * stride`: zero gives an empty buffer, anything that
        /// cannot fit is `nil` and counted, nothing traps and the cursor never moves.
        @Test func adversarialCountsAreRefused() throws {
            let arena = try ScratchArena(byteCapacity: 64, alignment: 16)
            let counts = Root.adversarialInts
                + [4, 5, 8, 9, 64, 65, .max / 2 + 1, .max / 4 + 1, .max / 16 + 1, .min / 2]
            var refused: UInt64 = 0
            func attempt<T: BitwiseCopyable>(_: T.Type, _ count: Int) -> Bool {
                let expected = count == 0 ? 0 : count > 0 && count <= 64 / MemoryLayout<T>.stride ? count : nil
                if expected == nil { refused += 1 }
                let buffer = arena.take(T.self, count: count)
                arena.resetCycle()
                let empty = buffer.map { $0.baseAddress == nil } ?? false
                return buffer?.count == expected && empty == (count == 0) && arena.exhaustedCount == refused
            }
            for count in counts {
                #expect(attempt(UInt8.self, count), "UInt8 x \(count)")
                #expect(attempt(UInt16.self, count), "UInt16 x \(count)")
                #expect(attempt(UInt64.self, count), "UInt64 x \(count)")
                #expect(attempt(SIMD4<Float>.self, count), "SIMD4<Float> x \(count)")
            }
            #expect(refused > 0)
            #expect(offset(arena.take(UInt64.self, count: 8), from: arena.storageBaseAddress) == 0)
        }
    }

    struct PlanSlotRetiring {
        /// Control: publishes `made` with its own scratch size. `consuming` and `consume` hand over the only
        /// reference, so the slot's ownership check passes and takes the plan on `.ok`.
        fileprivate static func publish(_ slot: ScratchProbeSlot?, _ made: consuming ScratchPlanProbe,
                                        alignment: Int) throws -> KernelStatus? {
            let bytes = made.scratchBytes
            var plan: ScratchPlanProbe? = consume made
            return try slot?.publish(&plan, scratchBytes: bytes, alignment: alignment)
        }

        fileprivate static func publishError(_ slot: ScratchProbeSlot, _ plan: inout ScratchPlanProbe?, bytes: Int,
                                             alignment: Int) -> ScratchArena.PreparationError? {
            do {
                _ = try slot.publish(&plan, scratchBytes: bytes, alignment: alignment)
                return nil
            } catch {
                return error
            }
        }

        @Test func emptySlotLendsNothingAndInvalidScratchPublishesNothing() throws {
            let ledger = RetireLedger()
            let (queue, _) = try Root.scratchRetireQueue(capacity: 2)
            let slot = ScratchProbeSlot(retire: queue)
            #expect(ledger.asRender { slot.beginCycle(frame: 0) } == .empty)
            #expect(ledger.asRender { slot.withCurrent { _, _ in true } } == nil)
            weak var weakPlan: ScratchPlanProbe?
            do {
                var plan: ScratchPlanProbe? = ScratchPlanProbe(1, scratchBytes: 64, ledger, ScratchArenaWatch())
                weakPlan = plan
                #expect(Self.publishError(slot, &plan, bytes: 0, alignment: 16) == .byteCapacity(0))
                #expect(Self.publishError(slot, &plan, bytes: 64, alignment: 3) == .alignment(3))
                #expect(Self.publishError(slot, &plan, bytes: .max, alignment: 16) == .byteCapacity(.max))
                #expect(plan?.serial == 1)  // a throwing publish leaves the plan with the caller
            }
            #expect(weakPlan == nil)
            #expect(queue.reservedCount == 0)
            #expect(ledger.asRender { slot.beginCycle(frame: 1) } == .empty)
            #expect(ledger.asRender { slot.withCurrent { _, _ in true } } == nil)
            #expect(ledger.allOnControl)
        }

        /// Each plan gets its own arena with its own geometry, and `beginCycle` resets the current arena every
        /// cycle, adopting or not.
        @Test func eachPlanHasItsOwnArenaResetEveryCycle() throws {
            let ledger = RetireLedger()
            let (queue, _) = try Root.scratchRetireQueue(capacity: 2)
            let slot = ScratchProbeSlot(retire: queue)
            let watch = ScratchArenaWatch()
            func fill() -> (ObjectIdentifier, Int)? {
                ledger.asRender {
                    slot.withCurrent { plan, scratch in
                        guard scratch.take(UInt8.self, count: plan.scratchBytes) != nil,
                              scratch.take(UInt8.self, count: 1) == nil else { return nil }
                        return (ObjectIdentifier(scratch), scratch.byteCapacity)
                    } ?? nil
                }
            }
            #expect(try Self.publish(slot, ScratchPlanProbe(1, scratchBytes: 48, ledger, watch), alignment: 16) == .ok)
            #expect(ledger.asRender { slot.withCurrent { _, _ in true } } == nil)  // not adopted before `beginCycle`
            #expect(ledger.asRender { slot.beginCycle(frame: 0) } == .ok)
            let first = try #require(fill())
            #expect(first.1 == 48)
            for frame in 1...3 {
                #expect(ledger.asRender { slot.beginCycle(frame: Int64(frame)) } == .empty)
                #expect(fill()?.0 == first.0)
            }
            #expect(try Self.publish(slot, ScratchPlanProbe(2, scratchBytes: 96, ledger, watch), alignment: 64) == .ok)
            #expect(ledger.asRender { slot.beginCycle(frame: 4) } == .ok)
            let second = try #require(fill())
            #expect(second.1 == 96)
            #expect(second.0 != first.0)
            #expect(ledger.asRender { slot.withCurrent { _, scratch in scratch.alignment } } == 64)
            #expect(slot.reclaim() == 1)
            #expect(ledger.live == 1)
            #expect(ledger.allOnControl)
        }

        /// A retired plan keeps its arena until control reclaims both; the plan is released first, so its arena is
        /// still alive at the plan's `deinit`; nothing is released on render; teardown does the same for `current`.
        /// A publish refused for backpressure hands the plan back and drops only its fresh arena.
        @Test func planAndArenaRetireTogether() throws {
            let ledger = RetireLedger()
            let watch = ScratchArenaWatch()
            let (queue, faults) = try Root.scratchRetireQueue(capacity: 1)
            var slot: ScratchProbeSlot? = ScratchProbeSlot(retire: queue)
            weak var firstPlan: ScratchPlanProbe?
            weak var firstArena: ScratchArena?
            weak var secondPlan: ScratchPlanProbe?
            weak var secondArena: ScratchArena?
            /// Render: begins a cycle, links the current plan to its arena and lends both to weak references.
            func cycle(_ frame: Int64, _ plan: inout ScratchPlanProbe?, _ arena: inout ScratchArena?) -> KernelStatus? {
                ledger.asRender {
                    let status = slot?.beginCycle(frame: frame)
                    slot?.withCurrent { current, scratch in
                        current.link(scratch)
                        plan = current
                        arena = scratch
                    }
                    return status
                }
            }
            #expect(try Self.publish(slot, ScratchPlanProbe(1, scratchBytes: 32, ledger, watch), alignment: 8) == .ok)
            #expect(cycle(1, &firstPlan, &firstArena) == .ok)
            #expect(try Self.publish(slot, ScratchPlanProbe(2, scratchBytes: 64, ledger, watch), alignment: 8) == .ok)
            #expect(cycle(2, &secondPlan, &secondArena) == .ok)  // plan 1 and its arena retire together
            #expect(firstPlan?.serial == 1)
            #expect(firstArena?.byteCapacity == 32)
            #expect(secondArena?.byteCapacity == 64)
            #expect(ledger.deinited.load(ordering: .acquiring) == 0)
            var refused: ScratchPlanProbe? = ScratchPlanProbe(3, scratchBytes: 16, ledger, watch)
            #expect(try slot?.publish(&refused, scratchBytes: 16, alignment: 8) == .refused(.full))
            #expect(refused?.serial == 3)  // handed back; only its fresh, never-lent arena was dropped
            refused = nil
            #expect(ledger.deinited.load(ordering: .acquiring) == 1)
            #expect(slot?.reclaim() == 1)
            #expect(firstPlan == nil)
            #expect(firstArena == nil)
            #expect(watch.aliveAtPlanDeinit.load(ordering: .relaxed) == 1)
            #expect(secondPlan?.serial == 2)
            slot = nil  // teardown on control
            #expect(secondPlan == nil)
            #expect(secondArena == nil)
            #expect(watch.aliveAtPlanDeinit.load(ordering: .relaxed) == 2)
            #expect(watch.goneAtPlanDeinit.load(ordering: .relaxed) == 0)
            #expect(!faults.isLatched(Root.scratchRetireScope))
            #expect(ledger.live == 0)
            #expect(ledger.allOnControl)
        }

        /// Exclusive ownership. A publisher that keeps a strong reference (or passes `nil`) is refused with
        /// `.notOwner`: nothing is published and the plan stays the caller's, so the slot never frees an arena
        /// while an outside alias keeps its plan alive. Once the publisher lets go, the slot's reference is the
        /// plan's last: the slot's release runs the plan's `deinit`, on control, while its arena is alive. A weak
        /// reference neither blocks the publish nor keeps the plan.
        @Test func retainedPublisherIsRefusedAndSoleOwnerDeinitsPlanBeforeArena() throws {
            let ledger = RetireLedger()
            let watch = ScratchArenaWatch()
            let (queue, _) = try Root.scratchRetireQueue(capacity: 1)
            let slot = ScratchProbeSlot(retire: queue)
            var plan: ScratchPlanProbe? = ScratchPlanProbe(1, scratchBytes: 32, ledger, watch)
            var alias = plan
            weak var observer: ScratchPlanProbe?
            observer = plan
            #expect(try slot.publish(&plan, scratchBytes: 32, alignment: 8) == .refused(.notOwner))
            #expect(try slot.publish(&plan, scratchBytes: 0, alignment: 8) == .refused(.notOwner))  // before geometry
            #expect(plan === alias)  // untouched
            #expect(ledger.asRender { slot.beginCycle(frame: 0) } == .empty)  // nothing was published
            #expect(queue.reservedCount == 0)
            var none: ScratchPlanProbe?
            #expect(try slot.publish(&none, scratchBytes: 32, alignment: 8) == .refused(.notOwner))
            alias = nil
            #expect(try slot.publish(&plan, scratchBytes: 32, alignment: 8) == .ok)
            #expect(plan == nil)  // the slot now holds the only strong reference
            #expect(observer?.serial == 1)
            #expect(ledger.asRender { slot.beginCycle(frame: 1) } == .ok)
            ledger.asRender { slot.withCurrent { current, scratch in current.link(scratch) } }
            #expect(try Self.publish(slot, ScratchPlanProbe(2, scratchBytes: 16, ledger, watch), alignment: 8) == .ok)
            #expect(ledger.asRender { slot.beginCycle(frame: 2) } == .ok)  // plan 1 retires with its arena
            #expect(observer != nil)
            #expect(slot.reclaim() == 1)
            #expect(observer == nil)  // the slot's release was the plan's last
            #expect(watch.aliveAtPlanDeinit.load(ordering: .relaxed) == 1)
            #expect(watch.goneAtPlanDeinit.load(ordering: .relaxed) == 0)
            #expect(ledger.allOnControl)
        }

        /// Defensive path (M6): an unreserved retire overfills the queue, so adopting plan 2 stalls plan 1, and the
        /// following cycles adopt nothing (`.refused(.full)`). Each of those cycles still resets the current arena,
        /// and the stalled plan keeps its arena until control reclaims both.
        @Test func refusedCycleStillResetsTheCurrentArena() throws {
            let ledger = RetireLedger()
            let watch = ScratchArenaWatch()
            let (queue, faults) = try Root.scratchRetireQueue(capacity: 1)
            let slot = ScratchProbeSlot(retire: queue)
            /// Render: claims the whole current arena; `nil` when no plan is current.
            func fill() -> Bool? {
                ledger.asRender {
                    slot.withCurrent { plan, scratch in scratch.take(UInt8.self, count: plan.scratchBytes) != nil }
                }
            }
            #expect(try Self.publish(slot, ScratchPlanProbe(1, scratchBytes: 32, ledger, watch), alignment: 8) == .ok)
            #expect(ledger.asRender { slot.beginCycle(frame: 0) } == .ok)
            ledger.asRender { slot.withCurrent { plan, scratch in plan.link(scratch) } }
            // Plan 2 reserves the queue's only slot.
            #expect(try Self.publish(slot, ScratchPlanProbe(2, scratchBytes: 48, ledger, watch), alignment: 8) == .ok)
            let intruder = Unmanaged.passRetained(ScratchPlanProbe(9, scratchBytes: 0, ledger, watch) as AnyObject)
            #expect(ledger.asRender { queue.retire(intruder, frame: 1) } == .ok)  // unreserved: the ring is full
            #expect(ledger.asRender { slot.beginCycle(frame: 2) } == .ok)  // plan 2 adopted; plan 1 stalled
            #expect(faults.observe(Root.scratchRetireScope).flatMap(faults.acknowledge)?.kind == .retireBacklog)
            #expect(fill() == true)
            #expect(fill() == false)  // exhausted for the rest of this cycle
            for frame in 3...4 {
                #expect(ledger.asRender { slot.beginCycle(frame: Int64(frame)) } == .refused(.full))
                #expect(ledger.asRender { slot.withCurrent { plan, _ in plan.serial } } == 2)
                #expect(fill() == true)  // reset although nothing was adopted
            }
            #expect(faults.observe(Root.scratchRetireScope).flatMap(faults.acknowledge)?.firstFrame == 3)
            #expect(slot.reclaim() == 1)  // the intruder
            #expect(watch.aliveAtPlanDeinit.load(ordering: .relaxed) == 0)
            #expect(ledger.asRender { slot.beginCycle(frame: 5) } == .empty)  // the retry retires plan 1
            #expect(fill() == true)
            #expect(slot.reclaim() == 1)  // plan 1, then its arena
            #expect(watch.aliveAtPlanDeinit.load(ordering: .relaxed) == 1)
            #expect(watch.goneAtPlanDeinit.load(ordering: .relaxed) == 0)
            #expect(queue.reservedCount == 0)
            #expect(!faults.isLatched(Root.scratchRetireScope))
            #expect(ledger.allOnControl)
        }
    }
}
