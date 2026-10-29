import Foundation
import Observation
import Testing

@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantActionPlanningTests {
    private func fixture(label: String = "Astrolab", lifetime: TimeInterval = 60)
        // swiftlint:disable:next large_tuple
        async -> (AssistantActionTestState, AssistantRecordingWingTransport, AssistantActionController) {
        let transport = AssistantRecordingWingTransport()
        await transport.put("/ch/7/name", .string(label))
        let wing = WingController(transport: transport)
        await wing.connect(host: "192.0.2.10")
        let state = AssistantActionTestState(wing: wing)
        let service = AssistantActionController(
            controller: { state.wing }, layout: { state.layout },
            scope: { state.scope },
            addShortcut: { binding, title, _, graph in
                guard !state.failLocal, graph == state.scope.graph else { return nil }
                if let existing = graph.nodes.first(where: { node in
                    guard case .liveChannel(let old) = node.kind else { return false }
                    return old.observedSessionID == binding.observedSessionID && old.members == binding.members
                }) {
                    return (existing.id, false)
                }
                let node = StudioNode(kind: .liveChannel(binding), title: title)
                state.scope.graph.addNode(node)
                return (node.id, true)
            }, timeout: .seconds(1), reviewLifetime: lifetime)
        return (state, transport, service)
    }

    private func request(_ text: String, state: AssistantActionTestState) -> AssistantActionInterpretationRequest {
        .init(
            text: text,
            liveContext: .init(
                status: .observed, sessionID: state.wing.sessionID,
                capturedAt: Date(), observations: []))
    }

    private func lower(_ target: String = "Astrolab") -> AssistantActionInterpretation {
        .proposal(
            .init(
                targetMention: target, action: .lower, amount: nil, addToStudio: false,
                evidence: .init(target: target, action: "turn down", amount: nil, add: nil)))
    }

    private func compound() -> AssistantActionInterpretation {
        .proposal(
            .init(
                targetMention: "mother-32", action: .setFaderPercent, amount: 50, addToStudio: true,
                evidence: .init(target: "mother-32", action: "turn", amount: "50%", add: "add")))
    }

    private func review(_ result: AssistantActionPreparation) throws -> AssistantActionReview {
        guard case .review(let review) = result else { throw BackendTestError.send }
        return review
    }

    @Test func answerClarificationAndMalformedIntentNeverQueryOrCreateEmptyReviews() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        let service = AssistantActionController(controller: { state.wing }, layout: { state.layout },
            scope: { state.scope }, addShortcut: { _, _, _, _ in nil })
        let question = request("how do I mute main?", state: state)
        if case .answer = await service.prepare(question, interpretation: .answer) {} else {
            Issue.record("Read-only answer was not forwarded")
        }
        _ = await service.prepare(question, interpretation: .clarification("Which channel?"))
        _ = await service.prepare(question, interpretation: lower())
        #expect(service.pendingReview == nil)
        #expect(service.latestResult == nil)
        #expect(await transport.queries.isEmpty)
        #expect(await transport.writes.isEmpty)
        await state.wing.disconnect()
    }

    @Test func explicitMainAndIndividualStereoMemberUseFreshReviewedNumericIdentity() async throws {
        for (target, node) in [("main 1", WingNodeRef.main(1)), ("main2", .main(2)), ("main 2", .main(2)),
                               ("channel7", .channel(7)), ("channel 7", .channel(7))] {
            let (state, transport, service) = await fixture()
            state.layout = FaderLayout(strips: [.init(node: .channel(7), rightNode: .channel(8),
                                                     customLabel: "Astrolab")])
            // A colliding live label must not steal an explicit numeric target.
            await transport.put(WingAddress.name(.channel, 8), .string(target))
            if node.kind == .main {
                await transport.put(WingAddress.name(.main, node.index), .string("Main"))
                await transport.put(WingAddress.fader(.main, node.index), .float(0.75))
                await transport.put(WingAddress.mute(.main, node.index), .int(0))
            }
            let submission = request("set \(target) to -12dB", state: state)
            let preview = try review(await service.prepare(submission,
                interpretation: AssistantActionInterpretationAdapter.fallback(submission, reason: "Test")))
            #expect(preview.stage == .ready)
            #expect(preview.target?.members.map { $0.identity.node } == [node])
            #expect(preview.target?.pairStripID == nil)
            #expect(await transport.writes.isEmpty)
            let result = await service.confirm(reviewID: preview.id)
            #expect(result.members.map(\.status) == [.confirmed])
            #expect(await transport.writes == [.init(address: WingAddress.fader(node.kind, node.index),
                                                      value: .float(-12))])
            await state.wing.disconnect()
        }
    }

    @Test func mainCannotBeAddedAsChannelShortcutAndUnqualifiedVolumeHasNoDefaultTarget() async {
        for (target, text, add) in [("main 1", "add main 1 and set it to -12dB", true),
                                    ("volume", "set volume to -12dB", false)] {
            let (state, transport, service) = await fixture()
            let intent = AssistantActionIntent(targetMention: target, action: .setDB, amount: -12,
                addToStudio: add, evidence: .init(target: target, action: "set", amount: "-12dB",
                                                  add: add ? "add" : nil))
            let outcome = await service.prepare(request(text, state: state), interpretation: .proposal(intent))
            if case .clarification = outcome {} else { Issue.record("Expected unsupported-target clarification") }
            #expect(service.pendingReview == nil)
            #expect(await transport.writes.isEmpty)
            #expect(state.scope.graph.nodes.isEmpty)
            await state.wing.disconnect()
        }
    }

    @Test func omittedAmountIsVisiblySuggestedAndOneConfirmationConsumesOnce() async throws {
        let (state, transport, service) = await fixture()
        let preview = try review(
            await service.prepare(
                request("turn down the volume of my Astrolab", state: state),
                interpretation: lower()))
        #expect(preview.stage == .ready)
        #expect(preview.suggestedAmountDB == 3)
        #expect(preview.summary.contains("Suggested change: lower by 3 dB (amount not specified)"))
        #expect(preview.faderChanges.first?.afterPosition == FaderMath.position(fromDecibels: -3))
        #expect(await transport.writes.isEmpty)
        let outcome = await service.confirm(reviewID: preview.id)
        #expect(outcome.members.map(\.status) == [.confirmed])
        #expect(await transport.writes.count == 1)
        _ = await service.confirm(reviewID: preview.id)
        #expect(await transport.writes.count == 1)
        #expect(service.pendingReview == nil)
        #expect(service.latestResult == outcome)
        await state.wing.disconnect()
    }

    @Test func compoundUnlinkedShortcutAnd50PercentAreLocalFirstAndDoNotInventGear() async throws {
        let (state, transport, service) = await fixture(label: "Mother-32")
        let originalHome = state.scope.connections
        let preview = try review(
            await service.prepare(
                request("add my mother-32 and turn the volume to 50%", state: state),
                interpretation: compound()))
        #expect(preview.faderChanges.first?.afterPosition == 0.5)
        #expect(FaderMath.decibels(fromPosition: 0.5) == -10)
        #expect(preview.addsLiveShortcut)
        #expect(preview.target?.members.first?.identity.equipmentID == nil)
        #expect(state.scope.graph.nodes.isEmpty)
        #expect(await transport.writes.isEmpty)
        let result = await service.confirm(reviewID: preview.id)
        #expect(result.localStatus == .added)
        #expect(result.members.map(\.status) == [.confirmed])
        #expect(state.scope.graph.nodes.count == 1)
        #expect(state.scope.graph.edges.isEmpty)
        #expect(state.scope.endpoints.isEmpty)
        #expect(state.scope.equipment.isEmpty)
        #expect(state.scope.connections == originalHome)
        #expect(await transport.writes == [.init(address: "/ch/7/fdr", value: .float(-10))])
        let repeated = try review(
            await service.prepare(
                request("add my mother-32 and turn the volume to 50%", state: state),
                interpretation: compound()))
        #expect(await service.confirm(reviewID: repeated.id).localStatus == .alreadyPresent)
        #expect(state.scope.graph.nodes.count == 1)
        await state.wing.disconnect()
    }

    @Test func punctuationSimilarityAndDuplicateLabelsRequireIDBoundSelectionWithZeroSETs() async throws {
        for duplicate in [false, true] {
            let (state, transport, service) = await fixture(label: duplicate ? "Astrolab" : "Astro-lab")
            if duplicate {
                await transport.put("/ch/8/name", .string("Astrolab"))
                await transport.put("/ch/8/fdr", .float(0.75))
                await transport.put("/ch/8/mute", .int(0))
            }
            let choice = try review(
                await service.prepare(request("turn down my Astrolab", state: state), interpretation: lower()))
            #expect(choice.stage == .chooseCandidate)
            #expect(choice.target == nil)
            _ = await service.confirm(reviewID: choice.id)
            #expect(await transport.writes.isEmpty)
            #expect(service.pendingReview?.id == choice.id)
            let preview = try review(await service.selectCandidate(reviewID: choice.id,
                                                                   candidateID: WingNodeRef.channel(7).id))
            #expect(preview.stage == .ready)
            #expect(preview.id != choice.id)
            #expect(preview.target?.members.first?.identity.node == .channel(7))
            #expect(await transport.writes.isEmpty)
            service.cancel()
            _ = await service.confirm(reviewID: preview.id)
            #expect(await transport.writes.isEmpty)
            await state.wing.disconnect()
        }
    }

    @Test func localInputAliasMapsThroughSourceNotNumericallyAndRequiresSelection() async throws {
        let (state, transport, service) = await fixture(label: "Lead")
        await transport.put(WingAddress.inputName(1), .string("Astrolab"))
        await transport.put(WingAddress.channelSourceIndex(7), .int(1))
        await transport.put(WingAddress.channelSourceGroup(1), .string("OFF"))
        let choice = try review(
            await service.prepare(request("turn down my Astrolab", state: state), interpretation: lower()))
        #expect(choice.stage == .chooseCandidate)
        #expect(choice.candidates.map(\.id) == [WingNodeRef.channel(7).id])
        #expect(await transport.writes.isEmpty)
        await state.wing.disconnect()
    }

    @Test func changedReviewEvidenceLocalFailureAndExpiredReviewAreZeroSET() async throws {
        for scenario in 0...8 {
            let (state, transport, service) = await fixture(label: "Mother-32", lifetime: scenario == 8 ? 0 : 60)
            let preview = try review(
                await service.prepare(
                    request("add my mother-32 and turn the volume to 50%", state: state),
                    interpretation: compound()))
            switch scenario {
            case 0: await transport.put("/ch/7/fdr", .float(0.6))
            case 1: await transport.put("/ch/7/name", .string("Other"))
            case 2: await transport.put(WingAddress.channelSourceIndex(7), .int(8))
            case 3: state.scope.environmentID = UUID()
            case 4: state.scope.graph.addNode(.init(kind: .instrument(UUID()), title: "Changed"))
            case 5: state.layout = FaderLayout(strips: [.init(node: .channel(8))])
            case 6: state.failLocal = true
            case 7: await state.wing.disconnect()
            default: break
            }
            let outcome = await service.confirm(reviewID: preview.id)
            #expect(outcome.members.allSatisfy { $0.status == .notSent })
            #expect(await transport.writes.isEmpty)
            #expect(state.scope.graph.nodes.allSatisfy { $0.kind.isRoutable })
            await state.wing.disconnect()
        }
    }

    @Test func queuedFinalSendRevokesOnCancellationSourceBaselineAndGraphABA() async throws {
        for scenario in 0...4 {
            let (state, transport, service) = await fixture()
            let preview = try review(
                await service.prepare(request("turn down my Astrolab", state: state), interpretation: lower()))
            await transport.pauseMixerSend()
            let confirmation = Task { await service.confirm(reviewID: preview.id) }
            try await AssistantBackendFixture.waitAsync { await transport.mixerSendWaiting }
            switch scenario {
            case 0: service.cancel()
            case 1: confirmation.cancel()
            case 2:
                await transport.emit(WingAddress.channelSourceIndex(7), .int(8))
                try await AssistantBackendFixture.wait {
                    state.wing.confirmedValues[WingAddress.channelSourceIndex(7)] == .int(8)
                }
            case 3:
                await transport.emit("/ch/7/fdr", .float(0.6))
                try await AssistantBackendFixture.wait { state.wing.confirmedValues["/ch/7/fdr"] == .float(0.6) }
            default:
                let original = state.scope.graph
                state.scope.graph.addNode(.init(kind: .instrument(UUID()), title: "Temporary"))
                state.scope.graph = original
            }
            await transport.releaseMixerSend()
            let result = await confirmation.value
            #expect(await transport.writes.isEmpty)
            #expect(result.members.map(\.status) == [.notSent])
            await state.wing.disconnect()
        }
    }

    @Test func sendFailureAfterLocalAddLeavesExplicitPartialWithoutRetry() async throws {
        let (state, transport, service) = await fixture(label: "Mother-32")
        let preview = try review(
            await service.prepare(
                request("add my mother-32 and turn the volume to 50%", state: state),
                interpretation: compound()))
        await transport.configure(afterWrite: false, fail: true)
        let result = await service.confirm(reviewID: preview.id)
        #expect(result.localStatus == .added)
        #expect(result.members.map(\.status) == [.sentUnconfirmed])
        #expect(result.message.contains("Partial or uncertain"))
        #expect(state.scope.graph.nodes.count == 1)
        #expect(await transport.writes.count == 1)
        _ = await service.confirm(reviewID: preview.id)
        #expect(await transport.writes.count == 1)
        await state.wing.disconnect()
    }
}

