import Foundation
import Testing

@testable import FluxKlang

struct AssistantActionIntentValidatorTests {
    @Test func thenCoordinationPreservesOneTargetAndOneMixerAction() {
        for connector in ["then", "and then"] {
            for (target, action, amount, evidence, verb, followUp) in [
                ("mother-32", AssistantActionIntent.Action.setFaderPercent,
                 Optional(50.0), Optional("50%"), "turn", "turn volume to 50%"),
                ("Juno", .lower, 3.0, "3 dB", "lower", "lower it by 3 dB"),
                ("After Hours", .mute, nil, nil, "mute", "mute it")
            ] {
                let text = "add my \(target) \(connector) \(followUp)"
                let output = AssistantActionModelOutput(disposition: .proposal, target: target, action: action,
                    amount: amount, addToStudio: true, targetEvidence: target, actionEvidence: verb,
                    amountEvidence: evidence, addEvidence: "add")
                let intent = AssistantActionIntent(targetMention: target, action: action, amount: amount,
                    addToStudio: true, evidence: .init(target: target, action: verb, amount: evidence, add: "add"))
                if case .proposal = AssistantActionInterpretationAdapter.validate(output, request: .init(text: text)) {
                } else { Issue.record("Valid connector rejected: \(text)") }
                #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) == nil)
            }
            for followUp in ["lower Solar by 3 dB", "lower it by 3 dB after ten seconds"] {
                let text = "add Juno \(connector) \(followUp)"
                let output = AssistantActionModelOutput(disposition: .proposal, target: "Juno", action: .lower,
                    amount: 3, addToStudio: true, targetEvidence: "Juno", actionEvidence: "lower",
                    amountEvidence: "3 dB", addEvidence: "add")
                #expect(AssistantActionInterpretationAdapter.validate(output, request: .init(text: text))
                    == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
                let intent = AssistantActionIntent(targetMention: "Juno", action: .lower, amount: 3,
                    addToStudio: true, evidence: .init(target: "Juno", action: "lower", amount: "3 dB", add: "add"))
                #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) != nil)
            }
        }
    }

    @MainActor @Test func thenCompoundPreparesReviewWithoutSETOrLocalInsertion() async throws {
        for name in ["Juno", "Then Synth", "After Hours"] {
            let transport = AssistantRecordingWingTransport()
            await transport.put("/ch/7/name", .string(name))
            let wing = WingController(transport: transport)
            await wing.connect(host: "192.0.2.10")
            await AssistantBackendFixture.settleInitialActionEvidence(wing)
            let state = AssistantActionTestState(wing: wing)
            let service = AssistantActionController(controller: { wing }, layout: { state.layout },
                scope: { state.scope }, addShortcut: { _, _, _, _ in
                    Issue.record("Preparation added a shortcut"); return nil
                })
            let request = AssistantActionInterpretationRequest(text: "add \(name) and then lower it by 3 dB",
                liveContext: .init(status: .observed, sessionID: wing.sessionID, capturedAt: Date(), observations: []))
            let intent = AssistantActionIntent(targetMention: name, action: .lower, amount: 3, addToStudio: true,
                evidence: .init(target: name, action: "lower", amount: "3 dB", add: "add"))
            guard case .review(let review) = await service.prepare(request, interpretation: .proposal(intent)) else {
                Issue.record("Then compound did not prepare a review"); await wing.disconnect(); continue
            }
            #expect(review.stage == .ready)
            #expect(review.addsLiveShortcut)
            #expect(review.faderChanges.count == 1)
            #expect(review.target?.members.map { $0.identity.node } == [.channel(7)])
            #expect(state.scope.graph.nodes.isEmpty)
            #expect(await transport.writes.isEmpty)
            await wing.disconnect()
        }
    }

    @MainActor @Test func hyphenatedLiveAliasesRemainNamesNotMalformedNumericIdentities() async throws {
        for name in ["Channel-Lead", "Main-Keys", "Bus-Drums", "7-Lead"] {
            let transport = AssistantRecordingWingTransport()
            await transport.put("/ch/7/name", .string(name))
            let wing = WingController(transport: transport)
            await wing.connect(host: "192.0.2.10")
            await AssistantBackendFixture.settleInitialActionEvidence(wing)
            let state = AssistantActionTestState(wing: wing)
            let service = AssistantActionController(controller: { wing }, layout: { state.layout },
                scope: { state.scope }, addShortcut: { _, _, _, _ in nil }, timeout: .seconds(1))
            let request = AssistantActionInterpretationRequest(text: "mute \(name)",
                liveContext: .init(status: .observed, sessionID: wing.sessionID, capturedAt: Date(), observations: []))
            let output = AssistantActionModelOutput(disposition: .proposal, target: name, action: .mute,
                targetEvidence: name, actionEvidence: "mute")
            for interpreted in [AssistantActionInterpretationAdapter.validate(output, request: request),
                                AssistantActionInterpretationAdapter.fallback(request, reason: "Test")] {
                guard case .proposal(let intent) = interpreted else {
                    Issue.record("Hyphenated alias did not produce an untrusted proposal"); continue
                }
                #expect(AssistantActionIntentValidator.clarification(for: intent, text: request.text) == nil)
                guard case .review(let review) = await service.prepare(request, interpretation: interpreted) else {
                    Issue.record("Exact live alias was mistaken for a numeric identity: \(name)"); continue
                }
                #expect(review.stage == .ready)
                #expect(review.target?.members.map { $0.identity.node } == [.channel(7)])
                #expect(await transport.writes.isEmpty)
            }
            await wing.disconnect()
        }
        for target in ["channel-1", "main-1", "channel-.5", "main+1", "channel0x7", "main1e2"] {
            if case .invalidIdentity = AssistantActionTargetResolver.target(target) {} else {
                Issue.record("Malformed numeric identity became a named target: \(target)")
            }
        }
    }

