//
//  DirectSendTransports.swift
//  FluxKlangTests
//
//  Socket-free WING transports and grant setup for the direct-send tests
//  (#62 AU3/AU4). No audio, MIDI, hardware or I/O.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Mints direct-send grants on an `AuthorityBench` authority: a running-set `.set`
/// of `liveParameter`, or of a `ParameterCatalog.wing` parameter, admitted for
/// project A (as in `HostAuthorityTests+DirectWrite.swift`).
enum DirectSendBench {
    static let liveParameter = ParameterID(validated: "parameter.live")

    static func nextEpoch() throws -> HostEpoch {
        HostEpoch(host: AuthorityBench.host, generation: try Generation.initial.next())
    }

    /// `liveParameter` plus the WING parameters.
    static func catalog() throws -> ParameterCatalog {
        let descriptor = try ParameterDescriptor(.init(
            id: liveParameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8, curve: .linear,
            ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
            controlClass: .live, verification: .reported
        ))
        return try ParameterCatalog([descriptor] + ParameterCatalog.wing.parameters)
    }

    static func admission(_ parameter: ParameterID = liveParameter) throws -> AdmissionContext {
        AdmissionContext(hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil,
                         revisions: CommandRevisions(), permission: AuthorityBench.permission,
                         allowedScopes: [.parameter(parameter)], allowedClasses: Set(ControlClass.allCases),
                         catalog: try catalog())
    }

    /// Sets `parameter` to its default value.
    static func intent(_ parameter: ParameterID = liveParameter) throws -> CommandIntent {
        let descriptor = try #require(try catalog()[parameter])
        return try CommandIntent(.init(
            id: CommandID(validated: "command.batch"), commandClass: .live, origin: .human,
            hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(),
            operation: .set(parameter, ParameterValue(value: descriptor.defaultValue, unit: descriptor.unit)),
            permission: AuthorityBench.permission
        ))
    }

    /// A ticket whose scope is `.parameter(parameter)`.
    static func ticket(_ authority: HostAuthority,
                       parameter: ParameterID = liveParameter) async throws -> DirectWriteTicket {
        try #require(try await authority.admitDirect(try intent(parameter), admission: try admission(parameter),
                                                     project: AuthorityBench.projectA,
                                                     window: AuthorityBench.windowA).get())
    }

    static func grant(_ authority: HostAuthority, targets: [DirectSendTarget],
                      parameter: ParameterID = liveParameter) async throws -> DirectWriteAuthorization {
        try await authority.authorizeDirectSend(try await ticket(authority, parameter: parameter),
                                                targets: targets).get()
    }

    /// A ticket whose scope is `.route(route)`: a `.structural` `.bind(route)`
    /// admitted for project A (#62 AU7a).
    static func ticket(_ authority: HostAuthority, route: RouteID) async throws -> DirectWriteTicket {
        let admission = AdmissionContext(hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil,
                                         revisions: CommandRevisions(), permission: AuthorityBench.permission,
                                         allowedScopes: [.route(route)], allowedClasses: Set(ControlClass.allCases),
                                         catalog: try catalog())
        let intent = try CommandIntent(.init(
            id: CommandID(validated: "command.bind"), commandClass: .structural, origin: .human,
            hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(),
            operation: .bind(route), permission: AuthorityBench.permission
        ))
        return try #require(try await authority.admitDirect(intent, admission: admission,
                                                            project: AuthorityBench.projectA,
                                                            window: AuthorityBench.windowA).get())
    }

    /// A grant binding each setting's address.
    static func grant(_ authority: HostAuthority, settings: [WingSetting],
                      parameter: ParameterID = liveParameter) async throws -> DirectWriteAuthorization {
        try await grant(authority, targets: settings.map { DirectSendTarget($0.address) }, parameter: parameter)
    }

    static func refusal<Success>(_ result: Result<Success, DirectWriteRefusal>) -> DirectWriteRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    /// Why `grant` refuses `target`; its body must never run. Use only once the
    /// grant is spent or revoked: an armed grant that does not bind `target` is
    /// revoked by this call.
    static func refusal(of grant: DirectWriteAuthorization, target: String) -> DirectWriteRefusal? {
        do {
            try grant.consume(DirectSendTarget(target)) { Issue.record("A spent or revoked grant ran its send") }
        } catch let refusal as DirectWriteRefusal {
            return refusal
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        return nil
    }
}

/// Test-only `DirectSendScopePolicy` admitting every target under every scope;
/// `AuthorityBench.makeAuthority`'s default, so tests not about scope mint freely.
struct AnyTargetScope: DirectSendScopePolicy {
    func admits(_ target: DirectSendTarget, under scope: CommandScope) -> Bool { true }
}

/// No socket. Records direct SETs and legacy SETs; GETs are dropped. Its session
/// check mirrors `WingTransport.sendDirect`; addresses passed to `fail` throw
/// inside `consume`, after the target is spent.
actor DirectSendRecordingTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private(set) var sessionID: UUID?
    private(set) var peerHosts: Set<String> = []
    private(set) var directCalls = 0
    private(set) var directWrites: [WingSetting] = []
    private(set) var legacyWrites: [WingSetting] = []
    private var failing: Set<String> = []

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) {
        sessionID = UUID()
        peerHosts = [remoteHost]
    }

    /// A transport restart the controller has not observed.
    func restart() { sessionID = UUID() }

    func fail(_ address: String) { failing.insert(address) }

    func stop() {
        sessionID = nil
        peerHosts = []
    }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) {
        if let value { legacyWrites.append(WingSetting(address: address, value: value)) }
    }

    func sendDirect(_ setting: WingSetting, sessionID: UUID, authorization: DirectWriteAuthorization) throws {
        directCalls += 1
        try authorization.consume(DirectSendTarget(setting.address)) {
            guard self.sessionID == sessionID else { throw WingTransportError.notAuthorized }
            guard !failing.contains(setting.address) else { throw WingTransportError.notStarted }
            directWrites.append(setting)
        }
    }
}

/// No socket and no direct path: `sendDirect` is the protocol default.
actor DefaultDirectSendTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private(set) var sends = 0

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) {}
    func stop() {}
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) { sends += 1 }
}

/// No socket. `sendDirect` spends the setting's target and records the write;
/// the first successful one then holds its return until `release()`, so a test can
/// change the controller session or the authority mid-batch. Later sends do not hold.
actor GatedDirectSendTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private(set) var sessionID: UUID?
    private(set) var directWrites: [WingSetting] = []
    private var holds = true
    private var held: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) { sessionID = UUID() }
    func stop() { sessionID = nil }
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) {}

    func sendDirect(_ setting: WingSetting, sessionID: UUID,
                    authorization: DirectWriteAuthorization) async throws {
        try authorization.consume(DirectSendTarget(setting.address)) {
            guard self.sessionID == sessionID else { throw WingTransportError.notAuthorized }
            directWrites.append(setting)
        }
        guard holds else { return }
        holds = false
        await withCheckedContinuation { continuation in
            held = continuation
            holdWaiters.forEach { $0.resume() }
            holdWaiters.removeAll()
        }
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