@MainActor
@Observable
final class AssistantActionTestState {
    var wing: WingController
    var layout = FaderLayout()
    var failLocal = false
    var scope = AssistantActionScope(
        environmentID: UUID(), graph: StudioGraph(), endpoints: [],
        equipment: [], connections: StudioHomeConnections())
    init(wing: WingController) { self.wing = wing }
}

extension AssistantActionPlanningTests {
    @Test func omittedCompoundAddCannotBecomeFaderOnlyReview() async {
        let (state, transport, service) = await fixture(label: "Mother-32")
        let intent = AssistantActionIntent(targetMention: "mother-32", action: .setFaderPercent, amount: 50,
            addToStudio: false, evidence: .init(target: "mother-32", action: "turn", amount: "50%", add: nil))
        let outcome = await service.prepare(
            request("Could you add my mother-32 and turn the volume to 50%?", state: state),
            interpretation: .proposal(intent))
        if case .clarification = outcome {} else { Issue.record("Compound request silently dropped its shortcut") }
        #expect(service.pendingReview == nil)
        #expect(state.scope.graph.nodes.isEmpty)
        #expect(await transport.writes.isEmpty)
        await state.wing.disconnect()
    }

    @Test func invalidNumericIdentitiesNeverFallThroughToCollidingLiveLabels() async throws {
        for target in ["main5", "main 5", "channel0", "channel 0", "channel41", "channel 41",
                       "main -1", "main-1", "channel -1", "channel-1", "main+1", "channel 1.5",
                       "channel .5", "main-.5", "main1e2", "channel0x7", "main1.",
                       "main999999999999999999999999999999"] {
            let (state, transport, service) = await fixture(label: target)
            let submission = request("set \(target) to -12dB", state: state)
            let intent = AssistantActionIntent(targetMention: target, action: .setDB, amount: -12,
                addToStudio: false, evidence: .init(target: target, action: "set", amount: "-12dB", add: nil))
            // Exercise untrusted generated intent as well as the exact fallback's range check.
            for interpretation in [AssistantActionInterpretation.proposal(intent),
                                   AssistantActionInterpretationAdapter.fallback(submission, reason: "Test")] {
                let outcome = await service.prepare(submission, interpretation: interpretation)
                if case .clarification = outcome {} else { Issue.record("Numeric identity fell through to a label") }
                #expect(service.pendingReview == nil)
                #expect(await transport.writes.isEmpty)
            }
            await state.wing.disconnect()
        }
    }

