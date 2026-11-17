//
//  WingApplyGrantMinter.swift
//  FluxKlang
//
//  The production grant minter for a gated Studio apply (#62 AU7b). Built only
//  from injected dependencies; nothing constructs it yet (AU7c wires it).
//

/// The intent and admission context a Studio apply is admitted under, read fresh
/// for every mint: the intent carries the host epoch and permission, and the book
/// refuses a stale one.
struct WingApplyAdmission: Sendable {
    let intent: CommandIntent
    let admission: AdmissionContext
}

/// Mints one grant per chunk of a gated apply: admits a `.bind(applyRoute)`
/// ticket, then spends it on exactly that chunk's targets. One minter per apply.
/// It stores no grant and no per-mint state; every step fails closed.
struct WingApplyGrantMinter: WingDirectGrantMinting {
    typealias Provider = @Sendable () async -> WingApplyAdmission?

    let authority: HostAuthority
    let project: ProjectID
    let window: WindowID
    let budget: WingApplyTicketBudget
    let provider: Provider

    func grant(for phase: WingDirectApplyPhase,
               targets: [DirectSendTarget]) async -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        guard budget.take() else { return .failure(.tooManyOutstanding) }
        guard let current = await provider() else { return .failure(.staleLive) }
        guard current.intent.operation == .bind(WingDirectSendScope.applyRoute) else {
            return .failure(.outOfScope)
        }
        switch await authority.admitDirect(current.intent, admission: current.admission,
                                           project: project, window: window) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let ticket):
            guard let ticket else { return .failure(.notOutstanding) }
            return await authority.authorizeDirectSend(ticket, targets: targets)
        }
    }
}
