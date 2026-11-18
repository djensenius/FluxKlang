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

/// Mints each grant on an `AuthorityBench` authority through `DirectSendBench`
/// (a fresh ticket per call) and records what it was asked for. It can refuse a
/// phase's mints by index, change the live state between a phase's admission and
/// its grant, as a live update during verification would, or run a step after a
/// phase's `n`th successful mint, before any send.
actor GatedApplyMinter: WingDirectGrantMinting {
    struct Mint: Sendable {
        let phase: WingDirectApplyPhase
        let targets: Set<DirectSendTarget>
        /// `targets` in the order the controller bound them.
        let orderedTargets: [DirectSendTarget]
        /// Armed grants on the authority just before this mint.
        let outstandingBefore: Int
        let result: Result<DirectWriteAuthorization, DirectWriteRefusal>
    }

    typealias Step = @MainActor @Sendable () async -> Void

    let authority: HostAuthority
    private let parameter: ParameterID
    private let route: RouteID?
    private(set) var mints: [Mint] = []
    private var refusing: [WingDirectApplyPhase: (refusal: DirectWriteRefusal, mints: Range<Int>)] = [:]
    private var bumpingLive: Set<WingDirectApplyPhase> = []
    private var steps: [WingDirectApplyPhase: (mint: Int, step: Step)] = [:]

    init(_ authority: HostAuthority, parameter: ParameterID = DirectSendBench.liveParameter) {
        self.authority = authority
        self.parameter = parameter
        route = nil
    }

    /// Admits a `.bind(route)` ticket for each phase instead (#62 AU7a).
    init(_ authority: HostAuthority, route: RouteID) {
        self.authority = authority
        parameter = DirectSendBench.liveParameter
        self.route = route
    }

    var phases: [WingDirectApplyPhase] { mints.map(\.phase) }
    var grants: [DirectWriteAuthorization] { mints.compactMap { try? $0.result.get() } }

    /// Refuses `phase`'s mints whose 0-based index, counted over this minter's life, is in `mints`.
    func refuse(_ phase: WingDirectApplyPhase, with refusal: DirectWriteRefusal = .notOutstanding,
                mints: Range<Int> = 0..<Int.max) {
        refusing[phase] = (refusal, mints)
    }

    func bumpLive(before phase: WingDirectApplyPhase) { bumpingLive.insert(phase) }

    /// Runs `step` after `phase`'s `mint`th (0-based) mint succeeds, before the grant is returned.
    func after(_ phase: WingDirectApplyPhase, mint: Int, run step: @escaping Step) { steps[phase] = (mint, step) }

    func grant(for phase: WingDirectApplyPhase,
               targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        let index = mints.count { $0.phase == phase }
        let outstanding = await authority.outstandingDirectSendCount()
        let result = await mint(phase, index: index, targets: targets)
        mints.append(Mint(phase: phase, targets: Set(targets), orderedTargets: targets,
                          outstandingBefore: outstanding, result: result))
        if case .success = result, let planned = steps[phase], planned.mint == index { await planned.step() }
        return result
    }

    private func mint(_ phase: WingDirectApplyPhase, index: Int,
                      targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        if let refusal = refusing[phase], refusal.mints.contains(index) { return .failure(refusal.refusal) }
        do {
            let ticket = if let route {
                try await DirectSendBench.ticket(authority, route: route)
            } else {
                try await DirectSendBench.ticket(authority, parameter: parameter)
            }
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
/// inside `consume`, `holdNextWrite` holds the next successful direct write's
/// return until `release()`, and `replaceSession` reconnects during verification.
/// Like `WingTransport`, `incoming` is one stream for the transport's lifetime:
/// `start`/`stop` keep it, the controller's single listener spans reconnects (#750),
/// and only `deinit` finishes it.
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
    private var replacing: (writes: Int, step: GatedApplyMinter.Step)?

    init() {
        (incoming, continuation) = AsyncStream.makeStream()
    }

    deinit { continuation.finish() }

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

    /// Stores each value and answers it at once, as a live update from the console would.
    func confirm(_ settings: [WingSetting]) {
        guard let sessionID, let host = peerHosts.first else { return }
        for setting in settings {
            stored[setting.address] = setting.value
            continuation.yield(WingIncoming(address: setting.address, value: setting.value, host: host,
                                            port: WingNetwork.defaultPort, transportSessionID: sessionID))
        }
    }

    /// Before answering the first GET sent once `writes` direct writes were made,
    /// runs `step` in its own task, so cancelling the querying task (a reconnect
    /// cancels the bulk refresh) cannot cut it short; the GET is then answered on
    /// whatever session is current, as a reconnect during verification would.
    func replaceSession(afterWrites writes: Int, run step: @escaping GatedApplyMinter.Step) {
        replacing = (writes, step)
    }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) async {
        if value == nil, let planned = replacing, directWrites.count >= planned.writes {
            replacing = nil
            await Task { await planned.step() }.value
        }
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
