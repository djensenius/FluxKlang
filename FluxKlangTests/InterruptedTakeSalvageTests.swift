import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builds `RecordingSegment` values only through their throwing initializer.
struct InterruptedTakeSegmentSpec {
    var fileStart: Int64
    var frames: Int64
    var startFrame: Int64 = 5_000
    var placement: SegmentPlacement = .placed(startOffsetNs: 0)
    var nominalRate: Int? = 48_000
    var generationValue = 1
    var clock = InterruptedTakeSalvageFixture.clock
    var overflows: [OverflowInterval] = []
    var openedBy: SegmentBoundaryReason?

    func build() throws -> RecordingSegment {
        let generation = try Generation(generationValue)
        return try RecordingSegment(clock: clock, generation: generation, nominalRate: nominalRate,
                                    startFrame: startFrame, placement: placement, fileFrameStart: fileStart,
                                    frames: frames, overflows: overflows, openedBy: openedBy)
    }
}

enum InterruptedTakeSalvageFixture {
    static let clock = ClockID(validated: "smp.main")

    /// Contiguous segments of the given lengths; segment `i` starts at the file frame the previous one ended at.
    static func chain(_ lengths: [Int64]) throws -> [RecordingSegment] {
        var segments: [RecordingSegment] = []
        var fileStart: Int64 = 0
        for length in lengths {
            let spec = InterruptedTakeSegmentSpec(fileStart: fileStart, frames: length, startFrame: fileStart + 5_000)
            segments.append(try spec.build())
            fileStart += length
        }
        return segments
    }

    static func facts(_ segments: [RecordingSegment], durable: Int64, finalized: Bool = true) -> InterruptedTakeFacts {
        InterruptedTakeFacts(segments: segments, durableFileFrames: durable, containerFinalized: finalized)
    }

    static func overflow(_ startFrame: Int64, _ frames: Int64) throws -> OverflowInterval {
        try OverflowInterval(startFrame: startFrame, frames: frames)
    }

    /// The refusal `plan` throws for `facts`, or nil when it plans.
    static func refusal(of facts: InterruptedTakeFacts) -> TakeSalvageRefusal? {
        do {
            _ = try InterruptedTakeSalvage.plan(facts)
            return nil
        } catch {
            return error
        }
    }
}

@Suite("Interrupted take salvage planner")
struct InterruptedTakeSalvageTests {
    typealias Fixture = InterruptedTakeSalvageFixture

    @Test
    func planningTwiceGivesEqualPlansAndTheFactsStillEqualTheirCopy() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let facts = Fixture.facts(segments, durable: 120, finalized: false)
        let copy = facts
        let first = try InterruptedTakeSalvage.plan(facts)
        let second = try InterruptedTakeSalvage.plan(facts)
        #expect(first == second)
        #expect(facts == copy)
    }

    @Test
    func theSegmentLimitIsTheLedgersPerTakeLimit() {
        let limit = InterruptedTakeSalvage.maximumSegments
        let ledgerLimit = TakeLedger.maximumSegmentsPerTake
        let expected = 1_024
        #expect(limit == ledgerLimit)
        #expect(limit == expected)
    }

    private static func sourceDirectory() -> URL? {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            "../Shared/Media/Recording/Recovery",
            "../Sources/FluxKlang/Shared/Media/Recording/Recovery",
            "../../Sources/FluxKlang/Shared/Media/Recording/Recovery"
        ]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("TakeSalvagePlan.swift").path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    @Test(.enabled(if: InterruptedTakeSalvageTests.sourcesAreReachable, "the sources are not next to the tests"))
    func plannerSourcesContainNoneOfTheBannedSubstrings() throws {
        let directory = try #require(Self.sourceDirectory())
        let names = ["InterruptedTakeFacts.swift", "TakeSalvagePlan.swift", "InterruptedTakeSalvage.swift"]
        let banned = ["Date(", "Clock", "Task", "import SwiftUI", "DispatchQueue", "default:", "FileManager",
                      "TakeStopReason", "try!", "fatalError", "String(decoding"]
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let found = banned.filter { text.contains($0) }
            #expect(found.isEmpty, "\(name) names \(found)")
        }
    }
}
