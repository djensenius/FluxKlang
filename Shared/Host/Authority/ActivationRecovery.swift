//
//  ActivationRecovery.swift
//  FluxKlang
//
//  The recovery policy and engine lifecycle (status-diagnostics.md "Lifecycle",
//  draft-active-transactions.md "Rollback is capability-specific"). Pure: it
//  returns decisions and effects for the owner (the H5 actor) to perform, and
//  performs nothing itself.
//

/// What keeps rendering while a revision is prepared ("the running set, if any").
enum RunningSetState: Hashable, Sendable {
    /// No running set yet, as in a first activation: nothing renders.
    case absent
    case running
    /// Rendering with these capabilities lost, as in `EngineLifecycle.degraded`.
    case degraded([CapabilityID])
}

/// What the engine is doing, as one window of one project observes it.
enum EngineLifecycle: Hashable, Sendable {
    case stopped
    /// Preparing a revision; `over` is what renders meanwhile and what the
    /// lifecycle returns to on cancel or failure (`endingPreparation`).
    case preparing(ContractRevision, over: RunningSetState)
    case running
    /// Running with these capabilities lost; affected nodes are silent placeholders.
    /// Which nodes are affected, and leaving `degraded` when a capability
    /// returns, are re-derived by the owner from the capability document.
    case degraded([CapabilityID])
    /// Outputs are muted and changes to the running set are rejected.
    case recovering
    /// Another project, or another window, holds the engine lease: edit and prepare only.
    case heldByOther(ProjectID)

    /// Whether this window's engine produces sound. Preparing keeps rendering the running set, if any.
    var rendersOutput: Bool {
        switch self {
        case .preparing(_, over: let base): base != .absent
        case .running, .degraded: true
        case .stopped, .recovering, .heldByOther: false
        }
    }

    /// Only recovery mutes outputs; a stopped or other-held engine is simply not this window's.
    var outputsMuted: Bool { self == .recovering }

    /// Whether commands that change the running set may be admitted. A stopped
    /// engine stores them without rendering.
    var acceptsRunningSetChanges: Bool {
        switch self {
        case .recovering, .heldByOther: false
        case .stopped, .preparing, .running, .degraded: true
        }
    }

    /// The lifecycle after `event`. Losing the lease or the commit's outcome
    /// always fails closed into muted recovery, whatever the lifecycle was.
    func after(_ event: RecoveryEvent) -> EngineLifecycle {
        switch event {
        case .commitOutcomeUnknown, .revisionOverflow, .leaseLost:
            return .recovering
        case .capabilityLost(let capability):
            switch self {
            case .running: return .degraded([capability])
            case .degraded(let lost): return .degraded(Self.adding(capability, to: lost))
            case .preparing(let revision, over: .running): return .preparing(revision, over: .degraded([capability]))
            case .preparing(let revision, over: .degraded(let lost)):
                return .preparing(revision, over: .degraded(Self.adding(capability, to: lost)))
            case .preparing(_, over: .absent), .stopped, .recovering, .heldByOther: return self
            }
        case .commitFailed, .partialCommit, .processorCrashed:
            return self
        }
    }

    /// The lifecycle `window` of `project` observes: the holder's `engine`
    /// lifecycle when the window is on the lease, otherwise held or stopped.
    /// Unresolved recovery outlives the lease: with no holder, or in this
    /// project's windows off the lease, a recovering engine stays `.recovering`
    /// (muted, running-set changes rejected). Other projects see `.heldByOther`.
    static func observed(by window: WindowID, of project: ProjectID, in registry: EngineLeaseRegistry,
                         engine: EngineLifecycle) -> EngineLifecycle {
        switch registry.role(of: window, project: project) {
        case .renders: engine
        case .editAndPrepareOnly(let holder):
            holder == project && engine == .recovering ? .recovering : .heldByOther(holder)
        case .stopped: engine == .recovering ? .recovering : .stopped
        }
    }

    /// Starts preparing `revision` over what renders now, keeping the lost capabilities.
    /// A recovering or other-held lifecycle is returned unchanged.
    func startingPreparation(of revision: ContractRevision) -> EngineLifecycle {
        switch self {
        case .stopped: .preparing(revision, over: .absent)
        case .running: .preparing(revision, over: .running)
        case .degraded(let lost): .preparing(revision, over: .degraded(lost))
        case .preparing(_, over: let base): .preparing(revision, over: base)
        case .recovering, .heldByOther: self
        }
    }

