import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension KernelRetirementCarryTests {
    @Test func carryCapacityIsTwoHundredFiftySixAndWithinTheMaximumBlockCapacity() {
        #expect(KernelRetirementCarry.capacity == 256)
        #expect(KernelRetirementCarry.capacity <= KernelCycle.maximumBlockCapacity)
    }

    @Test func carryStoresTwoHundredFiftyFiveAndThenTwoHundredFiftySixEventsWithoutDrops() {
        var carry = KernelRetirementCarry()
        let events = Self.distinctControls(256)
        for event in events.prefix(255) { #expect(carry.record(event) == .stored) }
        #expect(carry.count == 255)
        #expect(carry.droppedForCapacity == 0)
        #expect(carry.record(events[255]) == .stored)
        #expect(carry.count == 256)
        #expect(carry.droppedForCapacity == 0)
    }

    @Test func carryReportsTheTwoHundredFiftySeventhAsDroppedFullAndCountsEachFurtherDrop() {
        var carry = Self.carry(Self.distinctControls(256))
        let extra = Self.distinctControls(259)
        #expect(carry.record(extra[256]) == .droppedFull)
        #expect(carry.count == 256)
        #expect(carry.droppedForCapacity == 1)
        #expect(carry.record(extra[257]) == .droppedFull)
        #expect(carry.record(extra[258]) == .droppedFull)
        #expect(carry.count == 256)
        #expect(carry.droppedForCapacity == 3)
    }

    @Test func carryNeverOverwritesAStoredEventWhenFull() throws {
        let events = Self.distinctControls(260)
        let carry = Self.carry(events)
        #expect(carry.events == Array(events.prefix(256)))
        #expect(try #require(carry.event(at: 0)) == events[0])
        #expect(try #require(carry.event(at: 255)) == events[255])
    }

    @Test func carryStoresControlProgramAndRampTargetsAsStored() {
        var carry = KernelRetirementCarry()
        #expect(carry.record(Self.control()) == .stored)
        #expect(carry.record(Self.program()) == .stored)
        #expect(carry.record(Self.ramp()) == .stored)
        #expect(carry.count == 3)
    }

    @Test func carryRefusesNoteOnNoteOffAndClockPulseAsNotStatefulAndChangesNothing() {
        var carry = Self.carry([Self.control(), Self.ramp(parameter: 4)])
        let before = carry
        #expect(carry.record(Self.noteOn()) == .notStateful)
        #expect(carry.record(Self.noteOff()) == .notStateful)
        #expect(carry.record(Self.clockPulse()) == .notStateful)
        #expect(carry == before)
        #expect(carry.count == 2)
    }

    @Test func carryFullCarryCountsOnlyStatefulDropsAndReportsOthersAsNotStateful() {
        var carry = Self.carry(Self.distinctControls(256))
        #expect(carry.record(Self.noteOn()) == .notStateful)
        #expect(carry.record(Self.noteOff()) == .notStateful)
        #expect(carry.record(Self.clockPulse()) == .notStateful)
        #expect(carry.droppedForCapacity == 0)
        #expect(carry.record(Self.program()) == .droppedFull)
        #expect(carry.record(Self.ramp()) == .droppedFull)
        #expect(carry.droppedForCapacity == 2)
    }

    @Test func carryEventAccessIsNilOutsideTheRecordedRange() throws {
        let carry = Self.carry([Self.control(sequence: 1), Self.control(controller: 2, sequence: 2)])
        #expect(KernelRetirementCarry().event(at: 0) == nil)
        #expect(carry.event(at: -1) == nil)
        #expect(try #require(carry.event(at: 0)).sequence == 1)
        #expect(try #require(carry.event(at: 1)).sequence == 2)
        #expect(carry.event(at: 2) == nil)
    }

    @Test func carryEventsAreInRecordedOrderNotFrameOrder() {
        let late = Self.control(frame: 90, controller: 1, sequence: 1)
        let early = Self.program(frame: 10, sequence: 2)
        let middle = Self.ramp(frame: 50, sequence: 3)
        #expect(Self.carry([late, early, middle]).events == [late, early, middle])
    }

    @Test func carryEqualityComparesFrameScopeSequencePayloadCountAndDroppedCounter() {
        let base = Self.control(frame: 4, controller: 9, value: 1, sequence: 6)
        let differing = [
            Self.control(frame: 5, controller: 9, value: 1, sequence: 6),
            Self.control(frame: 4, controller: 9, value: 2, sequence: 6),
            Self.control(frame: 4, controller: 9, value: 1, sequence: 7),
            KernelEvent(frame: 4, scope: 8, sequence: 6, payload: base.payload)
        ]
        for other in differing { #expect(Self.carry([base]) != Self.carry([other])) }
        #expect(Self.carry([base]) == Self.carry([base]))
        #expect(Self.carry([base]) != Self.carry([base, base]))
        #expect(Self.carry([base, Self.program()]) != Self.carry([Self.program(), base]))
        #expect(Self.carry(Self.distinctControls(256)) != Self.carry(Self.distinctControls(257)))
    }

    @Test func carryEqualityTreatsANaNRampAsItselfAndOneRampValueAsAnother() {
        let invalid = Self.ramp(parameter: 2, value: .nan, duration: -3)
        #expect(Self.carry([invalid]) == Self.carry([invalid]))
        #expect(Self.carry([Self.ramp(value: 0)]) != Self.carry([Self.ramp(value: -0.0)]))
        #expect(Self.carry([Self.ramp(duration: 1)]) != Self.carry([Self.ramp(duration: 2)]))
        #expect(Self.carry([Self.ramp(parameter: 1)]) != Self.carry([Self.ramp(parameter: 2)]))
    }

    @Test func carryRecordsAnInvalidRampWithoutRefusingAtRecordTime() {
        var carry = KernelRetirementCarry()
        #expect(carry.record(Self.ramp(value: .nan, duration: -1)) == .stored)
        #expect(carry.record(Self.ramp(parameter: 2, value: .infinity)) == .stored)
        #expect(carry.count == 2)
    }

    @Test func carryTypesConformToBitwiseCopyableAndSendableAtCompileTime() {
        func requiresBitwiseCopyable<T: BitwiseCopyable & Sendable>(_: T.Type) -> Bool { true }
        #expect(requiresBitwiseCopyable(KernelRetirementCarry.self))
        #expect(requiresBitwiseCopyable(KernelRetirementCarry.RecordResult.self))
    }

    #if DEBUG
    @Test func carryDroppedCounterSaturatesAtIntMax() {
        var carry = KernelRetirementCarry(seedingDroppedForCapacity: Int.max - 2)
        for event in Self.distinctControls(256) { carry.record(event) }
        #expect(carry.droppedForCapacity == Int.max - 2)
        #expect(carry.record(Self.program()) == .droppedFull)
        #expect(carry.droppedForCapacity == Int.max - 1)
        #expect(carry.record(Self.program()) == .droppedFull)
        #expect(carry.droppedForCapacity == Int.max)
        #expect(carry.record(Self.program()) == .droppedFull)
        #expect(carry.droppedForCapacity == Int.max)
    }
    #endif

    // MARK: record contains no Array mutation (source scan)

    private static let arrayTokens = [
        ".append", ".insert", ".remove", ".popLast", ".replaceSubrange", ".swapAt", ".sort", ".reverse",
        "reserveCapacity", "Array", "[KernelEvent]"
    ]

    /// The text between the braces of the function whose declaration starts with `declaration`.
    static func functionBody(_ declaration: String, in text: String) -> String? {
        guard let start = text.range(of: declaration), let open = text[start.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[text.index(after: open)..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The array-mutating tokens in `body`, ignoring `//` comments.
    static func arrayMutations(in body: String) -> [String] {
        let code = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
        return arrayTokens.filter { code.contains($0) }
    }

    private static func eventsDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Audio/Kernel/Events", "../../Sources/FluxKlang/Shared/Audio/Kernel/Events"]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(carrySource).path) }
    }

    private static let carrySource = "KernelRetirementCarry.swift"

    private static let sourcesAreReachable = eventsDirectory() != nil

    @Test(.enabled(if: Self.sourcesAreReachable, "the kernel sources are not next to the tests"))
    func carryRecordSourceContainsNoArrayMutation() throws {
        let directory = try #require(Self.eventsDirectory())
        let text = try String(contentsOf: directory.appendingPathComponent(Self.carrySource), encoding: .utf8)
        let body = try #require(Self.functionBody("mutating func record(", in: text))
        #expect(body.contains("storage[count] = event"))
        #expect(Self.arrayMutations(in: body).isEmpty)
    }

    @Test func carryArrayScannerFlagsAnArrayMutationAndAcceptsAnInlineWrite() throws {
        let flagged = "func a() {\n    stash.append(event)\n}\n"
        let clean = "func b() {\n    storage[count] = event // not .append\n    count += 1\n}\n"
        let nested = "mutating func record(_ e: KernelEvent) {\n    if full { return }\n"
            + "    let x = Array(repeating: e, count: 1)\n}\n"
        let appended = try #require(Self.functionBody("func a(", in: flagged))
        let inlineWrite = try #require(Self.functionBody("func b(", in: clean))
        let arrayed = try #require(Self.functionBody("mutating func record(", in: nested))
        #expect(Self.arrayMutations(in: appended) == [".append"])
        #expect(Self.arrayMutations(in: inlineWrite).isEmpty)
        #expect(Self.arrayMutations(in: arrayed) == ["Array"])
        #expect(Self.functionBody("func missing(", in: clean) == nil)
    }
}
