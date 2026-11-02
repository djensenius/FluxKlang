import Testing

@testable import FluxKlang

@MainActor
struct AssistantRecordingWingTransportGateTests {
    @Test(arguments: RecordingWingFixtureGate.allCases)
    func releaseBeforeEntryDisarmsThePendingPause(_ gate: RecordingWingFixtureGate) async throws {
        let transport = AssistantRecordingWingTransport()
        await gate.pause(transport)
        await gate.release(transport)
        await gate.release(transport)

        try await withCall(gate, transport: transport) { _ in
            #expect(await !gate.isWaiting(transport))
        }
    }

    @Test(arguments: RecordingWingFixtureGate.allCases)
    func releaseResumesTheCallerAndAllowsExplicitRearming(_ gate: RecordingWingFixtureGate) async throws {
        let transport = AssistantRecordingWingTransport()
        for _ in 0..<2 {
            await gate.pause(transport)
            try await withCall(gate, transport: transport) { completion in
                #expect(await gate.isWaiting(transport))
                #expect(!completion.finished)
            }
            await gate.release(transport)
        }
    }

    private func withCall(
        _ gate: RecordingWingFixtureGate,
        transport: AssistantRecordingWingTransport,
        assertions: @MainActor (RecordingWingGateCompletion) async throws -> Void
    ) async throws {
        let completion = RecordingWingGateCompletion()
        let original = Task {
            await gate.enter(transport)
            completion.finished = true
        }
        do {
            try await AssistantBackendFixture.waitAsync {
                if completion.finished { return true }
                return await gate.isWaiting(transport)
            }
            try await assertions(completion)
        } catch {
            await gate.release(transport)
            await original.value
            throw error
        }
        await gate.release(transport)
        await original.value
    }
}

@MainActor
private final class RecordingWingGateCompletion {
    var finished = false
}

enum RecordingWingFixtureGate: CaseIterable, Sendable {
    case start
    case session
    case peers

    func pause(_ transport: AssistantRecordingWingTransport) async {
        switch self {
        case .start: await transport.pauseStart()
        case .session: await transport.pauseBindingRead(.session)
        case .peers: await transport.pauseBindingRead(.peers)
        }
    }

    func release(_ transport: AssistantRecordingWingTransport) async {
        switch self {
        case .start: await transport.releaseStart()
        case .session, .peers: await transport.releaseBindingRead()
        }
    }

    func isWaiting(_ transport: AssistantRecordingWingTransport) async -> Bool {
        switch self {
        case .start: await transport.startWaiting
        case .session, .peers: await transport.bindingReadWaiting
        }
    }

    func enter(_ transport: AssistantRecordingWingTransport) async {
        switch self {
        case .start:
            await transport.start(remoteHost: "192.0.2.10", localPort: nil, broadcast: false)
        case .session:
            _ = await transport.sessionID
        case .peers:
            _ = await transport.peerHosts
        }
    }
}
