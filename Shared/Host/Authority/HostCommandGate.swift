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
