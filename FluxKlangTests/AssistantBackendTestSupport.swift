import Foundation

@testable import FluxKlang

@MainActor
enum AssistantBackendFixture {
    static func context(equipment: [Equipment] = [], inputs: [StudioInputConnection] = []) -> AssistantToolContext {
        let connections = GlobalStudioConnections(home: StudioHomeConnections(inputs: inputs))
        return AssistantToolContext(
            currentScreen: .assistant,
            connection: .init(status: .connected, detail: nil, isDemo: false),
            equipment: equipment, homeConnections: connections.home, effectiveConnections: connections.effectiveHome,
            activeMoves: [], environments: [], activeEnvironmentID: nil, presets: [], resources: [],
            validationIssues: [], graph: StudioGraph(), endpoints: [], effects: [], globalConnections: connections
        )
    }

    static func observe(
        _ values: [String: WingValue], context: AssistantToolContext,
        session: UUID = UUID(), age: TimeInterval = 0,
        status: WingConfirmedSnapshot.Status = .observed
    ) -> AssistantToolContext {
        var result = context
        let now = Date()
        let snapshot = WingConfirmedSnapshot(
            status: status, sessionID: session, capturedAt: now,
            values: values, receivedAt: values.mapValues { _ in now.addingTimeInterval(-age) })
        result.liveWing = AssistantLiveWingContext.project(
            snapshot, equipment: context.equipment,
            connections: context.effectiveConnections)
        return result
    }

    static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BackendTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

enum BackendTestError: Error { case timeout, send }

actor AssistantBackendDraftStore: PendingStudioPatchPersisting {
    var draft: StudioPatchDraft?
    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft }
}

/// Replies and writes exist only in this recording actor. Never opens a socket.
actor AssistantRecordingWingTransport: WingTransporting {
    nonisolated let incoming: AsyncStream<WingIncoming>
    private let continuation: AsyncStream<WingIncoming>.Continuation
    private(set) var sessionID: UUID?
    let peerHosts: Set<String> = ["192.0.2.10"]
    private(set) var writes: [WingSetting] = []
    private var values: [String: WingValue]
    private var answersQueries = true
    private var answersAfterWrite = true
    private var failsWrites = false
    private var mismatchesWrites = false
    private var queryDelay: Duration = .zero

    init() {
        (incoming, continuation) = AsyncStream.makeStream()
        values = Dictionary(
            uniqueKeysWithValues: (1...40).map {
                (WingAddress.name(.channel, $0), WingValue.string($0 == 7 ? "Lead" : ""))
            })
        for node in [WingNodeRef.channel(7), .main(1)] {
            values[WingAddress.name(node.kind, node.index)] = .string(node.kind == .main ? "Main" : "Lead")
            values[WingAddress.fader(node.kind, node.index)] = .float(0.75)
            values[WingAddress.mute(node.kind, node.index)] = .int(0)
        }
    }

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) { sessionID = UUID() }
    func stop() { sessionID = nil }
    func configure(
        answers: Bool = true, afterWrite: Bool = true, fail: Bool = false,
        mismatch: Bool = false, delay: Duration = .zero
    ) {
        answersQueries = answers
        answersAfterWrite = afterWrite
        failsWrites = fail
        mismatchesWrites = mismatch
        queryDelay = delay
    }
    func put(_ address: String, _ value: WingValue) { values[address] = value }
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) async throws {
        if let value {
            writes.append(WingSetting(address: address, value: value))
            if failsWrites { throw BackendTestError.send }
            if !mismatchesWrites { values[address] = value.decodedFromWingSet(address: address) }
        } else {
            guard answersQueries, writes.isEmpty || answersAfterWrite else { return }
            if queryDelay != .zero { try await Task.sleep(for: queryDelay) }
            if let value = values[address] { emit(address, value) }
        }
    }
    func sendMixerValue(_ node: WingNodeRef, value: WingValue, muted: Bool, sessionID: UUID) async throws {
        guard self.sessionID == sessionID else { throw BackendTestError.send }
        let address = muted ? WingAddress.mute(node.kind, node.index) : WingAddress.fader(node.kind, node.index)
        try await send(address, value.encodedForWing(address: address), to: nil, port: nil)
    }
    func emit(
        _ address: String, _ value: WingValue, host: String = "192.0.2.10",
        port: UInt16 = WingNetwork.defaultPort, session: UUID? = nil, date: Date = Date()
    ) {
        continuation.yield(
            WingIncoming(
                address: address, value: value, host: host, port: port,
                transportSessionID: session ?? sessionID, receivedAt: date))
    }
}
