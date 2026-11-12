//
//  ActionSetTriggerBuilder.swift
//  FluxKlang
//
//  Turns one fire of a resolved action set into trigger stamps, all or
//  nothing (#107 A1). v1 has one `notReady` policy, drop and report
//  (media-contract.md §6.4): a set that is not ready yields no triggers.
//  Every requirement, shared or per member, must be current, so the
//  scheduler is never handed a set it would admit only in part.
//  Commit and look-ahead scheduling are not decided here.
//
//  Precedence: caller errors (an invalid context, an undeclared counter, a
//  bound, a trigger the contract refuses such as a musical target without
//  transport) throw before any drop report, even for a set that is not ready.
//
//  Snapshot scope: all or nothing holds for the one ledger snapshot passed
//  to `decide`. The caller must submit every emitted trigger against that
//  same snapshot, with no source-generation change in between; otherwise the
//  scheduler, which admits triggers one at a time, could still admit part of
//  the set. `ActionSetSubmitter.fire` (#107 A2) does that: it decides and
//  submits against one snapshot and admits every member's trigger or none.
//  A `.dropped` result and a thrown refusal both admit none.
//

import Foundation

/// One fire of a set. Caller-supplied values only; no clocks are read.
struct ActionSetFireRequest: Sendable {
    /// Member `i` gets the trigger ID `"<baseTrigger>.<i>"`.
    let baseTrigger: TriggerID
    let originHost: HostStamp
    let horizonFrame: Int64
    let target: TriggerTarget
    /// The current activation's `context` counter (§5.8).
    let context: GenerationKey
    /// Extra dependencies per member, such as its `source` generations.
    var memberRequirements: [ActionID: [GenerationRequirement]] = [:]
    var loopIteration: UInt32 = 0
}

struct ActionSetDropReport: Hashable, Sendable {
    enum Reason: String, Hashable, Sendable { case notReady }

    let set: ActionSetID
    let reason: Reason
    /// Every member's state and reason, in member order.
    let readiness: ActionSetReadinessReport
}

enum ActionSetFireDecision: Hashable, Sendable {
    /// One stamp per member, in member order.
    case fire([TriggerStamp])
    case dropped(ActionSetDropReport)
}

enum ActionSetTriggerBuilder {
    /// Kinds the builder alone adds; members may not supply them.
    static let builderKinds: Set<GenerationKind> = [.sampleClock, .transport, .musicalMap, .context, .cancelScope]

    /// Builds and checks every stamp first, so a caller error throws even when the set would be dropped.
    /// Then the set fires only if every member is ready and every requirement current; otherwise
    /// it is dropped whole, each member reporting its own state, reason and stale requirements.
    ///
    /// The guarantee holds for this one `ledger` snapshot only: submit every emitted trigger against
    /// the same snapshot, with no source-generation change in between. `ActionSetSubmitter.fire` (#107 A2)
    /// decides and submits against one snapshot and admits every member's trigger or none: a `.dropped`
    /// result and a thrown refusal both admit none.
    static func decide(_ resolved: ResolvedActionSet, request: ActionSetFireRequest,
                       readiness: ActionReadiness, ledger: GenerationLedger)
        throws(ActionSetRefusal) -> ActionSetFireDecision {
        guard request.context.kind == .context else { throw .invalidContext(request.context) }
        var stamps: [TriggerStamp] = []
        for (index, action) in resolved.actions.enumerated() {
            try stamps.append(stamp(for: action, index: index, set: resolved.set, request: request, ledger: ledger))
        }
        let stale = try staleRequirements(stamps, ledger: ledger)
        let report = ActionSetReadinessAggregate.evaluate(resolved, readiness: readiness, ledger: ledger,
                                                          stale: stale)
        guard report.isReady else {
            return .dropped(ActionSetDropReport(set: resolved.set.id, reason: .notReady, readiness: report))
        }
        return .fire(stamps)
    }

    /// Undeclared counters are caller errors; declared but superseded ones make their member stale.
    private static func staleRequirements(_ stamps: [TriggerStamp],
                                          ledger: GenerationLedger) throws(ActionSetRefusal)
        -> [ActionID: [GenerationKey]] {
        var stale: [ActionID: [GenerationKey]] = [:]
        for stamp in stamps {
            for requirement in stamp.requires {
                guard let live = ledger.generation(requirement.key) else { throw .undeclaredCounter(requirement.key) }
                if live != requirement.generation { stale[stamp.action, default: []].append(requirement.key) }
            }
        }
        return stale
    }

    private static func stamp(for action: ProjectMediaAction, index: Int, set: PerformanceActionSet,
                              request: ActionSetFireRequest, ledger: GenerationLedger)
        throws(ActionSetRefusal) -> TriggerStamp {
        let raw = "\(request.baseTrigger.rawValue).\(index)"
        guard raw.utf8.count <= TriggerID.maximumLength, let id = TriggerID(rawValue: raw) else {
            throw .triggerIDTooLong(raw.utf8.count)
        }
        let latePolicy = resolvedLatePolicy(action.policy)
        let requires = try requirements(for: action.id, set: set, request: request,
                                        latePolicy: latePolicy, ledger: ledger)
        let stamp = TriggerStamp(id: id, action: action.id, originHost: request.originHost,
                                 horizonFrame: request.horizonFrame, requires: requires, target: request.target,
                                 latePolicy: latePolicy, retroactiveMs: action.policy.retroactiveMs,
                                 stoppedPolicy: action.policy.stoppedPolicy, loopIteration: request.loopIteration)
        do {
            try stamp.validate(primaryClock: ledger.primaryClock, musicalClock: ledger.musicalClock)
        } catch {
            throw .invalidTrigger(action.id, error)
        }
        return stamp
    }

    /// A `nextBoundary` without its own grid carries the action's grid (§6.3).
    private static func resolvedLatePolicy(_ policy: ActionPolicy) -> LatePolicy {
        if case .nextBoundary(nil) = policy.latePolicy, let grid = policy.gridTicks {
            return .nextBoundary(gridTicks: grid)
        }
        return policy.latePolicy
    }

    private static func requirements(for action: ActionID, set: PerformanceActionSet,
                                     request: ActionSetFireRequest, latePolicy: LatePolicy,
                                     ledger: GenerationLedger) throws(ActionSetRefusal) -> [GenerationRequirement] {
        var keys = [ledger.primaryClock, request.context, set.cancelScopeKey]
        var needsTransport = request.target.isMusical
        if case .nextBoundary = latePolicy { needsTransport = true }
        if needsTransport, let musicalClock = ledger.musicalClock {
            keys.append(GenerationKey(.transport, musicalClock))
        }
        var requires: [GenerationRequirement] = []
        for key in keys {
            guard let generation = ledger.generation(key) else { throw .undeclaredCounter(key) }
            requires.append(GenerationRequirement(key: key, generation: generation))
        }
        let extra = request.memberRequirements[action] ?? []
        for requirement in extra where builderKinds.contains(requirement.key.kind) {
            throw .invalidMemberRequirement(action, requirement.key)
        }
        let total = requires.count + extra.count
        guard total <= TriggerStamp.maximumRequirements else { throw .tooManyRequirements(action, total) }
        return requires + extra
    }
}
