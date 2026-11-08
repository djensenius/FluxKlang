//
//  SetupFlowReducer.swift
//  FluxKlang
//
//  The step reducer of the startup interface setup flow: identify, map, review, decide. `reduce` takes a state, an
//  event and the current facts and returns the next state or throws a typed refusal. Apply is only an intent value in
//  an ended phase: nothing here applies, sends, prompts, reads, routes, sounds or stores anything, and no tone or
//  channel number is assumed. Stay manual ends the flow from every running or suspended phase.
//

/// Where the flow is. A suspended flow keeps every decision; an ended flow accepts no event.
enum SetupFlowPhase: Equatable, Sendable {
    case running(SetupFlowStep)
    case suspended(SetupFlowStep)
    case ended(SetupFlowEnding)
}

/// How the flow ended.
enum SetupFlowEnding: Equatable, Sendable {
    /// The operator chose manual or remote control.
    case manual
    /// Every gate passed at the decide step, with both panes acknowledged under the current facts; the caller may now
    /// act on the intent.
    case applyRequested(SetupFlowApplyIntent)
}

/// What the operator asked to apply: the picked rig, if any, and the facts the gates passed under (the two
/// pane gates need the acknowledged facts to equal the current facts, see `matches`). It has no
/// member that resumes a device, sounds a tone or names a route or channel.
struct SetupFlowApplyIntent: Equatable, Sendable {
    let rig: SetupFlowRigID?
    let basis: SetupFlowFacts

    fileprivate init(rig: SetupFlowRigID?, basis: SetupFlowFacts) {
        self.rig = rig
        self.basis = basis
    }
}

enum SetupFlowEvent: Equatable, Sendable {
    case next
    case back
    case chooseRig(SetupFlowRigID)
    case acknowledge(SetupFlowPane)
    case requestApply
    case stayManual
    case cancel
    case reopen
}

/// The decisions made so far. Built only by `begin()` and by `SetupFlowReducer`.
struct SetupFlowState: Equatable, Sendable {
    let phase: SetupFlowPhase
    let pickedRig: SetupFlowRigID?
    /// The facts the home pane was acknowledged under, if it was.
    let homeSeenUnder: SetupFlowFacts?
    /// The facts the runtime-map pane was acknowledged under, if it was.
    let runtimeMapSeenUnder: SetupFlowFacts?

    fileprivate init(
        phase: SetupFlowPhase,
        pickedRig: SetupFlowRigID?,
        homeSeenUnder: SetupFlowFacts?,
        runtimeMapSeenUnder: SetupFlowFacts?
    ) {
        self.phase = phase
        self.pickedRig = pickedRig
        self.homeSeenUnder = homeSeenUnder
        self.runtimeMapSeenUnder = runtimeMapSeenUnder
    }

    /// Running at the identify step, nothing picked, nothing acknowledged.
    static func begin() -> Self {
        Self(phase: .running(.identify), pickedRig: nil, homeSeenUnder: nil, runtimeMapSeenUnder: nil)
    }

    fileprivate func moved(to phase: SetupFlowPhase) -> Self {
        Self(
            phase: phase, pickedRig: pickedRig, homeSeenUnder: homeSeenUnder,
            runtimeMapSeenUnder: runtimeMapSeenUnder
        )
    }
}

enum SetupFlowReducer {
    /// Refusal order: the phase (`flowEnded`, `suspended`), then `notSuspended` (`reopen` while running), then the
    /// step fit (`noNextStep`, `noPreviousStep`, `wrongStep`), then the `chooseRig` payload (`rigNotOffered`) or the
    /// gates in order. A refusal returns no state. The gates are re-checked on every `next` that leaves identify, map
    /// or review, and on `requestApply` at decide: access, present devices, rig, undecided roles, home pane,
    /// runtime-map pane. `next` leaving identify checks the first three, leaving map the first four, leaving review
    /// all six; `requestApply` checks all six.
    static func reduce(
        _ state: SetupFlowState,
        _ event: SetupFlowEvent,
        facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        switch state.phase {
        case .ended:
            throw .flowEnded
        case .suspended(let step):
            return try reduceSuspended(state, step, event)
        case .running(let step):
            return try reduceRunning(state, step, event, facts)
        }
    }

    private static func reduceSuspended(
        _ state: SetupFlowState,
        _ step: SetupFlowStep,
        _ event: SetupFlowEvent
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        switch event {
        case .reopen:
            return state.moved(to: .running(step))
        case .stayManual:
            return state.moved(to: .ended(.manual))
        case .next, .back, .chooseRig, .acknowledge, .requestApply, .cancel:
            throw .suspended
        }
    }

