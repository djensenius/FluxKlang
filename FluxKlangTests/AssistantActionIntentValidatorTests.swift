import Foundation
import Testing

@testable import FluxKlang

struct AssistantActionIntentValidatorTests {
    @Test func recoveredTargetCannotOmitAdjacentAlphabeticNameWords() {
        for (text, target, accepted) in [
            ("mute Juno Alpha", "Juno", false), ("mute Alpha Juno", "Juno", false),
            ("mute Juno Alpha", "Alpha", false), ("mute Juno Alpha", "Juno Alpha", true),
            ("mute Juno", "Juno", true), ("Could you mute my Juno Alpha please?", "Juno Alpha", true)
        ] {
            let output = AssistantActionModelOutput(disposition: .proposal, target: target, action: .mute,
                targetEvidence: target, actionEvidence: "mute")
            let interpreted = AssistantActionInterpretationAdapter.validate(output, request: .init(text: text))
            if accepted {
                guard case .proposal = interpreted else { Issue.record("Complete target was rejected"); continue }
            } else {
                #expect(interpreted == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
            }
            let intent = AssistantActionIntent(targetMention: target, action: .mute, amount: nil, addToStudio: false,
                evidence: .init(target: target, action: "mute", amount: nil, add: nil))
            #expect((AssistantActionIntentValidator.clarification(for: intent, text: text) == nil) == accepted)
        }
    }

    private func intent(
        action: AssistantActionIntent.Action = .setFaderPercent, amount: Double? = 50,
        amountEvidence: String? = "50%", target: String = "mother-32", add: Bool = true
    )
        -> AssistantActionIntent {
        .init(
            targetMention: target, action: action, amount: amount, addToStudio: add,
            evidence: .init(
                target: target, action: action == .lower ? "turn down" : "turn",
                amount: amountEvidence, add: add ? "add" : nil))
    }

    @Test func currentRequestEvidenceValidatesBothOwnerExamples() {
        #expect(
            AssistantActionIntentValidator.clarification(
                for: intent(),
                text: "add my mother-32 and turn the volume to 50%") == nil)
        #expect(
            AssistantActionIntentValidator.clarification(
                for: intent(
                    action: .lower, amount: nil,
                    amountEvidence: nil, target: "Astrolab", add: false), text: "turn down the volume of my Astrolab")
                == nil)
    }

    @Test func compoundCannotDropExplicitAddAndTargetLabelWordsAreNotActionEvidence() {
        for text in ["add my mother-32 and turn the volume to 50%",
                     "Could you add my mother-32 and turn the volume to 50%?"] {
            #expect(AssistantActionIntentValidator.clarification(for: intent(add: false), text: text) != nil)
            #expect(AssistantActionIntentValidator.clarification(for: intent(), text: text) == nil)
        }
        #expect(AssistantActionIntentValidator.clarification(for: intent(target: "Add Synth", add: false),
            text: "turn Add Synth to 50%") == nil)
        #expect(AssistantActionIntentValidator.clarification(for: intent(target: "Add Synth"),
            text: "turn Add Synth to 50%") != nil)
        #expect(AssistantActionIntentValidator.clarification(for: intent(target: "Turn Synth", add: false),
            text: "turn Turn Synth to 50%") == nil)
        #expect(AssistantActionIntentValidator.clarification(for: intent(target: "Turn Synth", add: false),
            text: "Turn Synth to 50%") != nil)
    }

    @Test func compactDBEvidencePreservesExplicitMainCommandCompatibility() {
        let intent = AssistantActionIntent(targetMention: "main 1", action: .setDB, amount: -12,
            addToStudio: false, evidence: .init(target: "main 1", action: "set", amount: "-12dB", add: nil))
        #expect(AssistantActionIntentValidator.clarification(for: intent, text: "set main 1 to -12dB") == nil)
        let mixedUnits = AssistantActionIntent(targetMention: "main 1", action: .setDB, amount: -12,
            addToStudio: false, evidence: .init(target: "main 1", action: "set", amount: "-12%dB", add: nil))
        #expect(AssistantActionIntentValidator.clarification(for: mixedUnits, text: "set main 1 to -12%dB") != nil)
    }

    @Test func rejectsInventedTargetAmountWrongUnitAndInconsistentAbsoluteMissingAmount() {
        let text = "add my mother-32 and turn the volume to 50%"
        for malformed in [
            intent(target: "Other"), intent(amount: 60), intent(amount: .nan),
            intent(amount: .infinity), intent(amount: 101, amountEvidence: "101%"),
            intent(action: .setDB), intent(amount: nil, amountEvidence: nil),
            intent(amountEvidence: "50"), intent(amountEvidence: "50% 3 dB")
        ] {
            #expect(AssistantActionIntentValidator.clarification(for: malformed, text: text) != nil,
                    "Rejected malformed intent: \(String(reflecting: malformed))")
        }
    }

    @Test func quotedNegatedHypotheticalQuestionAndMultipleActionsCannotBecomePlans() {
        for text in [
            "\"add my mother-32 and turn the volume to 50%\"",
            "do not add my mother-32 and turn the volume to 50%",
            "if I add my mother-32 and turn the volume to 50%",
            "how do I add my mother-32 and turn the volume to 50%",
            "add my mother-32 and turn the volume to 50% then mute channel 9"
        ] {
            #expect(AssistantActionIntentValidator.clarification(for: intent(), text: text) != nil)
        }
    }
}
