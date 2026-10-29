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

    @Test func equivalentOrderedUnitsAreDeduplicatedBeforeAmbiguity() {
        let observation = AssistantLiveWingContext.Observation(kind: .channel, index: 7,
            label: AssistantUntrustedText("Astrolab"), receivedAt: Date(), sourceGroup: "LCL", sourceIndex: 7)
        let live = AssistantLiveWingContext(status: .observed, sessionID: UUID(), capturedAt: Date(),
                                            observations: [observation, observation])
        let candidates = AssistantActionTargetResolver.candidates(mention: "Astrolab", live: live,
            names: [7: "Astrolab"], layout: .init(), equipment: [])
        #expect(candidates.map(\.id) == [WingNodeRef.channel(7).id])
        #expect(candidates.first?.members.map(\.node) == [.channel(7)])
        #expect(candidates.first?.match == .exact)
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

    @Test func reviewedPairAllowsFirstEchoButStopsBeforeSecondSETOnCancellationOrRelevantABA() async throws {
        for scenario in 0...4 {
            let cancelSecond = scenario == 1
            let expectedWrites = scenario == 0 || scenario == 2 ? 2 : 1
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
            if scenario > 0 { await transport.pauseMixerSend(afterWrites: 1) }
            let task = Task { await service.confirm(reviewID: preview.id) }
            if scenario > 0 {
                try await AssistantBackendFixture.waitAsync { await transport.mixerSendWaiting }
                #expect(await transport.writes.count == 1)
                if cancelSecond {
                    service.cancel()
                } else if scenario == 2 {
                    let change = try #require(preview.faderChanges.first)
                    await transport.emit(WingAddress.fader(.channel, 7), .float(change.afterPosition))
                    try await AssistantBackendFixture.wait {
                        wing.confirmedValues[WingAddress.fader(.channel, 7)] == .float(change.afterPosition)
                    }
                } else {
                    let address = scenario == 3 ? WingAddress.channelSourceIndex(7) : WingAddress.fader(.channel, 8)
                    let original: WingValue = scenario == 3 ? .int(7) : .float(0.65)
                    let changed: WingValue = scenario == 3 ? .int(8) : .float(0.6)
                    let revision = wing.assistantActionEvidence.revision
                    await transport.emit(address, changed)
                    await transport.emit(address, original)
                    try await AssistantBackendFixture.wait { wing.assistantActionEvidence.revision >= revision + 2 }
                }
                await transport.releaseMixerSend()
            }
            let result = await task.value
            #expect(await transport.writes.count == expectedWrites)
            let expected: [AssistantActionResult.MemberStatus] = cancelSecond ? [.sentUnconfirmed, .notSent]
                : (expectedWrites == 2 ? [.confirmed, .confirmed] : [.confirmed, .notSent])
            #expect(result.members.map(\.status) == expected)
            _ = await service.confirm(reviewID: preview.id)
            #expect(await transport.writes.count == expectedWrites)
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
            withObservationTracking { evidence.observeChanges(at: [address]) } onChange: { authorization.invalidate() }
            evidence.record(address, value: original)
            #expect(evidence.revision == 0)
            evidence.record(address, value: changed)
            evidence.record(address, value: original)
            #expect(evidence.revision == 2)
            #expect(throws: WingTransportError.notAuthorized) { try authorization.consume {} }
            #expect(!authorization.wasConsumed)
        }
    }

    @Test func consumedFirstMemberCannotHideABABeforeTransportAcknowledgement() async throws {
        for scenario in 0...4 {
            let transport = AssistantRecordingWingTransport()
            for index in 7...8 {
                await transport.put("/ch/\(index)/name", .string("Astrolab \(index)"))
                await transport.put("/ch/\(index)/fdr", .float(0.75))
                await transport.put("/ch/\(index)/mute", .int(0))
            }
            let wing = WingController(transport: transport)
            await wing.connect(host: "192.0.2.10")
            let state = AssistantActionTestState(wing: wing)
            let strip = FaderStrip(node: .channel(7), rightNode: .channel(8), customLabel: "Astrolab")
            state.layout = .init(strips: [strip])
            let service = AssistantActionController(controller: { state.wing }, layout: { state.layout },
                scope: { state.scope }, addShortcut: { _, _, _, _ in nil }, timeout: .seconds(1))
            let request = AssistantActionInterpretationRequest(text: "set Astrolab to 50%",
                liveContext: .init(status: .observed, sessionID: wing.sessionID, capturedAt: Date(), observations: []))
            guard case .review(let choice) = await service.prepare(request, interpretation: .proposal(intent())),
                  case .review(let ready) = await service.selectCandidate(
                    reviewID: choice.id, candidateID: "pair-" + strip.id.uuidString)
            else { throw BackendTestError.send }
            await transport.pauseMixerAcknowledgement()
            let confirmation = Task { await service.confirm(reviewID: ready.id) }
            try await AssistantBackendFixture.waitAsync { await transport.mixerAcknowledgementWaiting }
            #expect(await transport.writes.count == 1)
            if scenario < 3 {
                let address = scenario == 0 ? "/ch/7/fdr"
                    : (scenario == 1 ? WingAddress.channelSourceIndex(7) : "/ch/8/fdr")
                let original: WingValue = scenario == 1 ? .int(7) : .float(0.75)
                let changed: WingValue = scenario == 1 ? .int(8) : .float(0.6)
                let revision = wing.assistantActionEvidence.revision
                // Scenario zero is an expected completed-member echo, not a revocation.
                await transport.emit(address, scenario == 0 ? .float(0.5) : changed)
                if scenario != 0 { await transport.emit(address, original) }
                try await AssistantBackendFixture.wait {
                    wing.assistantActionEvidence.revision >= revision + (scenario == 0 ? 1 : 2)
                }
            } else if scenario == 3 {
                let original = state.scope.environmentID
                state.scope.environmentID = UUID()
                state.scope.environmentID = original
            } else {
                let original = state.layout
                state.layout = .init()
                state.layout = original
            }
            await transport.releaseMixerAcknowledgement()
            let result = await confirmation.value
            #expect(await transport.writes.count == (scenario == 0 ? 2 : 1))
            #expect(result.members.map(\.status) == (scenario == 0 ? [.confirmed, .confirmed] : [.confirmed, .notSent]))
            await wing.disconnect()
        }
    }

    @Test func scopedEvidenceIgnoresCompletedBaselineButResetAlwaysRevokes() throws {
        let evidence = WingAssistantActionEvidence()
        let completed = WingAddress.fader(.channel, 7)
        let remaining = WingAddress.fader(.channel, 8)
        evidence.record(completed, value: .float(0.75))
        evidence.record(remaining, value: .float(0.65))
        let allowed = WingMixerWriteAuthorization(deadline: .now.advanced(by: .seconds(1)))
        withObservationTracking { evidence.observeChanges(at: [remaining]) } onChange: { allowed.invalidate() }
        evidence.record(completed, value: .float(0.55))
        try allowed.consume {}
        #expect(allowed.wasConsumed)
        let revoked = WingMixerWriteAuthorization(deadline: .now.advanced(by: .seconds(1)))
        withObservationTracking { evidence.observeChanges(at: [remaining]) } onChange: { revoked.invalidate() }
        evidence.reset()
        #expect(throws: WingTransportError.notAuthorized) { try revoked.consume {} }
        #expect(!revoked.wasConsumed)
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
