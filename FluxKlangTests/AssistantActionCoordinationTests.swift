import Foundation
import Testing
@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantActionCoordinationTests {
    private struct Fixture {
        let state: AssistantActionTestState
        let transport: AssistantRecordingWingTransport
        let service: AssistantActionController
    }

    private func fixture(label: String = "Astrolab") async -> Fixture {
        let transport = AssistantRecordingWingTransport()
        await transport.put("/ch/7/name", .string(label))
        let wing = WingController(transport: transport)
        await wing.connect(host: "192.0.2.10")
        let state = AssistantActionTestState(wing: wing)
        let service = AssistantActionController(controller: { state.wing }, layout: { state.layout },
            scope: { state.scope }, addShortcut: { _, _, _, _ in nil }, timeout: .seconds(1))
        return Fixture(state: state, transport: transport, service: service)
    }

    private func request(_ fixture: Fixture) -> AssistantActionInterpretationRequest {
        .init(text: "turn down my Astrolab", liveContext: .init(status: .observed,
            sessionID: fixture.state.wing.sessionID, capturedAt: Date(), observations: []))
    }

    private var interpretation: AssistantActionInterpretation {
        .proposal(.init(targetMention: "Astrolab", action: .lower, amount: nil, addToStudio: false,
            evidence: .init(target: "Astrolab", action: "turn down", amount: nil, add: nil)))
    }

    @Test func preservingReadRetainsSharedConfirmationButOldReplyCannotSatisfyTimestampGate() async throws {
        let fixture = await fixture()
        let wing = fixture.state.wing
        let session = try #require(wing.sessionID)
        let source = WingAddress.channelSourceGroup(7)
        let original = try #require(await wing.readFreshConfirmed([source], session: session,
            timeout: .seconds(1)))
        await fixture.transport.configure(answers: false)
        let result = await wing.readFreshConfirmed([source], session: session,
            timeout: .milliseconds(50))
        #expect(result == nil)
        #expect(wing.confirmedValues[source] == original[source])
        #expect(wing.confirmedReceivedAt[source] != nil)
        await wing.disconnect()
    }

    @Test func concurrentActionPreparationDoesNotEraseListenSourceProofOrCausePATCHRetry() async throws {
        let fixture = await fixture()
        let wing = fixture.state.wing
        let source = WingAddress.channelSourceGroup(7)
        let patch = WingSetting(address: source, value: .string("LCL"))
        let startedAt = Date()
        // This is the same paced verified transaction used by Studio Listen.
        let listen = Task { await wing.applyAndVerify([patch]) }
        try await AssistantBackendFixture.waitAsync {
            await fixture.transport.writes.contains(patch)
                && (wing.confirmedReceivedAt[source] ?? .distantPast) >= startedAt
                && wing.confirmedValues[source] == patch.value
        }
        let firstDiscovery = try #require(AssistantActionController.discoveryAddresses.sorted().first)
        await fixture.transport.pauseQueries(at: firstDiscovery)
        let preparation = Task { await fixture.service.prepare(request(fixture), interpretation: interpretation) }
        try await AssistantBackendFixture.waitAsync { await fixture.transport.queryWaiting }
        #expect(wing.confirmedValues[source] == patch.value)
        #expect(WingApplyVerifier.pendingSettings(expected: [patch], confirmedValues: wing.confirmedValues).isEmpty)
        let verification = await listen.value
        #expect(verification.state == .verified)
        #expect(await fixture.transport.writes.filter { $0.address == source } == [patch])
        await fixture.transport.releaseQueries()
        _ = await preparation.value
        #expect(await fixture.transport.writes == [patch])
        await wing.disconnect()
    }

    @Test func cancelledOrSupersededPreparationNeverRestoresOrOverwritesPendingReview() async throws {
        for replace in [false, true] {
            let fixture = await fixture()
            let firstDiscovery = try #require(AssistantActionController.discoveryAddresses.sorted().first)
            await fixture.transport.pauseQueries(at: firstDiscovery)
            let originalRequest = request(fixture)
            let original = Task { await fixture.service.prepare(originalRequest, interpretation: interpretation) }
            try await AssistantBackendFixture.waitAsync { await fixture.transport.queryWaiting }
            fixture.service.cancel()
            let replacementRequest = request(fixture)
            let replacement: Task<AssistantActionPreparation, Never>? = replace ? Task {
                await fixture.service.prepare(replacementRequest, interpretation: interpretation)
            } : nil
            await Task.yield()
            await fixture.transport.releaseQueries()
            let originalResult = await original.value
            if case .review = originalResult { Issue.record("Cancelled generation restored a review") }
            if let replacement {
                guard case .review(let newest) = await replacement.value else { throw BackendTestError.send }
                #expect(fixture.service.pendingReview?.id == newest.id)
                #expect(fixture.service.pendingReview?.submissionID == replacementRequest.submissionID)
            } else {
                #expect(fixture.service.pendingReview == nil)
            }
            #expect(await fixture.transport.writes.isEmpty)
            await fixture.state.wing.disconnect()
        }
    }

    @Test func cancelledCandidateRefreshNeverRestoresReview() async throws {
        let fixture = await fixture(label: "Astro-lab")
        guard case .review(let choice) = await fixture.service.prepare(request(fixture),
            interpretation: interpretation) else { throw BackendTestError.send }
        #expect(choice.stage == .chooseCandidate)
        let firstDiscovery = try #require(AssistantActionController.discoveryAddresses.sorted().first)
        await fixture.transport.pauseQueries(at: firstDiscovery)
        let selection = Task {
            await fixture.service.selectCandidate(reviewID: choice.id, candidateID: WingNodeRef.channel(7).id)
        }
        try await AssistantBackendFixture.waitAsync { await fixture.transport.queryWaiting }
        fixture.service.cancel()
        await fixture.transport.releaseQueries()
        let outcome = await selection.value
        if case .review = outcome { Issue.record("Cancelled selection restored a review") }
        #expect(fixture.service.pendingReview == nil)
        #expect(await fixture.transport.writes.isEmpty)
        await fixture.state.wing.disconnect()
    }

    @Test func reviewRevokesOnABABeforeOrDuringEitherConfirmationRefresh() async throws {
        for phase in 0...2 {
            for scenario in 0...3 {
                let fixture = await fixture()
                guard case .review(let preview) = await fixture.service.prepare(
                    request(fixture), interpretation: interpretation) else { throw BackendTestError.send }
                let pausedAddress = phase == 2 ? "/ch/7/fdr"
                    : try #require(AssistantActionController.discoveryAddresses.sorted().first)
                var confirmation: Task<AssistantActionResult, Never>?
                if phase > 0 {
                    await fixture.transport.pauseQueries(at: pausedAddress)
                    confirmation = Task { await fixture.service.confirm(reviewID: preview.id) }
                    try await AssistantBackendFixture.waitAsync { await fixture.transport.queryWaiting }
                }
                switch scenario {
                case 0, 1:
                    let address = scenario == 0 ? WingAddress.channelSourceIndex(7) : "/ch/7/fdr"
                    let original: WingValue = scenario == 0 ? .int(7) : .float(0.75)
                    let changed: WingValue = scenario == 0 ? .int(8) : .float(0.6)
                    let revision = fixture.state.wing.assistantActionEvidence.revision
                    await fixture.transport.emit(address, changed)
                    await fixture.transport.emit(address, original)
                    try await AssistantBackendFixture.wait {
                        fixture.state.wing.assistantActionEvidence.revision >= revision + 2
                    }
                case 2:
                    let original = fixture.state.scope.environmentID
                    fixture.state.scope.environmentID = UUID()
                    fixture.state.scope.environmentID = original
                default:
                    let original = fixture.state.layout
                    fixture.state.layout = .init(strips: [.init(node: .channel(8))])
                    fixture.state.layout = original
                }
                await fixture.transport.releaseQueries()
                let result: AssistantActionResult
                if let confirmation {
                    result = await confirmation.value
                } else {
                    result = await fixture.service.confirm(reviewID: preview.id)
                }
                #expect(result.members.map(\.status) == [.notSent])
                #expect(await fixture.transport.writes.isEmpty)
                #expect(fixture.state.scope.graph.nodes.isEmpty)
                await fixture.state.wing.disconnect()
            }
        }
    }

    @Test func candidateRefreshKeepsDisplayLinkButReplacesConfirmationAuthority() async throws {
        let fixture = await fixture(label: "Astro-lab")
        let submission = request(fixture)
        guard case .review(let choice) = await fixture.service.prepare(
            submission, interpretation: interpretation),
            case .review(let ready) = await fixture.service.selectCandidate(
                reviewID: choice.id, candidateID: WingNodeRef.channel(7).id)
        else { throw BackendTestError.send }
        #expect(choice.id != ready.id)
        #expect(choice.submissionID == ready.submissionID)
        let obsolete = await fixture.service.confirm(reviewID: choice.id)
        #expect(obsolete.members.isEmpty)
        let displayOnly = await fixture.service.confirm(reviewID: choice.submissionID)
        #expect(displayOnly.members.isEmpty)
        #expect(fixture.service.pendingReview?.id == ready.id)
        await fixture.transport.configure(afterWrite: false, fail: true)
        let result = await fixture.service.confirm(reviewID: ready.id)
        #expect(result.reviewID == ready.id)
        #expect(result.submissionID == choice.submissionID)
        #expect(result.members.map(\.status) == [.sentUnconfirmed])
        #expect(result.message.contains("Partial or uncertain"))
        #expect(fixture.service.pendingReview == nil)
        #expect(fixture.service.latestResult == result)
        _ = await fixture.service.confirm(reviewID: ready.id)
        #expect(await fixture.transport.writes.count == 1)
        await fixture.state.wing.disconnect()
    }

    @Test func expandedModelTargetCannotHideControlWordsBehindAnyShorterGroundedAlias() async throws {
        for scenario in 0...3 {
            let fixture = await fixture(label: scenario == 0 ? "Astrolab" : "Lead")
            if scenario == 1 {
                let gear = Equipment(name: "Astrolab")
                fixture.state.scope.equipment = [gear]
                fixture.state.scope.connections.inputs = [.init(connector: 7, equipmentID: gear.id, outputPort: 0)]
            } else if scenario == 2 {
                await fixture.transport.put(WingAddress.inputName(7), .string("Astrolab"))
            } else if scenario == 3 {
                await fixture.transport.put("/ch/8/name", .string("Right"))
                fixture.state.layout = .init(strips: [
                    .init(node: .channel(7), rightNode: .channel(8), customLabel: "Astrolab")
                ])
            }
            let target = "Astrolab preamp gain"
            let submission = AssistantActionInterpretationRequest(
                text: "set \(target) to 10 dB", liveContext: request(fixture).liveContext)
            // Text validation cannot know whether these words are an actual equipment name.
            let interpretation = AssistantActionInterpretationAdapter.validate(.init(
                disposition: .proposal, target: target, action: .setDB, amount: 10,
                targetEvidence: target, actionEvidence: "set", amountEvidence: "10 dB"), request: submission)
            guard case .proposal = interpretation else { throw BackendTestError.send }
            let prepared = await fixture.service.prepare(submission, interpretation: interpretation)
            if case .clarification = prepared {} else { Issue.record("Expanded model span became a target candidate") }
            #expect(fixture.service.pendingReview == nil)
            let selection = await fixture.service.selectCandidate(
                reviewID: UUID(), candidateID: WingNodeRef.channel(7).id)
            if case .clarification = selection {} else { Issue.record("Ungrounded target survived selection") }
            #expect(fixture.service.pendingReview == nil)
            #expect(await fixture.transport.writes.isEmpty)
            #expect(fixture.state.scope.graph.nodes.isEmpty)
            await fixture.state.wing.disconnect()
        }
    }

    @Test func groundedControlWordNamesAndTruePartialMentionsStillPrepareReviews() async throws {
        for scenario in 0...2 {
            let name = "Astrolab preamp gain"
            let fixture = await fixture(label: scenario == 2 ? "Lead" : name)
            if scenario == 2 {
                let gear = Equipment(name: name)
                fixture.state.scope.equipment = [gear]
                fixture.state.scope.connections.inputs = [.init(connector: 7, equipmentID: gear.id, outputPort: 0)]
            }
            let mention = scenario == 1 ? "Astrolab" : name
            let submission = AssistantActionInterpretationRequest(
                text: "set \(mention) to 10 dB", liveContext: request(fixture).liveContext)
            let interpretation = AssistantActionInterpretationAdapter.validate(.init(
                disposition: .proposal, target: mention, action: .setDB, amount: 10,
                targetEvidence: mention, actionEvidence: "set", amountEvidence: "10 dB"), request: submission)
            guard case .review(let initial) = await fixture.service.prepare(
                submission, interpretation: interpretation) else { throw BackendTestError.send }
            let ready: AssistantActionReview
            if scenario == 0 {
                #expect(initial.stage == .ready)
                ready = initial
            } else {
                #expect(initial.stage == .chooseCandidate)
                guard case .review(let selected) = await fixture.service.selectCandidate(
                    reviewID: initial.id, candidateID: WingNodeRef.channel(7).id) else { throw BackendTestError.send }
                ready = selected
            }
            #expect(ready.stage == .ready)
            #expect(ready.target?.members.map { $0.identity.node } == [.channel(7)])
            #expect(ready.faderChanges.first?.afterPosition == FaderMath.position(fromDecibels: 10))
            #expect(await fixture.transport.writes.isEmpty)
            await fixture.state.wing.disconnect()
        }
    }

    @Test func omittedSecondAdditionCannotCreateReviewOrQueryConsole() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        var controllerReads = 0
        var localAdds = 0
        let service = AssistantActionController(controller: { controllerReads += 1; return state.wing },
            layout: { state.layout }, scope: { state.scope },
            addShortcut: { _, _, _, _ in localAdds += 1; return nil })
        let intent = AssistantActionIntent(targetMention: "Juno", action: nil, amount: nil, addToStudio: true,
            evidence: .init(target: "Juno", action: nil, amount: nil, add: "add"))
        for text in ["add Juno and add Solar", "add Juno then add Solar", "add Juno also include Solar"] {
            let outcome = await service.prepare(.init(text: text), interpretation: .proposal(intent))
            if case .clarification = outcome {} else { Issue.record("Partial addition became a review") }
            #expect(service.pendingReview == nil)
            #expect(controllerReads == 0)
            #expect(localAdds == 0)
            #expect(state.scope.graph.nodes.isEmpty)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
        }
    }

    @Test func truncatedAlphabeticTargetCannotCreateReviewOrQueryConsole() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        var controllerReads = 0
        let service = AssistantActionController(controller: { controllerReads += 1; return state.wing },
            layout: { state.layout }, scope: { state.scope }, addShortcut: { _, _, _, _ in nil })
        let intent = AssistantActionIntent(targetMention: "Juno", action: .mute, amount: nil, addToStudio: false,
            evidence: .init(target: "Juno", action: "mute", amount: nil, add: nil))
        for text in ["mute Juno Alpha", "mute Alpha Juno", "mute Juno_Alpha", "mute Alpha_Juno",
                     "mute Juno:Alpha", "mute Alpha:Juno", "mute Juno—Alpha", "mute Alpha—Juno"] {
            let outcome = await service.prepare(.init(text: text), interpretation: .proposal(intent))
            if case .clarification = outcome {} else { Issue.record("Truncated target became a review") }
            #expect(service.pendingReview == nil)
            #expect(controllerReads == 0)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
        }
    }

    @Test func trueSubmittedPartialNameStillRequiresCandidateSelection() async throws {
        let fixture = await fixture(label: "Juno Alpha")
        let intent = AssistantActionIntent(targetMention: "Juno", action: .mute, amount: nil, addToStudio: false,
            evidence: .init(target: "Juno", action: "mute", amount: nil, add: nil))
        let submission = AssistantActionInterpretationRequest(
            text: "mute Juno", liveContext: request(fixture).liveContext)
        guard case .review(let review) = await fixture.service.prepare(submission, interpretation: .proposal(intent))
        else { throw BackendTestError.send }
        #expect(review.stage == .chooseCandidate)
        #expect(review.candidates.contains { $0.id == WingNodeRef.channel(7).id })
        #expect(await fixture.transport.writes.isEmpty)
        await fixture.state.wing.disconnect()
    }

    @Test func currentRelativePercentCannotCreateAbsoluteReviewOrQueryConsole() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        var controllerReads = 0
        let service = AssistantActionController(controller: { controllerReads += 1; return state.wing },
            layout: { state.layout }, scope: { state.scope }, addShortcut: { _, _, _, _ in nil })
        let intent = AssistantActionIntent(
            targetMention: "Astrolab", action: .setFaderPercent, amount: 50, addToStudio: false,
            evidence: .init(target: "Astrolab", action: "set", amount: "50%", add: nil))
        for reference in ["of its current level", "of the current volume"] {
            let outcome = await service.prepare(.init(text: "set Astrolab to 50% \(reference)"),
                                                interpretation: .proposal(intent))
            if case .clarification = outcome {} else { Issue.record("Relative percentage became absolute travel") }
            #expect(service.pendingReview == nil)
            #expect(controllerReads == 0)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
        }
    }

    @Test func wordedDestinationCannotCreateSuggestedRelativeReviewOrQueryConsole() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        var controllerReads = 0
        let service = AssistantActionController(controller: { controllerReads += 1; return state.wing },
            layout: { state.layout }, scope: { state.scope }, addShortcut: { _, _, _, _ in nil })
        let intent = AssistantActionIntent(targetMention: "Astrolab", action: .lower, amount: nil, addToStudio: false,
            evidence: .init(target: "Astrolab", action: "down", amount: nil, add: nil))
        for destination in ["zero", "off", "half"] {
            let outcome = await service.prepare(.init(text: "turn Astrolab down to \(destination)"),
                                                interpretation: .proposal(intent))
            if case .clarification = outcome {} else { Issue.record("Absolute destination became a relative step") }
            #expect(service.pendingReview == nil)
            #expect(controllerReads == 0)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
        }
    }

    @Test func differentAddTargetCannotReachConsoleOrLocalShortcutInsertion() async {
        let transport = AssistantRecordingWingTransport()
        let state = AssistantActionTestState(wing: WingController(transport: transport))
        var controllerReads = 0
        var localAdds = 0
        let service = AssistantActionController(
            controller: { controllerReads += 1; return state.wing }, layout: { state.layout },
            scope: { state.scope }, addShortcut: { _, _, _, _ in localAdds += 1; return nil })
        let intent = AssistantActionIntent(targetMention: "Astrolab", action: .mute, amount: nil, addToStudio: true,
            evidence: .init(target: "Astrolab", action: "mute", amount: nil, add: "add"))
        for text in ["mute Astrolab and add Juno", "add Astrolab and mute Juno"] {
            let outcome = await service.prepare(.init(text: text), interpretation: .proposal(intent))
            if case .clarification = outcome {} else {
                Issue.record("Compound request silently changed its add target")
            }
            #expect(service.pendingReview == nil)
            #expect(controllerReads == 0)
            #expect(localAdds == 0)
            #expect(state.scope.graph.nodes.isEmpty)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
        }
    }
}
