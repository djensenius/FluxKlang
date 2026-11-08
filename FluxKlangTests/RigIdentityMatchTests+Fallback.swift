import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigIdentityFixture {
    /// The directory holding the production sources of this slice, when the checkout (or the mirror) is readable.
    static var identitySourceDirectory: URL? {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [tests.appendingPathComponent("../Shared/Rig/Identity"),
                          tests.appendingPathComponent("../../Sources/FluxKlang/Shared/Rig/Identity")]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("RigSelection.swift").path)
        }
    }

    /// The code lines of `text`: each line without its `//` comment.
    static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "//")[0] }
    }

    /// The code words (comments removed) of `text`.
    static func codeWords(in text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
        let words = codeLines(text).joined(separator: "\n").components(separatedBy: separators)
        return Set(words.filter { !$0.isEmpty })
    }

    static let bannedWords: Set<String> = [
        "AudioRoute", "AudioRouteBinding", "RouteID", "RouteDirection", "route", "routes", "tone", "tones",
        "Date", "Clock", "ContinuousClock", "SuspendingClock", "CoreAudio", "AVFoundation", "UserDefaults",
        "FileManager", "Codable", "Decodable", "Encodable", "Task", "DispatchQueue", "SystemRandomNumberGenerator"
    ]

    /// The banned code words of `text` (sorted), then `global state` when a code line declares a file-scope `var`,
    /// a `static var` or `nonisolated(unsafe)`. A `var` indented inside a body is not global state.
    static func scanFindings(in text: String) -> [String] {
        var found = codeWords(in: text).intersection(bannedWords).sorted()
        let globals = codeLines(text).contains { line in
            line.hasPrefix("var ") || line.contains("static var ") || line.contains("nonisolated(unsafe)")
        }
        if globals { found.append("global state") }
        return found
    }
}

