//
//  ActivationRecovery.swift
//  FluxKlang
//
//  The recovery policy and engine lifecycle (status-diagnostics.md "Lifecycle",
//  draft-active-transactions.md "Rollback is capability-specific"). Pure: it
//  returns decisions and effects for the owner (the H5 actor) to perform, and
//  performs nothing itself.
//

/// What the engine is doing, as one window of one project observes it.
enum EngineLifecycle: Hashable, Sendable {
    case stopped
    case preparing(ContractRevision)
    case running
    /// Running with these capabilities lost; affected nodes are silent placeholders.
    case degraded([CapabilityID])
    /// Outputs are muted and changes to the running set are rejected.
    case recovering
    /// Another project, or another window, holds the engine lease: edit and prepare only.
    case heldByOther(ProjectID)

    /// Whether this window's engine produces sound. Preparing keeps rendering the running set.
    var rendersOutput: Bool {
        switch self {
        case .preparing, .running, .degraded: true
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
            case .degraded(let lost): return lost.contains(capability) ? self : .degraded(lost + [capability])
            default: return self
            }
        case .commitFailed, .partialCommit, .processorCrashed:
            return self
        }
    }

    /// The lifecycle `window` of `project` observes: the holder's `engine`
    /// lifecycle when the window is on the lease, otherwise held or stopped.
    static func observed(by window: WindowID, of project: ProjectID, in registry: EngineLeaseRegistry,
                         engine: EngineLifecycle) -> EngineLifecycle {
        switch registry.role(of: window, project: project) {
        case .renders: engine
        case .editAndPrepareOnly(let holder): .heldByOther(holder)
        case .stopped: .stopped
        }
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
    case restorePrevious(ContractRevision)
    /// Keep the partly applied plan active.
    case keepActivePartial
    /// The node stays a silent placeholder (not bypassed) and raises a
    /// diagnostic; it is never re-activated automatically.
    case missingPlaceholder(NodeID)
    /// Mute outputs and enter recovery. The policy only ever mutes.
    case recover(muteOutputs: Bool)
}

/// One recovery transition's output: decisions first, then effects.
struct ActivationRecoveryStep: Hashable, Sendable {
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
        ActivationRecoveryStep(decisions: decisions(for: event, running: running), effects: [])
    }

    /// Return to the running graph and release the plan that did not become it.
    static func restore(_ running: RunningGraph, discarding prepared: PreparedActivationID) -> ActivationRecoveryStep {
        ActivationRecoveryStep(decisions: decisions(for: .commitFailed, running: running),
                               effects: [.discard(prepared)])
    }

    /// Keep a partly applied plan as the new running graph: unapplied nodes
    /// become placeholders, and the replaced plan is released.
    static func keepPartial(unapplied: Set<NodeID>, replacing previous: RunningGraph) -> ActivationRecoveryStep {
        ActivationRecoveryStep(
            decisions: decisions(for: .partialCommit, running: previous)
                + unapplied.sorted().map { .missingPlaceholder($0) },
            effects: previous.prepared.map { [.discard($0)] } ?? []
        )
    }
}
