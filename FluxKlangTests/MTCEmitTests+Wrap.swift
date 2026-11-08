import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Drop-frame labels, 24-hour wraps, the decode round trip through `MTCAssembler` and the source gate.
extension MTCEmitTests {
    static func encodedTimes(_ plan: MTCEmitPlan) -> [SMPTETime] {
        positions(plan).map { $0.encoded }
    }

    @Test func dropFrameSequenceOneSkipsTheDroppedLabelsAfterFiftyNineTwentyEight() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 59, 28, .fps2997DropFrame), frames: 4))
        let expected: [UInt8] = [0x0C, 0x11, 0x2B, 0x33, 0x40, 0x50, 0x60, 0x74,
                                 0x02, 0x10, 0x20, 0x30, 0x41, 0x50, 0x60, 0x74]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func aForwardPlanFromTwentyThreeFiftyNineFiftyNineTwentyWrapsPastMidnightAtTwentyFourFps() throws {
        let plan = try Self.plan(Self.request(try Self.time(23, 59, 59, 20, .fps24), frames: 8))
        let expected: [UInt8] = [0x04, 0x11, 0x2B, 0x33, 0x4B, 0x53, 0x67, 0x71,
                                 0x06, 0x11, 0x2B, 0x33, 0x4B, 0x53, 0x67, 0x71,
                                 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70,
                                 0x02, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func aReversePlanFromMidnightPlusOneFrameWrapsBackToTwentyThreeFiftyNineFiftyNineTwentyThree() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 1, .fps24), frames: 4, direction: .reverse))
        let expected: [UInt8] = [0x70, 0x60, 0x50, 0x40, 0x30, 0x20, 0x10, 0x01,
                                 0x71, 0x67, 0x53, 0x4B, 0x33, 0x2B, 0x11, 0x07]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func forwardPlansDecodeThroughTheAssemblerToTheHandTypedTimesAtEachRate() throws {
        let twentyFour = try Self.plan(Self.request(try Self.time(1, 2, 3, 4, .fps24), frames: 4))
        let twentyFive = try Self.plan(Self.request(try Self.time(10, 20, 30, 12, .fps25), frames: 4))
        let dropFrame = try Self.plan(Self.request(try Self.time(0, 9, 59, 28, .fps2997DropFrame), frames: 4))
        let thirty = try Self.plan(Self.request(try Self.time(12, 34, 56, 28, .fps30), frames: 4))
        let first = [try Self.time(1, 2, 3, 4, .fps24), try Self.time(1, 2, 3, 6, .fps24)]
        let second = [try Self.time(10, 20, 30, 12, .fps25), try Self.time(10, 20, 30, 14, .fps25)]
        let third = [try Self.time(0, 9, 59, 28, .fps2997DropFrame), try Self.time(0, 10, 0, 0, .fps2997DropFrame)]
        let fourth = [try Self.time(12, 34, 56, 28, .fps30), try Self.time(12, 34, 57, 0, .fps30)]
        #expect(Self.encodedTimes(twentyFour) == first)
        #expect(Self.encodedTimes(twentyFive) == second)
        #expect(Self.encodedTimes(dropFrame) == third)
        #expect(Self.encodedTimes(thirty) == fourth)
    }

    @Test func reversePlansDecodeThroughTheAssemblerToTheHandTypedTimesAtEachRateWithReverseDirection() throws {
        let twentyFour = try Self.plan(Self.request(try Self.time(1, 0, 0, 0, .fps24), frames: 4, direction: .reverse))
        let twentyFive = try Self.plan(Self.request(try Self.time(0, 0, 0, 1, .fps25), frames: 4, direction: .reverse))
        let dropFrame = try Self.plan(
            Self.request(try Self.time(0, 1, 0, 2, .fps2997DropFrame), frames: 4, direction: .reverse))
        let thirty = try Self.plan(Self.request(try Self.time(0, 0, 1, 0, .fps30), frames: 4, direction: .reverse))
        let first = [try Self.time(1, 0, 0, 0, .fps24), try Self.time(0, 59, 59, 22, .fps24)]
        let second = [try Self.time(0, 0, 0, 1, .fps25), try Self.time(23, 59, 59, 24, .fps25)]
        let third = [try Self.time(0, 1, 0, 2, .fps2997DropFrame), try Self.time(0, 0, 59, 28, .fps2997DropFrame)]
        let fourth = [try Self.time(0, 0, 1, 0, .fps30), try Self.time(0, 0, 0, 28, .fps30)]
        #expect(Self.encodedTimes(twentyFour) == first)
        #expect(Self.encodedTimes(twentyFive) == second)
        #expect(Self.encodedTimes(dropFrame) == third)
        #expect(Self.encodedTimes(thirty) == fourth)
        let directions = [twentyFour, twentyFive, dropFrame, thirty].flatMap { Self.positions($0).map { $0.direction } }
        #expect(directions == Array(repeating: MTCDirection.reverse, count: 8))
    }

    @Test func aTwoHundredFiftySixFramePlanDecodesToOneHundredTwentyEightSequencesEndingAtTenSecondsFour() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps25), frames: 256))
        let times = Self.encodedTimes(plan)
        let last = try #require(times.last)
        let expectedLast = try Self.time(0, 0, 10, 4, .fps25)
        #expect(times.count == 128)
        #expect(last == expectedLast)
    }

    // MARK: Source gate

    static let productionFiles = ["MTCEmitPlan.swift", "MTCEmitRefusal.swift", "MTCEmitTimebase.swift"]

    static let forbiddenWords = [
        "Double", "Float", "Date(", "Clock", "Task", "import SwiftUI", "DispatchQueue", "default:", "try!",
        "fatalError", "static func ==", "static func <", "static func >"
    ]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/MIDI/Timecode/Emit",
            "../../Sources/FluxKlang/Shared/MIDI/Timecode/Emit"
        ]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(productionFiles[0]).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    static func findings(in text: String) -> [String] {
        forbiddenWords.filter { text.contains($0) }
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the emit sources are not next to the tests"))
    func theEmitSourcesContainNoneOfTheListedForbiddenWords() throws {
        let directory = try #require(Self.sourceDirectory())
        for name in Self.productionFiles {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("MTCEmit"), "\(name)")
            #expect(Self.findings(in: text) == [], "\(name)")
        }
    }

    @Test func theSourceScannerFlagsEachForbiddenWordAndNothingInACleanLine() {
        for word in Self.forbiddenWords {
            let flagged = Self.findings(in: "let item = \(word)")
            #expect(flagged == [word], "\(word)")
        }
        let clean = Self.findings(in: "let ticks: [UInt64] = []")
        #expect(clean == [])
    }
}
