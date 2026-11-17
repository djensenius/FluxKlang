//
//  WingApplyMinterBench.swift
//  FluxKlangTests
//
//  Setup for the production `WingApplyGrantMinter` tests (#62 AU7b): a real
//  authority under `WingDirectSendScope`, the provider's admission, and a
//  recording wrapper around the real minter. No audio, MIDI, hardware or I/O.
//

import Foundation
import Testing
@testable import FluxKlang

enum WingApplyBench {
    /// A real authority whose send scope is the production `WingDirectSendScope`.
    static func authority() async throws -> HostAuthority {
        try await AuthorityBench.makeAuthority(sendScope: WingDirectSendScope())
    }

    /// A `.structural` `.human` `.bind(route)` intent and an admission allowing exactly `.route(route)`.
    static func admission(route: RouteID = WingDirectSendScope.applyRoute,
                          epoch: HostEpoch = AuthorityBench.hostEpoch) throws -> WingApplyAdmission {
        let context = AdmissionContext(hostEpoch: epoch, connectionEpoch: nil, revisions: CommandRevisions(),
                                       permission: AuthorityBench.permission, allowedScopes: [.route(route)],
                                       allowedClasses: Set(ControlClass.allCases),
                                       catalog: try DirectSendBench.catalog())
        let intent = try CommandIntent(.init(
            id: CommandID(validated: "command.bind"), commandClass: .structural, origin: .human,
            hostEpoch: epoch, connectionEpoch: nil, revisions: CommandRevisions(),
            operation: .bind(route), permission: AuthorityBench.permission
        ))
        return WingApplyAdmission(intent: intent, admission: context)
    }

    /// A parameter-scoped `.set` admission, which a Studio apply must never run on. The
    /// default parameter is a WING fader, so its ticket would admit a fader address.
    static func parameterAdmission(
        _ parameter: ParameterID = ParameterCatalog.wingFaderDecibels
    ) throws -> WingApplyAdmission {
        WingApplyAdmission(intent: try DirectSendBench.intent(parameter),
                           admission: try DirectSendBench.admission(parameter))
    }

    static func minter(_ authority: HostAuthority, budget: WingApplyTicketBudget,
                       provider: @escaping WingApplyGrantMinter.Provider) -> WingApplyGrantMinter {
        WingApplyGrantMinter(authority: authority, project: AuthorityBench.projectA,
                             window: AuthorityBench.windowA, budget: budget, provider: provider)
    }

    /// The minter a composition root would build: the apply route's admission, read on every mint.
    static func minter(_ authority: HostAuthority, budget: WingApplyTicketBudget) throws -> WingApplyGrantMinter {
        let admission = try admission()
        return minter(authority, budget: budget) { admission }
    }

    /// The first `count` distinct WING query addresses of a class the apply route admits, each set to 1.
    static func settings(_ count: Int) throws -> [WingSetting] {
        let addresses = WingAddress.allQueryAddresses().filter { WingRouteAddressClass(address: $0) != nil }
        try #require(addresses.count >= count)
        return addresses.prefix(count).map { WingSetting(address: $0, value: .int(1)) }
    }

    static func targets(_ settings: some Sequence<WingSetting>) -> [DirectSendTarget] {
        settings.map { DirectSendTarget($0.address) }
    }

    /// How many tickets `budget` hands out before it refuses.
    static func drain(_ budget: WingApplyTicketBudget) -> Int {
        var taken = 0
        while taken < 1_000, budget.take() { taken += 1 }
        return taken
    }
}

/// Wraps the real minter, recording what the controller asked for and what came back.
actor RecordingApplyMinter: WingDirectGrantMinting {
    struct Mint: Sendable {
        let phase: WingDirectApplyPhase
        let targets: [DirectSendTarget]
        let refusal: DirectWriteRefusal?
    }

    typealias Step = @MainActor @Sendable () async -> Void

    private let minter: WingApplyGrantMinter
    private(set) var mints: [Mint] = []
    private var before: (phase: WingDirectApplyPhase, step: Step)?

    init(_ minter: WingApplyGrantMinter) {
        self.minter = minter
    }

    var phases: [WingDirectApplyPhase] { mints.map(\.phase) }

    /// Runs `step` once, just before the first mint of `phase` is delegated.
    func run(before phase: WingDirectApplyPhase, _ step: @escaping Step) { before = (phase, step) }

    func grant(for phase: WingDirectApplyPhase,
               targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        if let planned = before, planned.phase == phase {
            before = nil
            await planned.step()
        }
        let result = await minter.grant(for: phase, targets: targets)
        mints.append(Mint(phase: phase, targets: targets, refusal: DirectSendBench.refusal(result)))
        return result
    }
}