    @Test func targetLabelWordsDoNotInventOrHideAnAddRequestThroughAdapterAndPlanner() async throws {
        for name in ["Add Synth", "Include Synth"] {
            let (state, transport, service) = await fixture(label: name)
            let submission = request("turn \(name) to 50%", state: state)
            let output = AssistantActionModelOutput(disposition: .proposal, target: name,
                action: .setFaderPercent, amount: 50, targetEvidence: name,
                actionEvidence: "turn", amountEvidence: "50%")
            let interpreted = AssistantActionInterpretationAdapter.validate(output, request: submission)
            let preview = try review(await service.prepare(submission, interpretation: interpreted))
            #expect(preview.stage == .ready)
            #expect(!preview.addsLiveShortcut)
            #expect(preview.target?.members.map { $0.identity.node } == [.channel(7)])
            #expect(await transport.writes.isEmpty)

            let compound = request("add \(name) and turn its volume to 50%", state: state)
            let omitted = AssistantActionInterpretationAdapter.validate(output, request: compound)
            if case .clarification = omitted {} else { Issue.record("Actual add clause was silently omitted") }
            #expect(await transport.writes.isEmpty)
            await state.wing.disconnect()
        }
    }

    @Test func exactPlusSimilarSavedLinkOrPairRequiresSelectionBeforeConfirmation() async throws {
        for scenario in 0...2 {
            let (state, transport, service) = await fixture()
            await transport.put(WingAddress.name(.channel, 8), .string(scenario == 0 ? "Astro-lab" : "Lead"))
            if scenario == 1 {
                let gear = Equipment(name: "Astrolab")
                state.scope.equipment = [gear]
                state.scope.connections.inputs = [.init(connector: 8, equipmentID: gear.id, outputPort: 0)]
            } else if scenario == 2 {
                await transport.put(WingAddress.name(.channel, 9), .string("Keys R"))
                state.layout = .init(strips: [.init(node: .channel(8), rightNode: .channel(9),
                                                   customLabel: "Astrolab")])
            }
            let choice = try review(await service.prepare(request("turn down my Astrolab", state: state),
                                                           interpretation: lower()))
            #expect(choice.stage == .chooseCandidate)
            #expect(choice.candidates.count == 2)
            #expect(choice.selectedCandidateID == nil)
            #expect(choice.target == nil)
            #expect(choice.faderChanges.isEmpty)
            _ = await service.confirm(reviewID: choice.id)
            #expect(await transport.writes.isEmpty)
            let preview = try review(await service.selectCandidate(reviewID: choice.id,
                                                                   candidateID: WingNodeRef.channel(7).id))
            #expect(preview.stage == .ready)
            #expect(preview.target?.members.map { $0.identity.node } == [.channel(7)])
            #expect(await transport.writes.isEmpty)
            #expect(await service.confirm(reviewID: preview.id).members.map(\.status) == [.confirmed])
            #expect(await transport.writes.map(\.address) == [WingAddress.fader(.channel, 7)])
            await state.wing.disconnect()
        }
    }