    private static func reduceRunning(
        _ state: SetupFlowState,
        _ step: SetupFlowStep,
        _ event: SetupFlowEvent,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        switch event {
        case .next:
            return try advance(state, step, facts)
        case .back:
            return try retreat(state, step)
        case .chooseRig(let rig):
            return try choose(state, step, rig, facts)
        case .acknowledge(let pane):
            return try acknowledge(state, step, pane, facts)
        case .requestApply:
            return try apply(state, step, facts)
        case .stayManual:
            return state.moved(to: .ended(.manual))
        case .cancel:
            return state.moved(to: .suspended(step))
        case .reopen:
            throw .notSuspended
        }
    }

    // MARK: - Moving between steps

    private static func advance(
        _ state: SetupFlowState,
        _ step: SetupFlowStep,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        switch step {
        case .identify:
            try requireIdentifyGates(state, facts)
            return state.moved(to: .running(.map))
        case .map:
            try requireMapGates(state, facts)
            return state.moved(to: .running(.review))
        case .review:
            try requireReviewGates(state, facts)
            return state.moved(to: .running(.decide))
        case .decide:
            throw .noNextStep
        }
    }

    private static func retreat(
        _ state: SetupFlowState,
        _ step: SetupFlowStep
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        switch step {
        case .identify:
            throw .noPreviousStep
        case .map:
            return state.moved(to: .running(.identify))
        case .review:
            return state.moved(to: .running(.map))
        case .decide:
            return state.moved(to: .running(.review))
        }
    }

    private static func apply(
        _ state: SetupFlowState,
        _ step: SetupFlowStep,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        guard step == .decide else { throw .wrongStep(expected: .decide) }
        try requireReviewGates(state, facts)
        let intent = SetupFlowApplyIntent(rig: state.pickedRig, basis: facts)
        return state.moved(to: .ended(.applyRequested(intent)))
    }

    // MARK: - Decisions

    private static func choose(
        _ state: SetupFlowState,
        _ step: SetupFlowStep,
        _ rig: SetupFlowRigID,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        guard step == .identify else { throw .wrongStep(expected: .identify) }
        guard facts.offeredRigs.contains(rig) else { throw .rigNotOffered(rig) }
        return SetupFlowState(phase: state.phase, pickedRig: rig, homeSeenUnder: nil, runtimeMapSeenUnder: nil)
    }

    private static func acknowledge(
        _ state: SetupFlowState,
        _ step: SetupFlowStep,
        _ pane: SetupFlowPane,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        guard step == .review else { throw .wrongStep(expected: .review) }
        switch pane {
        case .home:
            return SetupFlowState(
                phase: state.phase, pickedRig: state.pickedRig, homeSeenUnder: facts,
                runtimeMapSeenUnder: state.runtimeMapSeenUnder
            )
        case .runtimeMap:
            return SetupFlowState(
                phase: state.phase, pickedRig: state.pickedRig, homeSeenUnder: state.homeSeenUnder,
                runtimeMapSeenUnder: facts
            )
        }
    }

    // MARK: - Gates

    private static func requireIdentifyGates(
        _ state: SetupFlowState,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) {
        try requireAccess(facts)
        try requireDevices(facts)
        try requireRig(state, facts)
    }

    private static func requireMapGates(
        _ state: SetupFlowState,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) {
        try requireIdentifyGates(state, facts)
        try requireRoles(facts)
    }

    private static func requireReviewGates(
        _ state: SetupFlowState,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) {
        try requireMapGates(state, facts)
        try requirePane(.home, seenUnder: state.homeSeenUnder, facts)
        try requirePane(.runtimeMap, seenUnder: state.runtimeMapSeenUnder, facts)
    }

    private static func requireAccess(_ facts: SetupFlowFacts) throws(SetupFlowRefusal) {
        guard facts.access == .granted else { throw .permissionNotGranted(facts.access) }
    }

    private static func requireDevices(_ facts: SetupFlowFacts) throws(SetupFlowRefusal) {
        guard facts.presentDevices >= 1 else { throw .noPresentDevice }
    }

    private static func requireRig(
        _ state: SetupFlowState,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) {
        if let pick = state.pickedRig {
            guard facts.offeredRigs.contains(pick) else { throw .rigNotOffered(pick) }
        } else {
            guard facts.offeredRigs.isEmpty else { throw .rigNotChosen }
        }
    }

    private static func requireRoles(_ facts: SetupFlowFacts) throws(SetupFlowRefusal) {
        guard facts.undecidedRoles == 0 else { throw .rolesUndecided(facts.undecidedRoles) }
    }

    private static func requirePane(
        _ pane: SetupFlowPane,
        seenUnder: SetupFlowFacts?,
        _ facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) {
        guard let seen = seenUnder, seen.matches(facts) else { throw .paneNotReviewed(pane) }
    }
}
