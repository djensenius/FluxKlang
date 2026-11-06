//
//  ActionSetSubmitter.swift
//  FluxKlang
//
//  Atomic admission of one action-set fire, and the scope sweep (#107 A2).
//  `ActionSetTriggerBuilder.decide` yields every member's stamp or none; this
//  submits them all or none. It stages copies of the value-type scheduler and
//  pending registry, submits every stamp into the copies, and publishes both
//  only when every member succeeded. Any refusal leaves the caller's
//  scheduler (session, clock, timeline), registry and ledger unchanged.
//
//  Cost: staging copies the scheduler and registry, O(scheduler size) per
//  fire or sweep. This is control-plane work only, never the render thread.
//
//  v1 keeps `notReady` as drop and report: a dropped decision submits
//  nothing and is returned unchanged; it is never deferred.
//

/// The caller's claim and CURRENT trusted snapshots for one submission: the session token it believes
/// current, and the ledger/readiness the scheduler and registry are checked against.
struct ActionSetSubmitContext: Sendable {
    let session: TriggerSessionToken
    let scheduler: TriggerSchedulerContext

    var ledger: GenerationLedger { scheduler.ledger }
}

/// A free namespace: contract types such as `TriggerScheduler` are not extended from Performance code.
enum ActionSetSubmitter {
    /// Decides and submits one fire against ONE snapshot (`context.scheduler`'s ledger and readiness),
    /// which closes A1's same-snapshot caveat. Builder refusals surface as `.decision`.
    static func fire(_ resolved: ResolvedActionSet, request: ActionSetFireRequest, context: ActionSetSubmitContext,
                     scheduler: inout TriggerScheduler,
                     pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal) -> ActionSetSubmission {
        let decision: ActionSetFireDecision
        do {
            decision = try ActionSetTriggerBuilder.decide(resolved, request: request,
                                                          readiness: context.scheduler.readiness,
                                                          ledger: context.ledger)
        } catch {
            throw .decision(error)
        }
        return try submit(decision, of: resolved.set, context: context, scheduler: &scheduler, pending: &pending)
    }

    /// Submits a decision for `set` all or nothing. Check order, all before any publication:
    /// 1. shape (one stamp per member, in member order, one shared cancel-scope generation);
    /// 2. registry capacity for every member, before any scheduler submit;
    /// 3. every requirement current in `context.ledger` (an old epoch is refused, never admitted stale);
    /// 4. registry staging (`duplicatePending`);
    /// 5. scheduler staging, member by member; the scheduler's error is kept as thrown.
    static func submit(_ decision: ActionSetFireDecision, of set: PerformanceActionSet,
                       context: ActionSetSubmitContext, scheduler: inout TriggerScheduler,
                       pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal) -> ActionSetSubmission {
        switch decision {
        case .dropped(let report):
            guard report.set == set.id else { throw .setMismatch(expected: set.id, actual: report.set) }
            return .dropped(report)
        case .fire(let stamps):
            return .fired(try admit(stamps, of: set, context: context, scheduler: &scheduler, pending: &pending))
        }
    }

    /// Bumps `cancelScope/<scope>` (`userCancel`), then sweeps the scheduler with `cancelStale`.
    /// Returns, in scheduler admission order, exactly the handles of the registered set members in
    /// `scope` that were still pending in the scheduler. Every set sharing the scope is cancelled
    /// together; other scopes survive. Repeating it bumps again and returns `[]`.
    ///
    /// The sweep also cancels any other request already stale against the ledger; those are not
    /// returned here, but their outcomes reach `drain` like every cancellation. A refusal changes nothing.
    static func userCancel(scope: GenerationSubject, ledger: inout GenerationLedger,
                           scheduler: inout TriggerScheduler,
                           pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal) -> [TriggerHandle] {
        var stagedLedger = ledger
        var stagedPending = pending
        let cancelled: [TriggerID]
        do {
            cancelled = try stagedPending.userCancel(scope: scope, ledger: &stagedLedger)
        } catch {
            throw .cancel(error)
        }
        var stagedScheduler = scheduler
        let swept: [TriggerHandle]
        do {
            swept = try stagedScheduler.cancelStale(ledger: stagedLedger)
        } catch {
            throw .sweep(error)
        }
        let members = Set(cancelled)
        ledger = stagedLedger
        pending = stagedPending
        scheduler = stagedScheduler
        return swept.filter { members.contains($0.trigger) }
    }

    /// Forgets every drained outcome's trigger in the registry, so the registry and scheduler agree
    /// after `drain`. Returns, in outcome order, the triggers that were still registered.
    @discardableResult
    static func settle(_ outcomes: [SessionOutcome], pending: inout ActionSetPendingTriggers) -> [TriggerID] {
        var settled: [TriggerID] = []
        for outcome in outcomes where pending.complete(outcome.handle.trigger) {
            settled.append(outcome.handle.trigger)
        }
        return settled
    }

    private static func admit(_ stamps: [TriggerStamp], of set: PerformanceActionSet,
                              context: ActionSetSubmitContext, scheduler: inout TriggerScheduler,
                              pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal)
        -> ActionSetFireRecord {
        _ = try ActionSetFireRecord.scope(of: stamps, set: set)
        guard stamps.count <= ActionSetPendingTriggers.maximumPending - pending.count else {
            throw .pendingCapacity(pending: pending.count, requested: stamps.count)
        }
        let ledger = context.ledger
        for (index, stamp) in stamps.enumerated() {
            if let stale = stamp.requires.first(where: { !ledger.isCurrent($0) }) {
                throw .staleRequirement(index: index, stale.key)
            }
        }
        var stagedPending = pending
        for (index, stamp) in stamps.enumerated() {
            do {
                try stagedPending.register(stamp, ledger: ledger)
            } catch {
                throw .registry(index: index, error)
            }
        }
        var stagedScheduler = scheduler
        var handles: [TriggerHandle] = []
        for (index, stamp) in stamps.enumerated() {
            do {
                handles.append(try stagedScheduler.submit(stamp, session: context.session,
                                                          context: context.scheduler))
            } catch {
                throw .scheduler(index: index, error)
            }
        }
        let record = try ActionSetFireRecord.make(set: set, stamps: stamps, handles: handles)
        scheduler = stagedScheduler
        pending = stagedPending
        return record
    }
}
