//
//  GatedApplyBench.swift
//  FluxKlangTests
//
//  A phase-recording grant minter and a socket-free echoing WING transport for
//  the grant-gated `applyAndVerify` tests (#62 AU6). No audio, MIDI, hardware or I/O.
//

import Foundation
import Testing
@testable import FluxKlang

/// Mints each phase's grant on an `AuthorityBench` authority through
/// `DirectSendBench` (a fresh ticket per call) and records what it was asked for.
/// It can refuse a phase without minting, or change the live state between a
/// phase's admission and its grant, as a live update during verification would.
actor GatedApplyMinter: WingDirectGrantMinting {
    struct Mint: Sendable {
        let phase: WingDirectApplyPhase
        let targets: Set<DirectSendTarget>
        /// Armed grants on the authority just before this mint.
        let outstandingBefore: Int
        let result: Result<DirectWriteAuthorization, DirectWriteRefusal>
    }

    let authority: HostAuthority
    private let parameter: ParameterID
    private(set) var mints: [Mint] = []
    private var refusing: [WingDirectApplyPhase: DirectWriteRefusal] = [:]
    private var bumpingLive: Set<WingDirectApplyPhase> = []

    init(_ authority: HostAuthority, parameter: ParameterID = DirectSendBench.liveParameter) {
        self.authority = authority
        self.parameter = parameter
    }

    var phases: [WingDirectApplyPhase] { mints.map(\.phase) }
    var grants: [DirectWriteAuthorization] { mints.compactMap { try? $0.result.get() } }

    func refuse(_ phase: WingDirectApplyPhase, with refusal: DirectWriteRefusal = .notOutstanding) {
        refusing[phase] = refusal
    }

    func bumpLive(before phase: WingDirectApplyPhase) { bumpingLive.insert(phase) }

    func grant(for phase: WingDirectApplyPhase,
               targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        let outstanding = await authority.outstandingDirectSendCount()
        let result = await mint(phase, targets: targets)
        mints.append(Mint(phase: phase, targets: Set(targets), outstandingBefore: outstanding, result: result))
        return result
    }

    private func mint(_ phase: WingDirectApplyPhase,
                      targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        if let refusal = refusing[phase] { return .failure(refusal) }
        do {
            let ticket = try await DirectSendBench.ticket(authority, parameter: parameter)
            if bumpingLive.contains(phase) {
                await authority.updateLive(try AuthorityBench.liveState(epoch: try DirectSendBench.nextEpoch()))
            }
            return await authority.authorizeDirectSend(ticket, targets: targets)
        } catch {
            Issue.record("Could not admit a ticket for \(phase): \(error)")
            return .failure(.notOutstanding)
        }
    }
}

/// No socket. `sendDirect` spends the setting's target inside the grant's
/// `consume` and stores the value; a GET of a stored address is answered with it,
/// so the controller confirms what was sent. `drop` leaves the next `times` writes
/// of an address unstored (sent, never confirmed), `fail` makes its writes throw
/// inside `consume`, and `holdNextWrite` holds the next successful direct write's
/// return until `release()`.
actor EchoingDirectTransport: WingTransporting {
    nonisolated let incoming: AsyncStream<WingIncoming>
    private let continuation: AsyncStream<WingIncoming>.Continuation
    private(set) var sessionID: UUID?
    private(set) var peerHosts: Set<String> = []
    private(set) var directCalls = 0
    private(set) var directWrites: [WingSetting] = []
    private(set) var legacyWrites: [WingSetting] = []
    private var stored: [String: WingValue] = [:]
    private var dropping: [String: Int] = [:]
    private var failing: Set<String> = []
    private var holds = false
    private var held: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        (incoming, continuation) = AsyncStream.makeStream()
    }

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) {
        sessionID = UUID()
        peerHosts = [remoteHost]
    }

    func stop() {
        sessionID = nil
        peerHosts = []
    }

    func drop(_ address: String, times: Int = .max) { dropping[address] = times }

    func fail(_ address: String) { failing.insert(address) }

    func holdNextWrite() { holds = true }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) {
        if let value {
            legacyWrites.append(WingSetting(address: address, value: value))
        } else if let value = stored[address], let sessionID, let host = peerHosts.first {
            continuation.yield(WingIncoming(address: address, value: value, host: host, port: WingNetwork.defaultPort,
                                            transportSessionID: sessionID))
        }
    }

    func sendDirect(_ setting: WingSetting, sessionID: UUID,
                    authorization: DirectWriteAuthorization) async throws {
        directCalls += 1
        try authorization.consume(DirectSendTarget(setting.address)) {
            guard self.sessionID == sessionID else { throw WingTransportError.notAuthorized }
            guard !failing.contains(setting.address) else { throw WingTransportError.notStarted }
            directWrites.append(setting)
            if let remaining = dropping[setting.address], remaining > 0 {
                dropping[setting.address] = remaining - 1
            } else {
                stored[setting.address] = setting.value
            }
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
