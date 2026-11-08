import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The verdict against a per-mille tolerance, and the source scan of the production files.
extension MIDIClockJitterTests {
    static func verdict(_ summary: MIDIClockJitterSummary, perMille: Int) throws(MIDIClockJitterRefusal)
        -> MIDIClockJitterVerdict {
        let tolerance = try MIDIClockJitterTolerance.make(perMille: perMille)
        return summary.verdict(tolerance)
    }

    @Test func aMaximumDeviationOfOneTenthIsExceededAtNinetyNineWithinAtOneHundredAndAbove() throws {
        let summary = try Self.summary(Self.windowA, percentile: 50)
        #expect(summary.maximumDeviationScaled == 100)
        let ninetyNine = try Self.verdict(summary, perMille: 99)
        let hundred = try Self.verdict(summary, perMille: 100)
        let hundredOne = try Self.verdict(summary, perMille: 101)
        #expect(ninetyNine == .exceeded)
        #expect(hundred == .withinTolerance)
        #expect(hundredOne == .withinTolerance)
    }

    @Test func theVerdictJudgesTheMaximumDeviationNotThePercentile() throws {
        let median = try Self.summary(Self.windowA, percentile: 50)
        #expect(median.percentileDeviationScaled == 0)
        let verdict = try Self.verdict(median, perMille: 50)
        #expect(verdict == .exceeded)
    }

    @Test func theVerdictCompareTheScaledDeviationWithTheScaledNominalSpan() throws {
        let summary = try Self.summary(Self.windowB, span: 1_000, pulses: 3)
        #expect(summary.maximumDeviationScaled == 2)
        let onePerMille = try Self.verdict(summary, perMille: 1)
        let twoPerMille = try Self.verdict(summary, perMille: 2)
        #expect(onePerMille == .exceeded)
        #expect(twoPerMille == .withinTolerance)
    }

    @Test func aPerfectWindowIsWithinTheSmallestToleranceAndEqualStampsExceedTheLargest() throws {
        let perfect = try Self.summary(Self.stamps(accumulating: [1_000, 1_000, 1_000]))
        let smallest = try Self.verdict(perfect, perMille: 1)
        #expect(smallest == .withinTolerance)
        let equal = try Self.summary(Self.stamps([5, 5, 5]))
        let largest = try Self.verdict(equal, perMille: 500)
        #expect(largest == .exceeded)
    }

    @Test func theVerdictHoldsAtTheLargestNominalSpanAndTheWidestInterval() throws {
        let top = Int128(1) << 80
        let summary = try Self.summary(Self.stamps([0, UInt64.max]), span: top, pulses: 1)
        let exceeded = try Self.verdict(summary, perMille: 500)
        #expect(exceeded == .exceeded)
        let matching = try Self.summary(Self.stamps([0, UInt64.max]), span: Int128(UInt64.max), pulses: 1)
        let within = try Self.verdict(matching, perMille: 1)
        #expect(matching.maximumDeviationScaled == 0)
        #expect(within == .withinTolerance)
    }

    // MARK: Source scan

    static let productionFiles = [
        "MIDIClockJitterSummary.swift", "MIDIClockJitterNominal.swift", "MIDIClockJitterRefusal.swift"
    ]
    static let forbiddenWords = [
        "Double", "Float", "Date(", "Clock.", "ContinuousClock", "SuspendingClock", "Task", "import SwiftUI",
        "DispatchQueue", "default:", "try!"
    ]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/MIDI/Clock/Jitter",
            "../../Sources/FluxKlang/Shared/MIDI/Clock/Jitter"
        ]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(productionFiles[0]).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    static func findings(in text: String) -> [String] {
        forbiddenWords.filter { text.contains($0) }
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the jitter sources are not next to the tests"))
    func theSourcesContainNoneOfTheListedForbiddenWords() throws {
        let directory = try #require(Self.sourceDirectory())
        for name in Self.productionFiles {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("MIDIClockJitter"), "\(name)")
            #expect(Self.findings(in: text) == [], "\(name)")
        }
    }

    @Test func theSourceScannerFlagsEachForbiddenWordAndNotTheMIDIClockPrefix() {
        for word in Self.forbiddenWords {
            let flagged = Self.findings(in: "let item = \(word)")
            #expect(flagged == [word], "\(word)")
        }
        let clean = Self.findings(in: "let nominal: MIDIClockJitterNominal = MIDIClockArbitrationPolicy.standard")
        #expect(clean == [])
    }
}