extension RigIdentityMatchTests {
    @Test func anEmptyObservedListIsLegalAndRequiredDevicesFallBackToManualRemote() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a"), Fixture.saved("dev.b", required: false)])
        let report = try Fixture.match(rig, [])
        #expect(report.mode == .manualRemote)
        #expect(report.rows.map(\.outcome) == [.missing, .missing])
        let result = try RigSelection.choose(rigs: [rig], observed: [])
        #expect(result.choice == .none)
    }

    @Test func anEmptyRigIsLegalAndFullWithNoRows() throws {
        let rig = try Fixture.rig("rig.a", [])
        let observed = try [Fixture.device("dev.a")]
        for list in [[], observed] {
            let report = try Fixture.match(rig, list)
            #expect(report.mode == .full)
            #expect(report.rows.isEmpty)
        }
    }

    @Test func anEmptyRigListChoosesNoneWithNoReports() throws {
        let result = try RigSelection.choose(rigs: [], observed: [])
        #expect(result.choice == .none)
        #expect(result.reports.isEmpty)
        #expect(try RigSelection.choose(rigs: [], observed: [Fixture.device("dev.a")]).choice == .none)
    }

    @Test func anEmptyRigIsSelectedWhenNoOtherRigIsFull() throws {
        let rigs = try [Fixture.rig("rig.b", [Fixture.saved("dev.a")]), Fixture.rig("rig.a", [])]
        let result = try RigSelection.choose(rigs: rigs, observed: [])
        #expect(result.choice == .selected(try RigProfileID("rig.a")))
    }

    @Test func aHandBuiltRigOver64DevicesIsRefusedByMatchAndChoose() throws {
        let rig = try Fixture.handBuilt("rig.a", Fixture.savedRun(65))
        let expected = RigIdentityRefusal.tooManyDevices(count: 65, maximum: 64)
        #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: []) } == expected)
        #expect(Fixture.refusal { try RigSelection.choose(rigs: [rig], observed: []) } == expected)
        let huge = try Fixture.handBuilt("rig.a", Fixture.savedRun(5_000))
        let refusal = Fixture.refusal { try RigIdentityMatcher.match(rig: huge, observed: []) }
        #expect(refusal == .tooManyDevices(count: 5_000, maximum: 64))
    }

    @Test func aHandBuiltRigWithARepeatedDeviceIDIsRefusedByMatch() throws {
        let rig = try Fixture.handBuilt("rig.a", [Fixture.saved("dev.a", uid: "u1"), Fixture.saved("dev.a", uid: "u2")])
        let refusal = Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: []) }
        #expect(refusal == .duplicateDevice(try DeviceID("dev.a")))
    }

    @Test func aHandBuiltRigWithARepeatedUIDIsRefusedByMatchAndChoose() throws {
        let rig = try Fixture.handBuilt("rig.a", [Fixture.saved("dev.b", uid: "u1"), Fixture.saved("dev.a", uid: "u1")])
        let expected = RigIdentityRefusal.duplicateUID(first: try DeviceID("dev.a"), second: try DeviceID("dev.b"))
        #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: []) } == expected)
        #expect(Fixture.refusal { try RigSelection.choose(rigs: [rig], observed: []) } == expected)
    }

    @Test func aHandBuiltRigOfCanonicallyEquivalentUIDsIsAcceptedAsTwoDevices() throws {
        let rig = try Fixture.handBuilt("rig.a", [Fixture.saved("dev.a", uid: Fixture.precomposed),
                                                  Fixture.saved("dev.b", uid: Fixture.decomposed)])
        let observed = try [Fixture.device("dev.p", uid: Fixture.precomposed)]
        let report = try Fixture.match(rig, observed)
        #expect(try Fixture.outcome(report, "dev.a") == .renumbered(from: DeviceID("dev.a"), to: DeviceID("dev.p")))
        #expect(try Fixture.outcome(report, "dev.b") == .missing)
    }

    @Test func refusedCallsReportTheirExactRefusalAndLaterCallsGiveTheSameResults() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a"), Fixture.saved("dev.b")])
        let observed = try [Fixture.device("dev.a"), Fixture.device("dev.z", uid: "uid-dev.b")]
        let matched = try Fixture.match(rig, observed)
        let chosen = try RigSelection.choose(rigs: [rig], observed: observed)
        let repeated = observed + [try Fixture.device("dev.a", uid: "uid-other")]
        let bad = try Fixture.handBuilt("rig.bad", Fixture.savedRun(65))
        let oversized = RigIdentityRefusal.tooManyDevices(count: 65, maximum: 64)
        let repeatedRefusal = Fixture.refusal { try RigIdentityMatcher.match(rig: rig, observed: repeated) }
        #expect(repeatedRefusal == .duplicateObservedDevice(try DeviceID("dev.a")))
        #expect(Fixture.refusal { try RigIdentityMatcher.match(rig: bad, observed: observed) } == oversized)
        #expect(Fixture.refusal { try RigSelection.choose(rigs: [rig, bad], observed: observed) } == oversized)
        #expect(try Fixture.match(rig, observed) == matched)
        #expect(try RigSelection.choose(rigs: [rig], observed: observed) == chosen)
    }

    @Test func anEmptyRigAndARealFullRigAreAmbiguousSoABlankRigBlocksAutoSelection() throws {
        let rigs = try [Fixture.rig("rig.real", [Fixture.saved("dev.a")]), Fixture.rig("rig.blank", [])]
        let observed = try [Fixture.device("dev.a")]
        let expected = RigChoice.ambiguous([try RigProfileID("rig.blank"), try RigProfileID("rig.real")])
        #expect(try RigSelection.choose(rigs: rigs, observed: observed).choice == expected)
    }

    @Test func rigFactoryReportsTheFirstOfTwoRepeatedUIDPairsInEitherOrder() throws {
        let devices = try [Fixture.saved("dev.d", uid: "u1"), Fixture.saved("dev.c", uid: "u2"),
                           Fixture.saved("dev.b", uid: "u2"), Fixture.saved("dev.a", uid: "u1")]
        let expected = RigIdentityRefusal.duplicateUID(first: try DeviceID("dev.b"), second: try DeviceID("dev.c"))
        for order in [devices, Array(devices.reversed())] {
            let refusal = Fixture.refusal { try RigSavedRig.make(id: RigProfileID("rig.a"), devices: order) }
            #expect(refusal == expected)
        }
    }

    @Test func uidsDifferingOnlyInCaseOrSpacingStayDistinct() throws {
        let rig = try Fixture.rig("rig.a", [Fixture.saved("dev.a", uid: "Uid A")])
        let lookalikes = try [Fixture.device("dev.b", uid: "uid a"), Fixture.device("dev.c", uid: "Uid  A"),
                              Fixture.device("dev.d", uid: "Uid A ")]
        #expect(try Fixture.outcome(Fixture.match(rig, lookalikes), "dev.a") == .missing)
        let exact = lookalikes + [try Fixture.device("dev.e", uid: "Uid A")]
        let outcome = try Fixture.outcome(Fixture.match(rig, exact), "dev.a")
        #expect(outcome == .renumbered(from: try DeviceID("dev.a"), to: try DeviceID("dev.e")))
    }

    @Test(.enabled(if: RigIdentityFixture.identitySourceDirectory != nil, "the identity sources are not reachable"))
    func identitySourcesNameNoRouteToneClockPersistenceOrGlobalState() throws {
        let directory = try #require(RigIdentityFixture.identitySourceDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let files = names.filter { $0.hasSuffix(".swift") }
        let known = ["RigIdentityMatcher.swift", "RigIdentityRefusal.swift", "RigSavedDevice.swift",
                     "RigSelection.swift"]
        #expect(Set(known).isSubset(of: Set(files)))
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            #expect(Fixture.scanFindings(in: text).isEmpty, "\(file) names \(Fixture.scanFindings(in: text))")
        }
    }

    @Test func theSourceScannerFlagsCodeNamesAndIgnoresComments() {
        #expect(Fixture.scanFindings(in: "let kind = AudioRoute.self // a route and a tone\n") == ["AudioRoute"])
        #expect(Fixture.scanFindings(in: "let value = 1 // route tone Date Clock CoreAudio\n").isEmpty)
        #expect(Fixture.scanFindings(in: "let stamp = Date()\nlet tone = 1\n") == ["Date", "tone"])
        #expect(Fixture.scanFindings(in: "let router = 1\nlet routed = 2\n").isEmpty)
    }

    @Test func theSourceScannerFlagsGlobalStateButNotLocalVariables() {
        #expect(Fixture.scanFindings(in: "var counter = 0\n") == ["global state"])
        #expect(Fixture.scanFindings(in: "enum E {\n    static var shared = 0\n}\n") == ["global state"])
        #expect(Fixture.scanFindings(in: "nonisolated(unsafe) let box = 0\n") == ["global state"])
        #expect(Fixture.scanFindings(in: "func f() {\n    var local = 0\n    local += 1\n}\n").isEmpty)
        #expect(Fixture.scanFindings(in: "// var counter = 0\nlet value = 1\n").isEmpty)
    }
}
