import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `settle` and the composition with the real feedback echo check. The planner appears only here: the dispatcher
/// itself never calls it, the caller does between `admit` and `settle`.
extension ControlLocalDispatchTests {
    private static func percent(_ value: Double) -> ParameterValue {
        ParameterValue(value: value, unit: .percent)
    }

    private static func standardAdmission() throws -> ControlLocalAdmission {
        try Fx.admit(Fx.standardBindings())
    }

    private static func isMessage(_ result: ControlFeedbackResult) -> Bool {
        if case .message = result { return true }
        return false
    }

    private static func planner() throws -> ControlFeedbackPlanner {
        let policy = try ControlFeedbackPolicy(
            bindingCapacity: 16, holdCapacity: 4, windowTicks: 10, holdTimeoutTicks: 100, emitBudget: 3
        )
        return ControlFeedbackPlanner(policy: policy)
    }

    // MARK: Goldens

    @Test func settleProposesTheJumpBindingAndHoldsTheCatchBindingAgainstHostTruth() throws {
        let admission = try Self.standardAdmission()
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        let proposal = try #require(result.proposals.first)
        #expect(result.proposals.count == 1)
        #expect(proposal.binding == Fx.aJump)
        #expect(proposal.target == Fx.level)
        #expect(proposal.operation == .set(Fx.level, Self.percent(100)))
        let hold = try #require(result.holds.first)
        #expect(result.holds.count == 1)
        #expect(hold.binding == Fx.bCatch)
        #expect(hold.hardware == 1)
        #expect(hold.target == 0.5)
        #expect(hold.reason == .notCaught)
        #expect(result.echoed.isEmpty)
        let mismatch = ControlIntakeRefusal.widthMismatch(messageBits: 7, profileBits: 14)
        #expect(result.refusals == [.bindingIntake(Fx.dRel, mismatch)])
    }

    @Test func settleHoldsACatchBindingWhoseTargetLiesAboveItsRangeWithThatReason() throws {
        let bounded = try Fx.binding(Fx.bCatch, pickup: .catch, upper: 20)
        let admission = try Fx.admit([bounded])
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        let hold = try #require(result.holds.first)
        #expect(result.holds.count == 1)
        #expect(hold.binding == Fx.bCatch)
        #expect(hold.reason == .targetAboveRange)
        #expect(result.proposals.isEmpty)
    }

    @Test func settleReportsTheNewPickupStateOfEveryBindingThatResolved() throws {
        let admission = try Self.standardAdmission()
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        let updates = result.pickupUpdates
        #expect(updates.count == 2)
        let first = try #require(updates.first)
        #expect(first.binding == Fx.aJump)
        #expect(first.state == .engaged(hardware: 1))
        let last = try #require(updates.last)
        #expect(last.binding == Fx.bCatch)
        #expect(last.state == .waiting(hardware: 1))
    }

    @Test func settleListsAnEchoedBindingAloneAndStillResolvesTheOthers() throws {
        let admission = try Self.standardAdmission()
        let result = try ControlLocalDispatch.settle(admission, echoes: [Fx.aJump], truth: Fx.truth())
        #expect(result.echoed == [Fx.aJump])
        #expect(result.proposals.isEmpty)
        let hold = try #require(result.holds.first)
        #expect(hold.binding == Fx.bCatch)
        let update = try #require(result.pickupUpdates.first)
        #expect(result.pickupUpdates.count == 1)
        #expect(update.binding == Fx.bCatch)
    }

    @Test func settleAppliesARelativeDeltaFromHostTruth() throws {
        let narrow = EncoderProfile.twosComplement(width: .seven)
        let bindings = try [Fx.relative(Fx.dRel, profile: narrow)]
        let admission = try Fx.admit(bindings, update: Fx.controller(70, 1))
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        let proposal = try #require(result.proposals.first)
        #expect(proposal.operation == .set(Fx.level, Self.percent(51)))
        let update = try #require(result.pickupUpdates.first)
        #expect(update.state == .engaged(hardware: nil))
    }

