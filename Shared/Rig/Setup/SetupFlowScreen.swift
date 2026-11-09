//
//  SetupFlowScreen.swift
//  FluxKlang
//
//  What the startup interface setup view shows for one state of the flow: the headline, one entry per event with the
//  reducer's own verdict, the one blocker of the forward action, whether manual or remote control is on offer, and a
//  note about lost or muted devices. Every verdict is a dry run of `SetupFlowReducer.reduce`; this file holds no rule
//  of its own, so a change in the reducer needs no change here. Nothing here reads a device, asks for permission,
//  routes audio, sounds a tone or stores anything.
//

/// What the reducer would do with one event right now.
enum SetupFlowScreenVerdict: Equatable, Sendable {
    case enabled
    case refused(SetupFlowRefusal)

    /// The refusal, or nil when the event is enabled.
    var refusal: SetupFlowRefusal? {
        switch self {
        case .enabled:
            return nil
        case .refused(let refusal):
            return refusal
        }
    }
}

/// One button of the setup view: the event it sends, what the reducer would do with it now, and its fixed label.
struct SetupFlowScreenAction: Equatable, Sendable {
    let event: SetupFlowEvent
    let verdict: SetupFlowScreenVerdict
    let label: String
}

/// Whether the operator may leave setup for manual or remote control.
enum SetupFlowScreenManual: Equatable, Sendable {
    /// The reducer accepts `stayManual` now.
    case offered
    /// The flow already ended in manual mode.
    case active
    /// The reducer refuses `stayManual` and the flow did not end in manual mode.
    case notOffered
}

/// The display value of the setup flow, built by `make` from a state and the current facts. The verdicts are a
/// preview: the caller must still send an event through `SetupFlowReducer.reduce`, which may refuse it because the
/// facts changed in between. `enabled` does not reserve anything.
struct SetupFlowScreen: Equatable, Sendable {
    /// Event kinds in `actions` before the offered rigs are added (`chooseRig` is listed once per offered rig).
    private static let eventKindCount = 8
    /// The longest `actions` list: every event kind and as many `chooseRig` entries as facts may offer.
    static let maximumActions = eventKindCount + SetupFlowFacts.maximumRigs

    let phase: SetupFlowPhase
    let headline: String
    /// Always complete and in a fixed order: `next`, `back`, a `chooseRig` per offered rig in the order of the facts,
    /// `acknowledge` for the home pane and the runtime map pane, `requestApply`, `stayManual`, `cancel`, `reopen`.
    let actions: [SetupFlowScreenAction]
    /// The refusal of the forward action while the flow runs, else nil.
    let blocker: SetupFlowRefusal?
    let blockerSentence: String?
    let manual: SetupFlowScreenManual
    let manualSentence: String
    let mutedNote: String?

    private init(
        phase: SetupFlowPhase,
        actions: [SetupFlowScreenAction],
        blocker: SetupFlowRefusal?,
        manual: SetupFlowScreenManual,
        mutedNote: String?
    ) {
        self.phase = phase
        headline = SetupFlowScreenText.headline(for: phase)
        self.actions = actions
        self.blocker = blocker
        blockerSentence = blocker.map { SetupFlowScreenText.sentence(for: $0) }
        self.manual = manual
        manualSentence = SetupFlowScreenText.manualSentence(for: manual)
        self.mutedNote = mutedNote
    }

    /// Total: both inputs are already validated values. At most `maximumActions` reducer calls, one per action.
    static func make(_ state: SetupFlowState, facts: SetupFlowFacts) -> Self {
        var actions: [SetupFlowScreenAction] = []
        actions.reserveCapacity(eventKindCount + facts.offeredRigs.count)
        let nextAction = action(.next, state, facts)
        actions.append(nextAction)
        actions.append(action(.back, state, facts))
        for rig in facts.offeredRigs {
            actions.append(action(.chooseRig(rig), state, facts))
        }
        actions.append(action(.acknowledge(.home), state, facts))
        actions.append(action(.acknowledge(.runtimeMap), state, facts))
        let applyAction = action(.requestApply, state, facts)
        actions.append(applyAction)
        let manualAction = action(.stayManual, state, facts)
        actions.append(manualAction)
        actions.append(action(.cancel, state, facts))
        actions.append(action(.reopen, state, facts))
        return Self(
            phase: state.phase,
            actions: actions,
            blocker: blocker(phase: state.phase, next: nextAction, apply: applyAction),
            manual: manual(phase: state.phase, stayManual: manualAction),
            mutedNote: facts.lostMuted >= 1 ? SetupFlowScreenText.mutedNote : nil
        )
    }

    private static func action(
        _ event: SetupFlowEvent,
        _ state: SetupFlowState,
        _ facts: SetupFlowFacts
    ) -> SetupFlowScreenAction {
        SetupFlowScreenAction(
            event: event, verdict: dryRun(state, event, facts), label: SetupFlowScreenText.label(for: event)
        )
    }

    private static func dryRun(
        _ state: SetupFlowState,
        _ event: SetupFlowEvent,
        _ facts: SetupFlowFacts
    ) -> SetupFlowScreenVerdict {
        do throws(SetupFlowRefusal) {
            _ = try SetupFlowReducer.reduce(state, event, facts: facts)
            return .enabled
        } catch {
            return .refused(error)
        }
    }

    private static func blocker(
        phase: SetupFlowPhase,
        next: SetupFlowScreenAction,
        apply: SetupFlowScreenAction
    ) -> SetupFlowRefusal? {
        switch phase {
        case .running(let step):
            return step == .decide ? apply.verdict.refusal : next.verdict.refusal
        case .suspended, .ended:
            return nil
        }
    }

    private static func manual(phase: SetupFlowPhase, stayManual: SetupFlowScreenAction) -> SetupFlowScreenManual {
        switch stayManual.verdict {
        case .enabled:
            return .offered
        case .refused:
            return endedManual(phase) ? .active : .notOffered
        }
    }

    private static func endedManual(_ phase: SetupFlowPhase) -> Bool {
        switch phase {
        case .ended(.manual):
            return true
        case .ended(.applyRequested), .running, .suspended:
            return false
        }
    }
}
