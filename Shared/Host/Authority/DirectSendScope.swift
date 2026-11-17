//
//  DirectSendScope.swift
//  FluxKlang
//
//  Which direct-send targets a ticket's `CommandScope` admits (#62 AU5).
//  `HostAuthority` asks its policy when it mints a grant, so a ticket admitted
//  for one scope cannot bind targets outside it. The authority stays neutral:
//  device-specific policies (e.g. `WingDirectSendScope`) live with their device.
//

/// Injected once, at `HostAuthority` init. Implementations are pure: no state,
/// no locks, no awaits; the authority calls them on its actor for every target.
protocol DirectSendScopePolicy: Sendable {
    func admits(_ target: DirectSendTarget, under scope: CommandScope) -> Bool
}

/// The default: no scope admits any target, so an authority built without a
/// policy refuses every grant with `.outOfScope`.
struct DenyAllDirectSendScope: DirectSendScopePolicy {
    func admits(_ target: DirectSendTarget, under scope: CommandScope) -> Bool { false }
}
