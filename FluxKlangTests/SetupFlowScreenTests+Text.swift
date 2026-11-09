//
//  SetupFlowScreenTests+Text.swift
//  FluxKlangTests
//
//  The fixed sentences and labels of the setup flow screen, the muted note, and a scan of the two production files for
//  banned words and for any rule of the reducer.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SetupFlowScreenTests {
    private struct Sentence {
        let refusal: SetupFlowRefusal
        let text: String
    }

    private static func refusalSentences() -> [Sentence] {
        [
            Sentence(refusal: .tooManyRigs(17), text: "Too many rigs are offered."),
            Sentence(refusal: .factOutOfRange(.presentDevices, 2_000), text: "A setup fact is out of range."),
            Sentence(refusal: .duplicateRig(rigA), text: "The same rig is offered twice."),
            Sentence(refusal: .flowEnded, text: "Setup has ended."),
            Sentence(refusal: .suspended, text: "Setup is paused."),
            Sentence(refusal: .notSuspended, text: "Setup is already running."),
            Sentence(refusal: .noNextStep, text: "This is the last step."),
            Sentence(refusal: .noPreviousStep, text: "This is the first step."),
            Sentence(refusal: .wrongStep(expected: .map), text: "That action belongs to another step."),
            Sentence(refusal: .rigNotOffered(rigB), text: "The chosen rig is not offered."),
            Sentence(refusal: .permissionNotGranted(.notDetermined), text: "Audio interface access is not granted."),
            Sentence(refusal: .noPresentDevice, text: "No audio interface is present."),
            Sentence(refusal: .rigNotChosen, text: "Choose a rig first."),
            Sentence(refusal: .rolesUndecided(4_096), text: "Some roles still need a decision."),
            Sentence(refusal: .paneNotReviewed(.home), text: "Confirm the Home pane."),
            Sentence(refusal: .paneNotReviewed(.runtimeMap), text: "Confirm the runtime map pane.")
        ]
    }

    @Test
    func setupFlowScreenRefusalSentencesEqualTheHandTypedTextAndCarryNoPayload() {
        let all = Self.refusalSentences()
        #expect(all.count == 16)
        for item in all {
            let text = SetupFlowScreenText.sentence(for: item.refusal)
            #expect(text == item.text)
        }
        let smallRoles = SetupFlowScreenText.sentence(for: .rolesUndecided(1))
        #expect(smallRoles == "Some roles still need a decision.")
        let otherStep = SetupFlowScreenText.sentence(for: .wrongStep(expected: .decide))
        #expect(otherStep == "That action belongs to another step.")
        let distinct = Set(all.map(\.text))
        #expect(distinct.count == 16)
    }

    @Test
    func setupFlowScreenHeadlinesEqualTheHandTypedTextForEachOfTheSevenPhases() throws {
        let good = try Self.facts()
        let steps: [(SetupFlowStep, String)] = [
            (.identify, "Step 1 of 4: identify your audio interface."),
            (.map, "Step 2 of 4: map the interface to your roles."),
            (.review, "Step 3 of 4: review the Home pane and the runtime map pane."),
            (.decide, "Step 4 of 4: apply the setup or stay manual.")
        ]
        for (step, text) in steps {
            let screen = try Self.screen(after: Self.path(to: step), built: good)
            #expect(screen.headline == text)
        }
        let paused = try Self.screen(after: [.cancel], built: good)
        #expect(paused.headline == "Setup is paused. Reopen it or stay manual.")
        let manual = try Self.screen(after: [.stayManual], built: good)
        #expect(manual.headline == "Setup ended. Manual and remote control stay available.")
        let applied = try Self.screen(after: Self.path(to: .decide) + [.requestApply], built: good)
        #expect(applied.headline == "Setup ended with a request to apply the setup.")
        let offered = try Self.facts(rigs: [Self.rigA])
        let pickedPath = Self.path(to: .decide, pick: Self.rigA) + [.requestApply]
        let withRig = try Self.screen(after: pickedPath, built: offered)
        #expect(withRig.headline == "Setup ended with a request to apply the setup.")
    }

    @Test
    func setupFlowScreenEverySentenceIsNonEmptyAsciiAndAtMostOneHundredTwentyBytes() throws {
        var texts = Self.refusalSentences().map { SetupFlowScreenText.sentence(for: $0.refusal) }
        let good = try Self.facts(lost: 1)
        let applied = Self.path(to: .decide) + [.requestApply]
        let phases: [[SetupFlowEvent]] = [[], [.next], [.cancel], [.stayManual], applied]
        for events in phases {
            let screen = try Self.screen(after: events, built: good)
            texts.append(screen.headline)
            texts.append(screen.manualSentence)
            texts.append(contentsOf: screen.actions.map(\.label))
            texts.append(contentsOf: screen.mutedNote.map { [$0] } ?? [])
        }
        #expect(texts.count > 16)
        for text in texts {
            let bytes = Array(text.utf8)
            #expect(!bytes.isEmpty)
            #expect(bytes.count <= 120)
            let ascii = bytes.allSatisfy { $0 < 0x80 }
            #expect(ascii)
        }
    }

    @Test
    func setupFlowScreenLabelsEqualTheHandTypedTextAndMutedNoteFollowsLostMuted() throws {
        let screen = try Self.screen(after: [], built: try Self.facts(rigs: [Self.rigA, Self.rigB]))
        let expected: [String] = [
            "Next", "Back", "Choose this rig", "Choose this rig", "Confirm the Home pane",
            "Confirm the runtime map pane", "Apply", "Stay manual", "Pause setup", "Reopen setup"
        ]
        #expect(screen.actions.map(\.label) == expected)
        let quiet = try Self.screen(after: [], built: try Self.facts(lost: 0))
        #expect(quiet.mutedNote == nil)
        let note = "Lost or muted devices stay muted. Setup makes no sound."
        let one = try Self.screen(after: [], built: try Self.facts(lost: 1))
        #expect(one.mutedNote == note)
        let most = try Self.screen(after: [], built: try Self.facts(lost: 1_024))
        #expect(most.mutedNote == note)
        let denied = try Self.screen(after: [], built: try Self.facts(access: .denied, present: 0, lost: 1))
        #expect(denied.mutedNote == note)
    }

    @Test
    func setupFlowScreenBlockerSentenceIsTheSentenceOfTheBlockerAndNilExactlyWhenThereIsNone() throws {
        let blocked = try Self.screen(after: [], built: try Self.facts(rigs: [Self.rigA]))
        let blocker = try #require(blocked.blocker)
        #expect(blocked.blockerSentence == SetupFlowScreenText.sentence(for: blocker))
        #expect(blocked.blockerSentence == "Choose a rig first.")
        let free = try Self.screen(after: [], built: try Self.facts())
        let freeBlocker: SetupFlowRefusal? = free.blocker
        #expect(freeBlocker == nil)
        #expect(free.blockerSentence == nil)
    }

    @Test
    func setupFlowScreenEqualInputsGiveEqualScreens() throws {
        let built = try Self.facts(rigs: [Self.rigA, Self.rigB], roles: 1)
        let state = try Self.drive([.chooseRig(Self.rigB)], built)
        let first = SetupFlowScreen.make(state, facts: built)
        let second = SetupFlowScreen.make(state, facts: built)
        #expect(first == second)
        let other = SetupFlowScreen.make(try Self.drive([], built), facts: built)
        #expect(first != other)
    }

    // MARK: - Source scan

    private static func startsAt(_ wanted: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
        guard start + wanted.count <= bytes.count else { return false }
        for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
            return false
        }
        return true
    }

    private static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        for start in 0...(bytes.count - wanted.count) where startsAt(wanted, in: bytes, at: start) {
            return true
        }
        return false
    }

    /// Texts the two production files must not contain, even in a comment: banned APIs and the names the reducer
    /// reads for its gates. Each is joined from pieces, so that no single literal in this list spells a fence token.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["im", "port "].joined(), ["Da", "te"].joined(), ["Dispatch", "Queue"].joined(),
            ["Swift", "UI"].joined(), ["Ta", "sk"].joined(), ["Cl", "ock"].joined(), ["Dou", "ble"].joined(),
            ["Flo", "at"].joined(), ["defa", "ult:"].joined(), ["mutat", "ing"].joined(),
            ["static", " var"].joined(), ["nonisolated", "(unsafe)"].joined(), ["try", "!"].joined(),
            ["Cod", "able"].joined(), ["File", "Manager"].joined(), ["User", "Defaults"].joined(),
            [".acc", "ess"].joined(), ["present", "Devices"].joined(), ["undecided", "Roles"].joined(),
            ["home", "SeenUnder"].joined(), ["runtimeMap", "SeenUnder"].joined(), ["picked", "Rig"].joined(),
            [".mat", "ches("].joined(), ["is", "Empty"].joined()
        ]
    }

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Rig/Setup",
            "../../Sources/FluxKlang/Shared/Rig/Setup"
        ]
        let marker = "SetupFlowScreen.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    @Test
    func setupFlowScreenTheSourceScanFindsAPlantedWordAndNotAnAbsentOne() {
        let word = Self.forbiddenSourceWords().first ?? ""
        #expect(!word.isEmpty)
        let found = Self.containsBytes(word, in: "a " + word + "b")
        #expect(found)
        let missing = Self.containsBytes(word, in: "nothing to see")
        #expect(!missing)
        #expect(Self.forbiddenSourceWords().count == 24)
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the setup flow sources are not next to the tests"))
    func setupFlowScreenTheTwoProductionFilesContainNoBannedWordAndNoGateName() throws {
        let directory = try #require(Self.sourceDirectory(), "the setup flow sources are not next to the tests")
        var hits: [String] = []
        var scanned = 0
        for name in ["SetupFlowScreen.swift", "SetupFlowScreen+Text.swift"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            scanned += 1
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
        }
        #expect(scanned == 2)
        #expect(hits.isEmpty)
    }
}
