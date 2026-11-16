//
//  HostCommandGate.swift
//  FluxKlang
//
//  Admits direct commands against the engine lifecycle. It wraps
//  `CommandAdmission` unchanged and adds only the lifecycle check.
//

enum HostCommandDecision: Hashable, Sendable {
    /// Validated intent only: does not grant activation, an engine lease or perform a write.
    case admitted
    /// `CommandAdmission`'s refusal, unchanged.
    case refused(CommandResult)
    /// Admissible, but the lifecycle does not accept changes to the running set.
    case unavailable(EngineLifecycle)
}

enum HostCommandGate {
    /// `CommandAdmission` first, so epoch, permission and scope refusals keep
    /// their reasons. Then, while recovering or held by another project, only
    /// safety commands (panic, safe mute) and draft-scoped commands (propose,
    /// edit draft) pass; anything that changes the running set is unavailable.
    static func admit(_ intent: CommandIntent, admission: AdmissionContext,
                      lifecycle: EngineLifecycle) -> HostCommandDecision {
        if case .refused(let result) = CommandAdmission.admit(intent, in: admission) { return .refused(result) }
        switch intent.operation.scope {
        case .safety, .draft: return .admitted
        case .parameter, .route, .patch, .action, .transport:
            return lifecycle.acceptsRunningSetChanges ? .admitted : .unavailable(lifecycle)
        }
    }
}

/// Why a direct write (#62 AU1) was refused, by `HostAuthorityBook.admitDirect` or
/// `HostAuthorityBook.redeemDirect`.
enum DirectWriteRefusal: Error, Hashable, Sendable {
    /// `HostCommandGate.admit`'s refusal, unchanged; never `.admitted`.
    case gate(HostCommandDecision)
    case unknownProject
    /// The window does not render under the lease: a running-set change needs `.renders`.
    case windowCannotWrite(WindowRenderRole)
    /// The admission context, or the ticket, is not the book's live host epoch and permission.
    case staleLive
    /// The lease the ticket was admitted under is no longer the held lease.
    case staleLease
    /// A commit of the ticket's project was delivered to the engine and is not yet reported.
    case commitInFlight
    /// The engine context changed since admission.
    case staleContext
    /// Never minted by this book, already redeemed (refused or not), dropped by
    /// `detach` of its window, or dropped as unredeemable at capacity.
    case notOutstanding
    case recovering
    /// `HostAuthority.directWriteCapacity` redeemable tickets are outstanding.
    case tooManyOutstanding
}

/// What a ticket is checked against at redemption, read from the book at that moment.
struct DirectWriteFence {
    /// nil for an unknown project.
    let lifecycle: EngineLifecycle?
    let live: HostLiveState
    let held: EngineLeaseToken?
    let role: WindowRenderRole
    let commitInFlight: Bool
    let context: Generation?
}

extension HostCommandGate {
    /// Direct-write admission, in order: `admit` runs first, unchanged, and its
    /// refusal is passed through as `.gate`; safety and draft scopes then need no
    /// ticket (`nil`). Running-set changes additionally need `admission`'s host
    /// epoch and permission to be `live`'s (`staleLive`): the gate only compares the
    /// intent with the caller-supplied `admission`, so this ties what it validated
    /// to the book's live state, which the ticket then records. Then `role` must be
    /// `.renders`, returning that lease. This is stricter than
    /// `acceptsRunningSetChanges` when no project holds the lease (window role
    /// `.stopped`): `admit` accepts the stored command, but no direct write is
    /// granted, since process locality confers no privilege. A window that renders
    /// for a holder whose project lifecycle is `.stopped` is granted a ticket, as
    /// `admit` accepts it: the holder owns the engine.
    static func admitDirect(
        _ intent: CommandIntent, admission: AdmissionContext, lifecycle: EngineLifecycle,
        role: WindowRenderRole, live: HostLiveState
    ) -> Result<EngineLeaseToken?, DirectWriteRefusal> {
        let decision = admit(intent, admission: admission, lifecycle: lifecycle)
        guard decision == .admitted else { return .failure(.gate(decision)) }
        switch intent.operation.scope {
        case .safety, .draft: return .success(nil)
        case .parameter, .route, .patch, .action, .transport:
            guard admission.hostEpoch == live.hostEpoch, admission.permission == live.permission else {
                return .failure(.staleLive)
            }
            guard case .renders(let lease) = role else { return .failure(.windowCannotWrite(role)) }
            return .success(lease)
        }
    }

    /// Why `ticket` cannot be redeemed against `now`, or nil. Precedence: unknown
    /// project; `.recovering`; live host epoch or permission changed (`staleLive`);
    /// the held lease is not the ticket's (`staleLease`, also when no lease is
    /// held); the window no longer renders under it (`windowCannotWrite`;
    /// unreachable today, since `detach` drops the window's tickets); a commit of
    /// the project is in flight (`commitInFlight`; once reported, a successful
    /// commit's context bump makes it `staleContext`); the engine context moved
    /// (`staleContext`). Outstanding-ness is the caller's check.
    static func redeemRefusal(_ ticket: DirectWriteTicket, now: DirectWriteFence) -> DirectWriteRefusal? {
        // Unreachable today (projects never close while a ticket is outstanding); fails closed.
        guard let lifecycle = now.lifecycle else { return .unknownProject }
        guard lifecycle != .recovering else { return .recovering }
        guard now.live.hostEpoch == ticket.hostEpoch, now.live.permission == ticket.permission else {
            return .staleLive
        }
        guard now.held == ticket.lease else { return .staleLease }
        guard now.role == .renders(ticket.lease) else { return .windowCannotWrite(now.role) }
        guard !now.commitInFlight else { return .commitInFlight }
        guard now.context == ticket.context else { return .staleContext }
        return nil
    }
}