    @Test func blankOrWhitespaceChannelsHaveNoNamedLOCALAliasOrCustomPairButAllowNumericIdentity() async throws {
        for label in ["", " \t "] {
            for pair in [false, true] {
                let (state, transport, service) = await fixture(label: label)
                await transport.put(WingAddress.inputName(7), .string("Astrolab"))
                if pair {
                    await transport.put(WingAddress.name(.channel, 8), .string(label))
                    state.layout = .init(strips: [.init(node: .channel(7), rightNode: .channel(8),
                                                       customLabel: "Astrolab")])
                }
                let named = await service.prepare(request("turn down my Astrolab", state: state),
                                                  interpretation: lower())
                if case .clarification = named {} else { Issue.record("Blank scribbles authorized a named target") }
                #expect(service.pendingReview == nil)
                #expect(await transport.writes.isEmpty)
                let preview = try review(await service.prepare(request("turn down channel7", state: state),
                                                                 interpretation: lower("channel7")))
                #expect(preview.stage == .ready)
                #expect(preview.target?.members.map { $0.identity.node } == [.channel(7)])
                #expect(preview.target?.members.first?.identity.label == label)
                #expect(preview.target?.pairStripID == nil)
                #expect(await transport.writes.isEmpty)
                await state.wing.disconnect()
            }
        }
    }