    @Test func settleReportsAnUnchangedBindingOnlyThroughItsPickupUpdate() throws {
        let admission = try Fx.admit([Fx.binding(Fx.aJump)])
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth(host: 100))
        #expect(result.proposals.isEmpty)
        #expect(result.holds.isEmpty)
        #expect(result.refusals.isEmpty)
        let update = try #require(result.pickupUpdates.first)
        #expect(result.pickupUpdates.count == 1)
        #expect(update.state == .engaged(hardware: 1))
    }

    // MARK: Refusals and order

    @Test func settleOfARefusedAdmissionReturnsOnlyItsRefusalsAndReadsNoEchoOrTruth() throws {
        let admission = try Fx.admit(Fx.standardBindings(), update: Fx.noteOn)
        let result = try ControlLocalDispatch.settle(admission, echoes: [Fx.aJump], truth: Fx.truthWithoutLevel())
        #expect(result.refusals == [.intake(.notControlInput)])
        #expect(result.proposals.isEmpty)
        #expect(result.holds.isEmpty)
        #expect(result.echoed.isEmpty)
        #expect(result.pickupUpdates.isEmpty)
    }

    @Test func settleListsAnEchoWithoutReadingAHostTruthThatLacksItsTarget() throws {
        let admission = try Self.standardAdmission()
        let result = try ControlLocalDispatch.settle(admission, echoes: [Fx.aJump], truth: Fx.truthWithoutLevel())
        let mismatch = ControlIntakeRefusal.widthMismatch(messageBits: 7, profileBits: 14)
        let admitted = ControlLocalDispatchRefusal.bindingIntake(Fx.dRel, mismatch)
        let missing = ControlLocalDispatchRefusal.binding(Fx.bCatch, .targetMissing(Fx.level))
        #expect(result.echoed == [Fx.aJump])
        #expect(result.refusals == [admitted, missing])
        #expect(result.proposals.isEmpty)
        #expect(result.pickupUpdates.isEmpty)
    }

    @Test func settleListsSeveralEchoedBindingsInTheAdmissionOrder() throws {
        let admission = try Self.standardAdmission()
        let both: Set<BindingID> = [Fx.bCatch, Fx.aJump]
        let result = try ControlLocalDispatch.settle(admission, echoes: both, truth: Fx.truth())
        let expected = [Fx.aJump, Fx.bCatch]
        #expect(result.echoed == expected)
        #expect(result.proposals.isEmpty)
        #expect(result.holds.isEmpty)
    }

    @Test func settleKeepsTheEntryOfARefusedBindingOutOfThePickupUpdates() throws {
        let bindings = try [Fx.binding(Fx.aJump), Fx.binding(Fx.bCatch, pickup: .catch)]
        var table = Fx.fresh(bindings)
        table[Fx.bCatch] = .unavailable
        let admission = try Fx.admit(bindings, pickup: table)
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        #expect(result.refusals == [.binding(Fx.bCatch, .pickupUnavailable)])
        let update = try #require(result.pickupUpdates.first)
        #expect(result.pickupUpdates.count == 1)
        #expect(update.binding == Fx.aJump)
    }

    @Test func settleAppendsItsRefusalsAfterTheAdmissionRefusalsWithoutMerging() throws {
        let bindings = try [Fx.binding(Fx.aJump), Fx.relative(Fx.bCatch), Fx.binding(Fx.cOther)]
        var table = Fx.fresh(bindings)
        table[Fx.cOther] = .unavailable
        let admission = try Fx.admit(bindings, pickup: table)
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        let mismatch = ControlIntakeRefusal.widthMismatch(messageBits: 7, profileBits: 14)
        let first = ControlLocalDispatchRefusal.bindingIntake(Fx.bCatch, mismatch)
        let second = ControlLocalDispatchRefusal.binding(Fx.cOther, .pickupUnavailable)
        #expect(result.refusals == [first, second])
        let reversed = ControlLocalDispatchRefusal.binding(Fx.aJump, .pickupUnavailable)
        #expect(result.refusals.contains(reversed) == false)
    }

    @Test func settleIgnoresEchoIdsThatAreNotCandidatesWhateverTheirNumber() throws {
        let admission = try Self.standardAdmission()
        let plain = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth())
        var strays: Set<BindingID> = [Fx.cOther, Fx.dRel]
        for index in 0..<4096 {
            let stray = try BindingID("bnd.stray\(index)")
            strays.insert(stray)
        }
        let large = try ControlLocalDispatch.settle(admission, echoes: strays, truth: Fx.truth())
        #expect(strays.count == 4098)
        #expect(large == plain)
    }

    @Test func aPairedFourteenBitUpdateIsHeardOnItsCc14SourceAndSettlesToTheProposalsOfTheWideBindings() throws {
        let wideAbsolute = try Fx.binding(Fx.aJump, source: Fx.pair7, profile: .absolute(resolution: 16383))
        let narrow = try Fx.binding(Fx.bCatch, source: Fx.pad7)
        let wideRelative = try Fx.relative(Fx.dRel, source: Fx.pair7, profile: .binaryOffset(width: .fourteen))
        let bindings = [narrow, wideRelative, wideAbsolute]
        let update = MIDI1StateUpdate(channel: 1, effect: .controller14(7, value: 8191))
        let admission = try Fx.admit(bindings, update: update)
        #expect(admission.refusals.isEmpty)
        try #require(admission.candidates.count == 2)
        let absolute = admission.candidates[0]
        #expect(absolute.binding.id == Fx.aJump)
        #expect(absolute.input == .absolute(normalized: 0.5))
        let relative = admission.candidates[1]
        #expect(relative.binding.id == Fx.dRel)
        #expect(relative.input == .relative(delta: -1))
        let result = try ControlLocalDispatch.settle(admission, echoes: [], truth: Fx.truth(host: 20))
        #expect(result.refusals.isEmpty)
        #expect(result.holds.isEmpty)
        try #require(result.proposals.count == 2)
        #expect(result.proposals[0].binding == Fx.aJump)
        #expect(result.proposals[0].operation == .set(Fx.level, Self.percent(50)))
        #expect(result.proposals[1].binding == Fx.dRel)
        #expect(result.proposals[1].operation == .set(Fx.level, Self.percent(19)))
    }

    @Test func admitAndSettleGiveEqualResultsOnTwoCallsWithEqualInputs() throws {
        let bindings = try Fx.standardBindings()
        let first = try Fx.admit(bindings)
        let second = try Fx.admit(bindings)
        #expect(first == second)
        let truth = try Fx.truth()
        let settledFirst = ControlLocalDispatch.settle(first, echoes: [Fx.aJump], truth: truth)
        let settledSecond = ControlLocalDispatch.settle(second, echoes: [Fx.aJump], truth: truth)
        #expect(settledFirst == settledSecond)
    }

    // MARK: Composition with the feedback echo check

    @Test func aPositionTheControllerWasJustSentIsAnEchoAndSettleProposesNothingForIt() throws {
        var planner = try Self.planner()
        let jump = try Fx.binding(Fx.aJump)
        let truth = try Fx.truth()
        let told = try planner.plan([jump], truth: truth, reason: .refresh, now: 1)
        let outcome = try #require(told.first)
        #expect(Self.isMessage(outcome.result))
        let admission = try Fx.admit([jump], update: Fx.controller(70, 64))
        let candidate = try #require(admission.candidates.first)
        let inbound = try planner.receive(candidate.input, for: candidate.binding, truth: truth, now: 2)
        #expect(inbound == .echo)
        let result = ControlLocalDispatch.settle(admission, echoes: [candidate.binding.id], truth: truth)
        #expect(result.proposals.isEmpty)
        #expect(result.echoed == [Fx.aJump])
    }

    @Test func aPositionTheControllerWasNotSentIsAMoveAndSettleProposesTheWrite() throws {
        var planner = try Self.planner()
        let jump = try Fx.binding(Fx.aJump)
        let truth = try Fx.truth()
        _ = try planner.plan([jump], truth: truth, reason: .refresh, now: 1)
        let admission = try Fx.admit([jump], update: Fx.controller(70, 127))
        let candidate = try #require(admission.candidates.first)
        let inbound = try planner.receive(candidate.input, for: candidate.binding, truth: truth, now: 2)
        #expect(inbound == .move)
        let result = ControlLocalDispatch.settle(admission, echoes: [], truth: truth)
        let proposal = try #require(result.proposals.first)
        #expect(proposal.operation == .set(Fx.level, Self.percent(100)))
        #expect(result.echoed.isEmpty)
    }

    @Test func admitDoesNotDependOnTheFeedbackStateTheCallerKeeps() throws {
        var planner = try Self.planner()
        let jump = try Fx.binding(Fx.aJump)
        let before = try Fx.admit([jump], update: Fx.controller(70, 64))
        _ = try planner.plan([jump], truth: Fx.truth(), reason: .refresh, now: 1)
        let candidate = try #require(before.candidates.first)
        _ = try planner.receive(candidate.input, for: candidate.binding, truth: Fx.truth(), now: 1)
        let after = try Fx.admit([jump], update: Fx.controller(70, 64))
        #expect(after == before)
    }

    // MARK: Sources

    private static func glued(_ head: String, _ tail: String) -> String {
        "\(head)\(tail)"
    }

    private static let sourceNames = ["ControlLocalDispatch.swift", "ControlLocalDispatchRefusal.swift"]

    /// The two production files, read from the checkout or from the package mirror; empty when absent.
    static func dispatchSourceTexts() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Control/Dispatch/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = sourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == sourceNames.count { return texts }
        }
        return []
    }

    @Test(.enabled(if: !ControlLocalDispatchTests.dispatchSourceTexts().isEmpty))
    func theTwoDispatchSourcesNameNoFeedbackStateGateImportTimeQueueViewOrMutation() {
        let texts = Self.dispatchSourceTexts()
        #expect(texts.count == 2)
        let banned = [
            "ControlFeedbackPlanner", "ControlInputGate", "ControlFeedbackEcho", "LearnSession", "import ",
            "Foundation",
            Self.glued("Ta", "sk"), Self.glued("Clo", "ck"), Self.glued("default", ":"), "Date", "DispatchQueue",
            "SwiftUI", "try!", "fatalError", "mutating", "static var", "Float", ".sorted(", ".filter("
        ]
        for text in texts {
            for token in banned { #expect(!text.contains(token), "\(token)") }
        }
    }

    @Test(.enabled(if: !ControlLocalDispatchTests.dispatchSourceTexts().isEmpty))
    func theDispatchSourceCodeLinesNameTheDoubleTypeExactlyFourTimes() throws {
        let texts = Self.dispatchSourceTexts()
        let text = try #require(texts.first)
        let codeLines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let code = codeLines.joined(separator: "\n")
        let parts = code.components(separatedBy: "Double")
        #expect(parts.count == 5)
    }
}
