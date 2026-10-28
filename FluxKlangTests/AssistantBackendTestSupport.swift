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

    static func waitAsync(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw BackendTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
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
    private(set) var queries: [String] = []
    private var values: [String: WingValue]
    private var answersQueries = true
    private var answersAfterWrite = true
    private var failsWrites = false
    private var mismatchesWrites = false
    private var queryDelay: Duration = .zero
    private var gateMixerSend = false
    private(set) var mixerSendWaiting = false
    private var mixerSendGate: CheckedContinuation<Void, Never>?
    private var gateBaselineAfterNames = false
    private var namesRead: Set<String> = []
    private var gateReadback = false
    private(set) var queryWaiting = false
    private var queryGates: [CheckedContinuation<Void, Never>] = []

    init() {
        (incoming, continuation) = AsyncStream.makeStream()
        values = Dictionary(
            uniqueKeysWithValues: (1...40).map {
                (WingAddress.name(.channel, $0), WingValue.string($0 == 7 ? "Lead" : ""))
            })
        for index in 1...24 { values[WingAddress.inputName(index)] = .string("") }
        for index in 1...40 {
            values[WingAddress.channelSourceGroup(index)] = .string(index <= 24 ? "LCL" : "OFF")
            values[WingAddress.channelSourceIndex(index)] = .int(Int32(index <= 24 ? index : 0))
        }
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
    func pauseMixerSend() { gateMixerSend = true }
    func releaseMixerSend() {
        gateMixerSend = false
        mixerSendGate?.resume()
        mixerSendGate = nil
    }
    func pauseBaselineAfterNameDiscovery() { gateBaselineAfterNames = true; namesRead = [] }
    func pauseReadback() { gateReadback = true }
    func releaseQueries() {
        gateBaselineAfterNames = false
        gateReadback = false
        let waiting = queryGates
        queryGates = []
        waiting.forEach { $0.resume() }
    }
    func put(_ address: String, _ value: WingValue) { values[address] = value }
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) async throws {
        if let value {
            try recordWrite(address, value)
        } else {
            queries.append(address)
            guard answersQueries, writes.isEmpty || answersAfterWrite else { return }
            if address.hasPrefix("/ch/"), address.hasSuffix("/name") { namesRead.insert(address) }
            if (gateBaselineAfterNames && namesRead.count == 40 && ["/ch/7/fdr", "/ch/7/mute"].contains(address))
                || (gateReadback && !writes.isEmpty) {
                queryWaiting = true
                await withCheckedContinuation { queryGates.append($0) }
            }
            if queryDelay != .zero { try await Task.sleep(for: queryDelay) }
            if let value = values[address] { emitQuery(address, value) }
        }
    }
    func sendMixerValue(_ node: WingNodeRef, value: WingValue, muted: Bool, sessionID: UUID,
                        authorization: WingMixerWriteAuthorization) async throws {
        if gateMixerSend {
            mixerSendWaiting = true
            await withCheckedContinuation { mixerSendGate = $0 }
        }
        try authorization.consume {
            guard self.sessionID == sessionID else { throw BackendTestError.send }
            let address = muted ? WingAddress.mute(node.kind, node.index) : WingAddress.fader(node.kind, node.index)
            try recordWrite(address, value.encodedForWing(address: address))
        }
    }
    private func recordWrite(_ address: String, _ value: WingValue) throws {
        writes.append(WingSetting(address: address, value: value))
        if failsWrites { throw BackendTestError.send }
        if !mismatchesWrites { values[address] = value.decodedFromWingSet(address: address) }
    }
    private func emitQuery(_ address: String, _ value: WingValue) {
        let reply: [WingValue]
        if address.hasSuffix("/fdr"), let position = value.floatValue {
            reply = [.string(FaderMath.label(forPosition: position)), .float(position),
                     .float(FaderMath.decibels(fromPosition: position))]
        } else if address.hasSuffix("/mute"), let muted = value.intValue {
            reply = [.string(muted == 1 ? "ON" : "OFF"), .float(Float(muted)), .int(muted)]
        } else if address.hasSuffix("/in/conn/in"), let index = value.intValue {
            reply = [.string(String(index)), .float(0), .int(max(0, index - 1))]
        } else if address.hasSuffix("/in/conn/grp"), let group = value.stringValue {
            reply = [.string(group), .float(0), .string(group)]
        } else { reply = [value] }
        continuation.yield(WingIncoming(address: address, values: reply, host: "192.0.2.10",
            port: WingNetwork.defaultPort, transportSessionID: sessionID))
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
