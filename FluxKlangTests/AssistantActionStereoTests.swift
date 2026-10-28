import Foundation
import Observation
import Testing

@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantActionStereoTests {
    private func intent(action: AssistantActionIntent.Action = .setFaderPercent, amount: Double? = 50)
        -> AssistantActionIntent {
        .init(
            targetMention: "Astrolab", action: action, amount: amount, addToStudio: false,
            evidence: .init(
                target: "Astrolab", action: action == .lower ? "lower" : "set",
                amount: action == .lower ? "3 dB" : "50%", add: nil))
    }

    private func evidence(_ left: Float, _ right: Float) -> AssistantActionTargetEvidence {
        .init(
            sessionID: UUID(),
            members: [left, right].enumerated().map { index, position in
                .init(
                    identity: .init(
                        node: .channel(index + 7), label: "Astrolab \(index)",
                        sourceGroup: "LCL", sourceIndex: index + 7, equipmentID: nil),
                    position: position, muted: false)
            }, pairStripID: UUID())
    }

    @Test func absolutePairPreservesNormalizedBalanceAndRelativeAppliesPerSideDBWithoutClamping() throws {
        let planned = try #require(AssistantActionFaderPlanner.changes(intent: intent(), target: evidence(0.75, 0.65)))
        #expect(abs(planned[0].afterPosition - 0.55) < 0.0001)
        #expect(abs(planned[1].afterPosition - 0.45) < 0.0001)
        let relative = try #require(
            AssistantActionFaderPlanner.changes(
                intent: intent(action: .lower, amount: 3),
                target: evidence(0.75, 0.5)))
        #expect(abs(FaderMath.decibels(fromPosition: relative[0].afterPosition) - (-3)) < 0.001)
        #expect(abs(FaderMath.decibels(fromPosition: relative[1].afterPosition) - (-13)) < 0.001)
        #expect(
            AssistantActionFaderPlanner.changes(
                intent: intent(action: .setFaderPercent, amount: 10),
                target: evidence(0.95, 0.05)) == nil)
        #expect(
            AssistantActionFaderPlanner.changes(
                intent: intent(action: .lower, amount: 3),
                target: evidence(0, 0.75)) == nil)
        #expect(
            AssistantActionFaderPlanner.changes(
                intent: intent(action: .setFaderPercent, amount: .nan),
                target: evidence(0.75, 0.75)) == nil)
    }

    @Test func overlappingOrSelfPairsCannotAuthorizeUnits() {
        let first = FaderStrip(node: .channel(7), rightNode: .channel(8), customLabel: "Astrolab")
        #expect(AssistantActionTargetResolver.validPairs(in: .init(strips: [first])).count == 1)
        #expect(AssistantActionTargetResolver.validPairs(in: .init(strips: [first, .init(node: .channel(8))])).isEmpty)
        #expect(AssistantActionTargetResolver.validPairs(in: .init(strips: [first, first])).isEmpty)
        #expect(
            AssistantActionTargetResolver.validPairs(
                in: .init(strips: [
                    .init(node: .channel(7), rightNode: .channel(7))
                ])
            ).isEmpty)
    }

    @Test func reviewedPairConfirmsBothOrStopsBeforeSecondSETWithExplicitPartial() async throws {
        for cancelSecond in [false, true] {
            let transport = AssistantRecordingWingTransport()
            for (index, label, position) in [(7, "Astrolab L", Float(0.75)), (8, "Astrolab R", Float(0.65))] {
                await transport.put("/ch/\(index)/name", .string(label))
                await transport.put("/ch/\(index)/fdr", .float(position))
                await transport.put("/ch/\(index)/mute", .int(0))
            }
            let wing = WingController(transport: transport)
            await wing.connect(host: "192.0.2.10")
            let state = AssistantActionTestState(wing: wing)
            let strip = FaderStrip(node: .channel(7), rightNode: .channel(8), customLabel: "Astrolab")
            state.layout = .init(strips: [strip])
            let service = AssistantActionController(
                controller: { state.wing }, layout: { state.layout },
                scope: { state.scope }, addShortcut: { _, _, _, _ in nil }, timeout: .seconds(1))
            let request = AssistantActionInterpretationRequest(
                text: "set Astrolab to 50%",
                liveContext: .init(status: .observed, sessionID: wing.sessionID, capturedAt: Date(), observations: []))
            guard case .review(let choice) = await service.prepare(request, interpretation: .proposal(intent())) else {
                throw BackendTestError.send
            }
            #expect(choice.stage == .chooseCandidate)
            #expect(await transport.writes.isEmpty)
            guard
                case .review(let preview) = await service.selectCandidate(
                    reviewID: choice.id,
                    candidateID: "pair-" + strip.id.uuidString)
            else {
                throw BackendTestError.send
            }
            #expect(preview.target?.members.count == 2)
            #expect(preview.warnings.contains { $0.contains("two independent SETs") })
            #expect(await transport.writes.isEmpty)
            if cancelSecond { await transport.pauseMixerSend(afterWrites: 1) }
            let task = Task { await service.confirm(reviewID: preview.id) }
            if cancelSecond {
                try await AssistantBackendFixture.waitAsync { await transport.mixerSendWaiting }
                #expect(await transport.writes.count == 1)
                service.cancel()
                await transport.releaseMixerSend()
            }
            let result = await task.value
            #expect(await transport.writes.count == (cancelSecond ? 1 : 2))
            #expect(
                result.members.map(\.status)
                    == (cancelSecond ? [.sentUnconfirmed, .notSent] : [.confirmed, .confirmed]))
            _ = await service.confirm(reviewID: preview.id)
            #expect(await transport.writes.count == (cancelSecond ? 1 : 2))
            await wing.disconnect()
        }
    }

    @Test func evidenceRevisionIgnoresIdenticalGETsAndRevokesOnSourceOrBaselineABA() throws {
        for address in [WingAddress.channelSourceIndex(7), WingAddress.fader(.channel, 7)] {
            let evidence = WingAssistantActionEvidence()
            let original: WingValue = address.hasSuffix("/fdr") ? .float(0.75) : .int(7)
            let changed: WingValue = address.hasSuffix("/fdr") ? .float(0.6) : .int(8)
            evidence.record(address, value: original)
            let authorization = WingMixerWriteAuthorization(deadline: .now.advanced(by: .seconds(1)))
            withObservationTracking { _ = evidence.revision } onChange: { authorization.invalidate() }
            evidence.record(address, value: original)
            #expect(evidence.revision == 0)
            evidence.record(address, value: changed)
            evidence.record(address, value: original)
            #expect(evidence.revision == 2)
            #expect(throws: WingTransportError.notAuthorized) { try authorization.consume {} }
            #expect(!authorization.wasConsumed)
        }
    }

    @Test func finalSendAllowlistRejectsWrongValueWrongNodeAndUnboundConsume() throws {
        for scenario in 0...2 {
            let authorization = WingMixerWriteAuthorization(
                deadline: .now.advanced(by: .seconds(1)),
                node: .channel(7), value: .float(0.5), muted: false)
            var writes = 0
            #expect(throws: WingTransportError.notAuthorized) {
                switch scenario {
                case 0: try authorization.consume(node: .channel(8), value: .float(0.5), muted: false) { writes += 1 }
                case 1: try authorization.consume(node: .channel(7), value: .float(0.6), muted: false) { writes += 1 }
                default: try authorization.consume { writes += 1 }
                }
            }
            #expect(writes == 0)
            #expect(!authorization.wasConsumed)
        }
    }
}