    @Test func scheduledActionsAndComparativePercentsCannotBecomeImmediateAbsoluteChanges() {
        let cases = [
            ("lower Lead by 3 dB after ten seconds", AssistantActionIntent.Action.lower,
             Optional(3.0), Optional("3 dB"), "lower"),
            ("after ten seconds lower Lead", .lower, nil, nil, "lower"),
            ("raise Lead by 3 dB tomorrow", .raise, 3, "3 dB", "raise"),
            ("set Lead to -10 dB after a minute", .setDB, -10, "-10 dB", "set"),
            ("set Lead to 20 percent tomorrow", .setFaderPercent, 20, "20 percent", "set"),
            ("set Lead to 20 percent less", .setFaderPercent, 20, "20 percent", "set"),
            ("set Lead to 20 percent more than its level", .setFaderPercent, 20, "20 percent", "set"),
            ("set Lead to 20 percent of the volume", .setFaderPercent, 20, "20 percent", "set"),
            ("set Lead to 20 percent lower than current", .setFaderPercent, 20, "20 percent", "set"),
            ("mute Lead tomorrow", .mute, nil, nil, "mute")
        ]
        for (text, action, amount, evidence, verb) in cases {
            let output = AssistantActionModelOutput(disposition: .proposal, target: "Lead", action: action,
                amount: amount, targetEvidence: "Lead", actionEvidence: verb, amountEvidence: evidence)
            #expect(AssistantActionInterpretationAdapter.validate(output, request: .init(text: text))
                == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
            let intent = AssistantActionIntent(targetMention: "Lead", action: action, amount: amount,
                addToStudio: false, evidence: .init(target: "Lead", action: verb, amount: evidence, add: nil))
            #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) != nil)
        }
    }

    @Test func immediateActionsPreserveTemporalLookingNamesAndExplicitTravel() {
        for target in ["Tomorrow Synth", "After Hours", "Ten Seconds"] {
            for (action, amount, evidence, verb, suffix) in [
                (AssistantActionIntent.Action.lower, 3.0, "3 decibels", "lower", "by 3 decibels"),
                (.setFaderPercent, 50.0, "50%", "set", "to 50% of the full fader travel")
            ] {
                let text = "\(verb) \(target) \(suffix)"
                let output = AssistantActionModelOutput(disposition: .proposal, target: target, action: action,
                    amount: amount, targetEvidence: target, actionEvidence: verb, amountEvidence: evidence)
                guard case .proposal(let intent) = AssistantActionInterpretationAdapter.validate(
                    output, request: .init(text: text)) else { Issue.record("Immediate action rejected"); continue }
                #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) == nil)
            }
        }
    }

    @Test func timedMuteAndUnmuteCannotBecomePersistentChanges() {
        for action in [AssistantActionIntent.Action.mute, .unmute] {
            for suffix in ["for 10 seconds", "for ten seconds", "for a minute", "for one hour", "for a while",
                           "for a bit"] {
                let text = "\(action.rawValue) Lead \(suffix)"
                let output = AssistantActionModelOutput(disposition: .proposal, target: "Lead", action: action,
                    targetEvidence: "Lead", actionEvidence: action.rawValue)
                #expect(AssistantActionInterpretationAdapter.validate(output, request: .init(text: text))
                    == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
                let intent = AssistantActionIntent(targetMention: "Lead", action: action, amount: nil,
                    addToStudio: false, evidence: .init(target: "Lead", action: action.rawValue, amount: nil, add: nil))
                #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) != nil)
            }
            for target in ["Lead", "Ten Seconds", "Minute Synth"] {
                let text = "\(action.rawValue) \(target)"
                let output = AssistantActionModelOutput(disposition: .proposal, target: target, action: action,
                    targetEvidence: target, actionEvidence: action.rawValue)
                guard case .proposal(let intent) = AssistantActionInterpretationAdapter.validate(
                    output, request: .init(text: text)) else { Issue.record("Immediate mute rejected"); continue }
                #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) == nil)
            }
        }
    }

