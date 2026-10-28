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
            let preview = try review(await service.selectCandidate(reviewID: choice.id, candidateID: "channel-7"))
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
        #expect(choice.candidates.map(\.id) == ["channel-7"])
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