    @Test func exactTurnFallbackPreservesDirectionThroughPlannerPreparation() async throws {
        for (text, afterDB) in [("turn main 1 down by 3 dB", Float(-3)), ("turn down main 1 by 3 dB", -3),
                                ("turn main 1 up by 3 dB", 3), ("turn up main 1 by 3 dB", 3)] {
            let (state, transport, service) = await fixture()
            let submission = request(text, state: state)
            let preview = try review(await service.prepare(submission,
                interpretation: AssistantActionInterpretationAdapter.fallback(submission, reason: "Test")))
            #expect(preview.stage == .ready)
            #expect(preview.target?.members.map { $0.identity.node } == [.main(1)])
            #expect(preview.faderChanges.first?.afterPosition == FaderMath.position(fromDecibels: afterDB))
            #expect(await transport.writes.isEmpty)
            await state.wing.disconnect()
        }
    }

    @Test func exactTurnFallbackExcludesDirectionWordsInsideRecoveredTarget() async throws {
        for (label, direction) in [("Down Synth", "up"), ("Up Synth", "down")] {
            let (state, transport, service) = await fixture(label: label)
            let submission = request("turn \(label) \(direction) by 3 dB", state: state)
            let interpretation = AssistantActionInterpretationAdapter.fallback(submission, reason: "disabled")
            guard case .proposal(let intent) = interpretation else { throw BackendTestError.send }
            #expect(intent.evidence.action == direction)
            #expect(intent.action == (direction == "up" ? .raise : .lower))
            let preview = try review(await service.prepare(submission, interpretation: interpretation))
            #expect(preview.stage == .ready)
            #expect(preview.target?.members.map { $0.identity.node } == [.channel(7)])
            #expect(preview.faderChanges.first?.afterPosition
                == FaderMath.position(fromDecibels: direction == "up" ? 3 : -3))
            #expect(await transport.writes.isEmpty)
            await state.wing.disconnect()
        }
    }

    @Test func unsupportedPreampRequestNeverCreatesFaderReviewOrSendsSET() async {
        let (state, transport, service) = await fixture()
        let submission = request("set channel 7 preamp gain to 10 dB", state: state)
        let intent = AssistantActionIntent(targetMention: "channel 7", action: .setDB, amount: 10,
            addToStudio: false, evidence: .init(target: "channel 7", action: "set", amount: "10 dB", add: nil))
        let outcome = await service.prepare(submission, interpretation: .proposal(intent))
        if case .clarification = outcome {} else { Issue.record("Preamp request became a fader review") }
        #expect(service.pendingReview == nil)
        #expect(await transport.queries.isEmpty)
        #expect(await transport.writes.isEmpty)
        #expect(state.scope.graph.nodes.isEmpty)
        await state.wing.disconnect()
    }
}