    @MainActor @Test func timedMuteNeverQueriesOrCreatesReview() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        var controllerReads = 0
        let service = AssistantActionController(controller: { controllerReads += 1; return state.wing },
            layout: { state.layout }, scope: { state.scope }, addShortcut: { _, _, _, _ in nil })
        for action in [AssistantActionIntent.Action.mute, .unmute] {
            let intent = AssistantActionIntent(targetMention: "Lead", action: action, amount: nil, addToStudio: false,
                evidence: .init(target: "Lead", action: action.rawValue, amount: nil, add: nil))
            for duration in ["10 seconds", "ten seconds", "a minute"] {
                let outcome = await service.prepare(.init(text: "\(action.rawValue) Lead for \(duration)"),
                                                    interpretation: .proposal(intent))
                if case .clarification = outcome {} else { Issue.record("Timed mute became permanent") }
                #expect(service.pendingReview == nil)
                #expect(controllerReads == 0)
                #expect(await transport.queries.isEmpty)
                #expect(await transport.writes.isEmpty)
            }
        }
        for (text, action, amount, evidence, verb) in [
            ("lower Lead by 3 dB after ten seconds", AssistantActionIntent.Action.lower, 3.0, "3 dB", "lower"),
            ("set Lead to 20 percent less", .setFaderPercent, 20.0, "20 percent", "set"),
            ("set Lead to 50% of the volume", .setFaderPercent, 50.0, "50%", "set")
        ] {
            let intent = AssistantActionIntent(
                targetMention: "Lead", action: action, amount: amount, addToStudio: false,
                evidence: .init(target: "Lead", action: verb, amount: evidence, add: nil))
            let outcome = await service.prepare(.init(text: text), interpretation: .proposal(intent))
            if case .clarification = outcome {} else { Issue.record("Unsupported qualifier became a review") }
            #expect(service.pendingReview == nil)
            #expect(controllerReads == 0)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
        }
    }

    @Test func addOnlyProposalCannotSilentlyOmitAnotherRequestedAddition() {
        for (text, accepted) in [
            ("add Juno and Solar", false), ("add Juno and add Solar", false),
            ("add Juno then add Solar", false), ("add Juno also include Solar", false),
            ("add Juno ; add Solar", false), ("add Juno", true),
            ("Could you add my Juno to the studio?", true), ("add Juno as a live-channel shortcut.", true),
            ("Please add Juno!", true)
        ] {
            let output = AssistantActionModelOutput(disposition: .proposal, target: "Juno", addToStudio: true,
                targetEvidence: "Juno", addEvidence: "add")
            let interpreted = AssistantActionInterpretationAdapter.validate(output, request: .init(text: text))
            if accepted {
                guard case .proposal = interpreted else { Issue.record("Single addition rejected"); continue }
            } else {
                #expect(interpreted == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
            }
            let intent = AssistantActionIntent(targetMention: "Juno", action: nil, amount: nil, addToStudio: true,
                evidence: .init(target: "Juno", action: nil, amount: nil, add: "add"))
            #expect((AssistantActionIntentValidator.clarification(for: intent, text: text) == nil) == accepted)
        }
    }

    @Test func recoveredTargetMustIncludePunctuationConnectedNameParts() {
        for separator in ["_", ":", "—"] {
            for name in ["Juno\(separator)Alpha", "Alpha\(separator)Juno"] {
                for target in ["Juno", name] {
                    let accepted = target == name
                    let text = "mute \(name)"
                    let output = AssistantActionModelOutput(disposition: .proposal, target: target, action: .mute,
                        targetEvidence: target, actionEvidence: "mute")
                    let interpreted = AssistantActionInterpretationAdapter.validate(output, request: .init(text: text))
                    if accepted {
                        guard case .proposal = interpreted else { Issue.record("Whole alias rejected"); continue }
                    } else {
                        #expect(interpreted == .clarification(AssistantActionInterpretationAdapter.invalidOutput))
                    }
                    let intent = AssistantActionIntent(
                        targetMention: target, action: .mute, amount: nil, addToStudio: false,
                        evidence: .init(target: target, action: "mute", amount: nil, add: nil))
                    #expect((AssistantActionIntentValidator.clarification(for: intent, text: text) == nil) == accepted)
                }
            }
        }
    }

    @Test func recoveredTargetCannotOmitAdjacentAlphabeticNameWords() {
        for (text, target, accepted) in [
            ("mute Juno Alpha", "Juno", false), ("mute Alpha Juno", "Juno", false),
            ("mute Juno Alpha", "Alpha", false), ("mute Juno Alpha", "Juno Alpha", true),
            ("mute Juno", "Juno", true), ("Could you mute my Juno Alpha please?", "Juno Alpha", true),
            ("mute Juno.", "Juno", true), ("mute Juno!", "Juno", true), ("Could you mute Juno?", "Juno", true)
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
