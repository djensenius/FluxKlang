import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformRecallTests {
    /// Facts that would drop or refuse a press or confirm, plus the passing facts; cancel and settle get each.
    private static func hostileFacts() -> [PerformRecallFacts] {
        [
            facts(.live), facts(.live).resynced(), facts(.live).epoched(epochOtherHost), facts(.live).unpermitted(),
            facts(.live).targetless(), facts(.structural), facts(.live).readied(.failed)
        ]
    }

    @Test func performRecallCancelGivesTheSameStepUnderSevenFactSetsAndEachPhase() {
        for facts in Self.hostileFacts() {
            Self.expectStep(Self.step(.awaitingConfirm(Self.epochA), .cancel, facts), .idle, .released)
            Self.expectStep(Self.step(.idle, .cancel, facts), .idle, .refused(.notAwaitingConfirm))
            let fired = Self.step(.fired(Self.epochA), .cancel, facts)
            Self.expectStep(fired, .fired(Self.epochA), .refused(.alreadyFired))
        }
    }

    @Test func performRecallSettleGivesTheSameStepUnderSevenFactSetsAndEachPhase() {
        for facts in Self.hostileFacts() {
            Self.expectStep(Self.step(.fired(Self.epochA), .settle, facts), .idle, .released)
            Self.expectStep(Self.step(.idle, .settle, facts), .idle, .refused(.nothingFired))
            let awaiting = Self.step(.awaitingConfirm(Self.epochA), .settle, facts)
            Self.expectStep(awaiting, .awaitingConfirm(Self.epochA), .refused(.nothingFired))
        }
    }

    @Test func performRecallSettleReleasesAFiredPhaseHeldUnderAnEpochThatIsNoLongerLive() throws {
        let newer = try Self.epochAt(2)
        let outcome = Self.step(.fired(Self.epochA), .settle, Self.facts(.live).epoched(newer))
        Self.expectStep(outcome, .idle, .released)
    }

    @Test func performRecallAfterACancelTheNextPressAsksAgainAndAfterASettleTheNextPressFires() throws {
        let facts = Self.facts(.hazardous)
        let asked = Self.step(.idle, .press, facts)
        let cancelled = Self.step(asked.phase, .cancel, facts)
        Self.expectStep(cancelled, .idle, .released)
        let askedAgain = Self.step(cancelled.phase, .press, facts)
        Self.expectStep(askedAgain, .awaitingConfirm(Self.epochA), .awaitConfirm)
        let confirmed = Self.step(askedAgain.phase, .confirm, facts)
        let settled = Self.step(confirmed.phase, .settle, facts)
        let fresh = Self.step(settled.phase, .press, Self.facts(.live))
        #expect(Self.isFire(fresh))
    }

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Views/Workspace/Perform/Recall",
            "../../Sources/FluxKlang/Shared/Views/Workspace/Perform/Recall"
        ]
        let marker = "PerformRecallReducer.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["import", " "].joined(), ["Da", "te("].joined(), ["Cl", "ock"].joined(), ["Ta", "sk"].joined(),
            ["Dispatch", "Queue"].joined(), ["Swift", "UI"].joined(), ["Dou", "ble"].joined(),
            ["Fl", "oat"].joined(), ["defa", "ult:"].joined(), ["mutat", "ing"].joined(),
            ["static ", "var"].joined(), ["nonisolated", "(unsafe)"].joined(), ["try", "!"].joined(),
            ["fatal", "Error"].joined(), ["static func ", "=="].joined(), ["static func ", "<"].joined(),
            ["static func ", "+"].joined()
        ]
    }

    /// Looks for each text of `forbiddenSourceWords()` in the three new production files. The search is over the raw
    /// text, comments included, and finds only the listed texts. It is skipped when the sources are not next to the
    /// tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the recall sources are not next to the tests"))
    func performRecallTheThreeProductionFilesContainNoForbiddenText() throws {
        let directory = try #require(Self.sourceDirectory(), "the recall sources are not next to the tests")
        let names = ["PerformRecallModel.swift", "PerformRecallReason.swift", "PerformRecallReducer.swift"]
        var hits: [String] = []
        var scanned = 0
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in Self.forbiddenSourceWords() where text.range(of: word, options: .literal) != nil {
                hits.append("\(name): \(word)")
            }
        }
        #expect(scanned == 3)
        #expect(hits.isEmpty, "\(hits)")
    }
}
