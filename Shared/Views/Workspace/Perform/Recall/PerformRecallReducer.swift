//
//  PerformRecallReducer.swift
//  FluxKlang
//
//  The reducer of one perform recall cell (#102 RCL1). It sends, authorizes and loads nothing.
//

/// A request to recall a target, to be turned into a command by a later slice. It authorizes nothing and holds no
/// command id, revision, value or time.
struct PerformRecallIntent: Equatable, Sendable {
    let target: PerformRecallTarget
    let controlClass: ControlClass
    let epoch: HostEpoch

    fileprivate init(target: PerformRecallTarget, controlClass: ControlClass, epoch: HostEpoch) {
        self.target = target
        self.controlClass = controlClass
        self.epoch = epoch
    }
}

/// The next phase and what to do about the event.
struct PerformRecallStep: Equatable, Sendable {
    let phase: PerformRecallPhase
    let decision: PerformRecallDecision

    fileprivate init(phase: PerformRecallPhase, decision: PerformRecallDecision) {
        self.phase = phase
        self.decision = decision
    }
}

enum PerformRecallReducer {
    /// Press and confirm check, in this order: resyncing, a held epoch that differs from the live one, permission,
    /// the target, the control class, a phase conflict, then readiness. Cancel and settle read no fact.
    static func reduce(
        _ phase: PerformRecallPhase,
        _ event: PerformRecallEvent,
        target: PerformRecallTarget,
        facts: PerformRecallFacts
    ) -> PerformRecallStep {
        switch event {
        case .press:
            if let stopped = gates(phase, facts, conflict: pressConflict(phase)) { return stopped }
            return press(target, facts)
        case .confirm:
            if let stopped = gates(phase, facts, conflict: confirmConflict(phase)) { return stopped }
            return fire(target, facts)
        case .cancel:
            return cancel(phase)
        case .settle:
            return settle(phase)
        }
    }

    private static func pressConflict(_ phase: PerformRecallPhase) -> PerformRecallRefusal? {
        switch phase {
        case .idle: nil
        case .awaitingConfirm: .alreadyAwaitingConfirm
        case .fired: .alreadyFired
        }
    }

    private static func confirmConflict(_ phase: PerformRecallPhase) -> PerformRecallRefusal? {
        switch phase {
        case .idle: .notAwaitingConfirm
        case .awaitingConfirm: nil
        case .fired: .alreadyFired
        }
    }

    /// The step that stops a press or confirm, or nil when it may go on.
    private static func gates(
        _ phase: PerformRecallPhase,
        _ facts: PerformRecallFacts,
        conflict: PerformRecallRefusal?
    ) -> PerformRecallStep? {
        if facts.resyncing { return drop(.resyncing) }
        if let held = phase.heldEpoch, held != facts.epoch { return drop(.staleEpoch) }
        if !facts.permitted { return refuse(phase, .notPermitted) }
        if !facts.targetExists { return refuse(phase, .noTarget) }
        switch facts.controlClass {
        case .live, .hazardous: break
        case .structural, .safety, .proposal:
            return refuse(phase, .classNotPerformable(facts.controlClass))
        }
        if let conflict { return refuse(phase, conflict) }
        if facts.readiness != .ready { return drop(.notReady(facts.readiness)) }
        return nil
    }

    private static func press(_ target: PerformRecallTarget, _ facts: PerformRecallFacts) -> PerformRecallStep {
        switch facts.controlClass {
        case .hazardous:
            return PerformRecallStep(phase: .awaitingConfirm(facts.epoch), decision: .awaitConfirm)
        case .live, .structural, .safety, .proposal:
            return fire(target, facts)
        }
    }

    private static func fire(_ target: PerformRecallTarget, _ facts: PerformRecallFacts) -> PerformRecallStep {
        let intent = PerformRecallIntent(target: target, controlClass: facts.controlClass, epoch: facts.epoch)
        return PerformRecallStep(phase: .fired(facts.epoch), decision: .fire(intent))
    }

    private static func cancel(_ phase: PerformRecallPhase) -> PerformRecallStep {
        switch phase {
        case .idle: refuse(phase, .notAwaitingConfirm)
        case .awaitingConfirm: PerformRecallStep(phase: .idle, decision: .released)
        case .fired: refuse(phase, .alreadyFired)
        }
    }

    private static func settle(_ phase: PerformRecallPhase) -> PerformRecallStep {
        switch phase {
        case .idle, .awaitingConfirm: refuse(phase, .nothingFired)
        case .fired: PerformRecallStep(phase: .idle, decision: .released)
        }
    }

    private static func refuse(_ phase: PerformRecallPhase, _ reason: PerformRecallRefusal) -> PerformRecallStep {
        PerformRecallStep(phase: phase, decision: .refused(reason))
    }

    private static func drop(_ reason: PerformRecallDrop) -> PerformRecallStep {
        PerformRecallStep(phase: .idle, decision: .dropped(reason))
    }
}
