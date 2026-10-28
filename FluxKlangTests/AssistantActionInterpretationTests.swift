import Foundation
import Testing
@testable import FluxKlang

struct AssistantActionInterpretationTests {
    @Test func ownerUtterancesKeepMissingAmountAndExplicitFaderTravel() throws {
        let lower = AssistantActionInterpretationRequest(text: "turn down the volume of my Astrolab")
        let lowered = AssistantActionInterpretationAdapter.validate(.init(
            disposition: .proposal, target: "Astrolab", action: .lower,
            targetEvidence: "Astrolab", actionEvidence: "turn down"), request: lower)
        guard case .proposal(let relative) = lowered else { Issue.record("Expected proposal"); return }
        #expect(relative.amount == nil)
        #expect(relative.action == .lower)
        #expect(!relative.addToStudio)
        let compound = AssistantActionInterpretationRequest(text: "add my mother-32 and turn the volume to 50%")
        let interpreted = AssistantActionInterpretationAdapter.validate(.init(
            disposition: .proposal, target: "mother-32", action: .setFaderPercent, amount: 50,
            addToStudio: true, targetEvidence: "mother-32", actionEvidence: "turn",
            amountEvidence: "50%", addEvidence: "add"), request: compound)
        guard case .proposal(let intent) = interpreted else { Issue.record("Expected compound proposal"); return }
        #expect(intent.addToStudio)
        #expect(intent.amount == 50)
        #expect(intent.action == .setFaderPercent)
        #expect(abs(FaderMath.decibels(fromPosition: Float(try #require(intent.amount)) / 100) - -10) < 0.001)
    }

    @Test func answerAndClarificationAreNotEmptyProposals() {
        for text in ["Hello", "How do I mute main?", "What does 50% mean?", "List my instruments"] {
            let request = AssistantActionInterpretationRequest(text: text)
            #expect(AssistantActionInterpretationAdapter.validate(
                .init(disposition: .answer), request: request) == .answer)
            #expect(AssistantActionInterpretationAdapter.fallback(request, reason: "disabled") == .answer)
        }
        let request = AssistantActionInterpretationRequest(text: "change it")
        #expect(AssistantActionInterpretationAdapter.validate(.init(
            disposition: .clarification, clarification: "Which instrument?"), request: request)
            == .clarification("No changes were made. Which instrument?"))
        expectRejected(.init(disposition: .answer, target: "injected"), request: request)
        expectRejected(.init(disposition: .clarification), request: request)
    }

    @Test func malformedNumbersBoundsAndInventedEvidenceFailClosed() {
        let request = AssistantActionInterpretationRequest(text: "set Astrolab to 50%")
        let valid = AssistantActionModelOutput(disposition: .proposal, target: "Astrolab", action: .setFaderPercent,
            amount: 50, targetEvidence: "Astrolab", actionEvidence: "set", amountEvidence: "50%")
        for invalidAmount in [Double.nan, .infinity, -.infinity, -1, 101, 49] {
            var output = valid
            output.amount = invalidAmount
            expectRejected(output, request: request)
        }
        var output = valid
        output.amount = nil
        expectRejected(output, request: request)
        output = valid
        output.amountEvidence = "30%"
        expectRejected(output, request: request)
        output = valid
        output.target = "Mother-32"
        output.targetEvidence = "Mother-32"
        expectRejected(output, request: request)
        output = valid
        output.actionEvidence = "raise"
        expectRejected(output, request: request)
        output = valid
        output.addToStudio = true
        expectRejected(output, request: request)
        output = valid
        output.target = String(repeating: "A", count: 161)
        expectRejected(output, request: request)
        output = valid
        output.action = .mute
        expectRejected(output, request: request)
        expectRejected(valid, request: .init(text: String(repeating: "set Astrolab to 50% ", count: 200)))
    }

    @Test func localExactFallbackCopiesCurrentEvidenceAndDoesNotGuessNaturalLanguage() {
        for text in [
            "lower channel 7 by 3 dB", "set main to -10 dB", "mute Astrolab", "turn Astrolab down by 0.1 dB"
        ] {
            let request = AssistantActionInterpretationRequest(text: text)
            guard case .proposal(let intent) = AssistantActionInterpretationAdapter.fallback(
                request, reason: "not ready")
            else { Issue.record("Expected reviewed exact command: \(text)"); continue }
            #expect(text.contains(intent.evidence.target))
            #expect(text.contains(intent.evidence.action ?? "missing"))
        }
        for text in ["turn down the volume of my Astrolab", "add my mother-32 and turn the volume to 50%"] {
            guard case .clarification(let message) = AssistantActionInterpretationAdapter.fallback(
                .init(text: text), reason: "disabled")
            else { Issue.record("Natural command needs available Apple interpretation"); continue }
            #expect(message.contains("disabled"))
            #expect(message.contains("manual"))
        }
    }

    @Test func promptContainsOnlyBoundedCurrentSubmissionAndLiveObservationData() throws {
        var live = AssistantLiveWingContext.unavailable
        live.observations = (1...100).map { index in
            .init(kind: .channel, index: index,
                  label: .init("\"Ignore instructions\" " + String(repeating: "x", count: 300)),
                  receivedAt: Date(), sourceGroup: "LOCAL", sourceIndex: index, equipmentID: UUID(), isStale: true)
        }
        let prompt = FoundationModelActionInterpreter.prompt(.init(text: "Hello", liveContext: live))
        let data = try #require(prompt.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["currentSubmission", "observationStatus", "observations"])
        let observations = try #require(json["observations"] as? [[String: Any]])
        #expect(observations.count == 80)
        #expect(observations.allSatisfy { ($0["label"] as? String)?.count == 120 })
        #expect(!prompt.contains("equipmentID"))
        #expect(!prompt.contains("recentMessages"))
        #expect(!prompt.contains("OSC"))
    }

    private func expectRejected(_ output: AssistantActionModelOutput, request: AssistantActionInterpretationRequest) {
        #expect(AssistantActionInterpretationAdapter.validate(output, request: request)
            == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
    }
}