    /// Leaves preparation without a commit (cancelled, failed or abandoned): back to what renders.
    var endingPreparation: EngineLifecycle {
        switch self {
        case .preparing(_, over: .absent): .stopped
        case .preparing(_, over: .running): .running
        case .preparing(_, over: .degraded(let lost)): .degraded(lost)
        case .stopped, .running, .degraded, .recovering, .heldByOther: self
        }
    }

    private static func adding(_ capability: CapabilityID, to lost: [CapabilityID]) -> [CapabilityID] {
        lost.contains(capability) ? lost : lost + [capability]
    }
}

/// Something that went wrong after a plan was handed to the engine.
enum RecoveryEvent: Hashable, Sendable {
    case commitFailed
    case partialCommit
    /// The commit's report did not arrive, for example after a timeout or
    /// lost report; it is never assumed successful.
    case commitOutcomeUnknown
    /// An applied plan cannot be named by a next revision.
    case revisionOverflow
    case processorCrashed(NodeID)
    case leaseLost
    case capabilityLost(CapabilityID)
}

/// What the owner must do, in order, before performing a step's effects.
enum RecoveryDecision: Hashable, Sendable {
    /// Return the engine to the running graph's prepared plan at this revision.
    /// `resolveRecovery` issues it only under this project's engine lease, and the
    /// owner (H5) performs it under that lease; without it, it stays recovering, muted.
    case restorePrevious(ContractRevision)
    /// Keep the partly applied plan active.
    case keepActivePartial
    /// The node stays a silent placeholder (not bypassed) and raises a
    /// diagnostic; it is never re-activated automatically.
    case missingPlaceholder(NodeID)
    /// Mute outputs and enter recovery. The policy only ever mutes (`true`);
    /// the field keeps the instruction explicit for the owner and diagnostics.
    case recover(muteOutputs: Bool)
}

/// Why a commit attempt is abandoned without a usable report.
enum CommitAbandonment: Hashable, Sendable {
    /// No report arrived, for example after a timeout or a lost report.
    case outcomeUnknown
    /// The plan was applied, but the running revision cannot advance.
    case revisionOverflow
    /// The engine lease was lost or changed hands.
    case leaseLost

    var event: RecoveryEvent {
        switch self {
        case .outcomeUnknown: .commitOutcomeUnknown
        case .revisionOverflow: .revisionOverflow
        case .leaseLost: .leaseLost
        }
    }
}

/// One recovery transition's output: decisions first, then effects.
struct ActivationRecoveryStep: Hashable, Sendable {
    /// What the step recovers from, for the owner's diagnostics.
    let cause: RecoveryEvent
    let decisions: [RecoveryDecision]
    let effects: [ActivationEffect]
}

enum ActivationRecovery {
    /// The policy for `event` over the running graph. A crashed processor only
    /// becomes a placeholder; a lost capability only degrades (no decisions here,
    /// the lifecycle records it).
    static func decisions(for event: RecoveryEvent, running: RunningGraph) -> [RecoveryDecision] {
        switch event {
        case .commitFailed: [.restorePrevious(running.revision)]
        case .partialCommit: [.keepActivePartial]
        case .commitOutcomeUnknown, .revisionOverflow, .leaseLost: [.recover(muteOutputs: true)]
        case .processorCrashed(let node): [.missingPlaceholder(node)]
        case .capabilityLost: []
        }
    }

    /// Fail closed: mute and recover, keeping the running graph. `prepared`
    /// stays held by the engine until the recovery is resolved.
    static func enterRecovery(_ event: RecoveryEvent, running: RunningGraph) -> ActivationRecoveryStep {
        ActivationRecoveryStep(cause: event, decisions: decisions(for: event, running: running), effects: [])
    }

    /// Return to the running graph and release the plan that did not become it.
    /// `cause` is the event that started the recovery (`.commitFailed`, or the
    /// abandonment or fail-closed reason); the instructions do not depend on it.
    static func restore(_ running: RunningGraph, discarding prepared: PreparedActivationID,
                        cause: RecoveryEvent) -> ActivationRecoveryStep {
        ActivationRecoveryStep(cause: cause, decisions: decisions(for: .commitFailed, running: running),
                               effects: [.discard(prepared)])
    }

    /// Keep a partly applied plan as the new running graph: unapplied nodes
    /// become placeholders, and the replaced plan is released.
    static func keepPartial(unapplied: Set<NodeID>, replacing previous: RunningGraph) -> ActivationRecoveryStep {
        ActivationRecoveryStep(
            cause: .partialCommit,
            decisions: decisions(for: .partialCommit, running: previous)
                + unapplied.sorted().map { .missingPlaceholder($0) },
            effects: previous.prepared.map { [.discard($0)] } ?? []
        )
    }
}
